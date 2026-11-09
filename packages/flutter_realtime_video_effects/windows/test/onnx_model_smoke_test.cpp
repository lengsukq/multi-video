#include "../pphumanseg_inference.h"
#include "../mf_camera_capture.h"

#include <onnxruntime_cxx_api.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3 ||
      (argc == 3 && std::string(argv[2]) != "--camera")) {
    std::cerr << "Usage: onnx_model_smoke_test <model-path> [--camera]\n";
    return 2;
  }
  try {
    // Report the real model contract independently of the segmentation
    // implementation, to diagnose model updates without exposing camera data.
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "model_smoke");
    Ort::SessionOptions options;
    auto wide = std::wstring(argv[1], argv[1] + std::strlen(argv[1]));
    Ort::Session model(env, wide.c_str(), options);
    auto inputShape = model.GetInputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();
    auto outputShape = model.GetOutputTypeInfo(0).GetTensorTypeAndShapeInfo().GetShape();
    std::cout << "input:";
    for (auto n : inputShape) std::cout << ' ' << n;
    std::cout << "\noutput:";
    for (auto n : outputShape) std::cout << ' ' << n;
    std::cout << '\n';

    // Verify whether the deployed model already returns Softmax probabilities
    // rather than logits. Applying Softmax a second time will wash out the
    // person alpha, blurring even fully recognized foreground pixels.
    float expected_foreground = -1.0f;
    {
      constexpr std::size_t plane = 192 * 192;
      std::vector<float> input(plane * 3, (127.0f / 255.0f - .5f) / .5f);
      const std::array<int64_t, 4> input_dims{1, 3, 192, 192};
      auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
      auto tensor = Ort::Value::CreateTensor<float>(
          memory, input.data(), input.size(), input_dims.data(), input_dims.size());
      Ort::AllocatorWithDefaultOptions allocator;
      auto input_name = model.GetInputNameAllocated(0, allocator);
      auto output_name = model.GetOutputNameAllocated(0, allocator);
      const char* names_in[]{input_name.get()};
      const char* names_out[]{output_name.get()};
      auto output = model.Run(Ort::RunOptions{nullptr}, names_in, &tensor,
                              1, names_out, 1);
      if (output.size() == 1 && output[0].IsTensor()) {
        const auto* values = output[0].GetTensorData<float>();
        const auto shape = output[0].GetTensorTypeAndShapeInfo().GetShape();
        if (shape.size() == 4 && shape[1] == 2 &&
            shape[2] == 192 && shape[3] == 192) {
          float min_bg = 2, max_bg = -2, min_fg = 2, max_fg = -2;
          double sum_error = 0;
          for (std::size_t i = 0; i < plane; ++i) {
            min_bg = std::min(min_bg, values[i]);
            max_bg = std::max(max_bg, values[i]);
            min_fg = std::min(min_fg, values[plane + i]);
            max_fg = std::max(max_fg, values[plane + i]);
            sum_error += std::abs(values[i] + values[plane + i] - 1.0f);
          }
          std::cout << "raw channels: bg=[" << min_bg << ',' << max_bg
                    << "] fg=[" << min_fg << ',' << max_fg
                    << "] avg_sum_error=" << sum_error / plane
                    << " first bg=" << values[0]
                    << " fg=" << values[plane] << '\n';
          expected_foreground = values[plane];
        }
      }
    }

    realtime_video_effects::PersonSegmenter segmenter;
    if (!segmenter.Open(wide)) {
      std::cerr << "Model could not be opened by PersonSegmenter\n";
      return 3;
    }
    // An opaque synthetic frame is enough to verify the shape, pixel format
    // and inference path; no webcam or personal footage is accessed.
    auto pixels = std::make_shared<const std::vector<std::uint8_t>>(
        192 * 192 * 4, std::uint8_t{127});
    realtime_processed_video::Frame frame{
        "synthetic", pixels, 192, 192, 192 * 4, 123, false};
    realtime_processed_video::PersonMask mask;
    if (!segmenter.Infer(frame, &mask) || !mask.Valid()) {
      std::cerr << "Segmentation inference returned no valid mask\n";
      return 4;
    }
    std::cout << "Segmentation OK: " << mask.width << 'x' << mask.height
              << " alpha=" << mask.alpha[0] << '\n';
    if (expected_foreground < 0 ||
        std::abs(mask.alpha[0] - expected_foreground) > 0.0001f) {
      std::cerr << "Regression: person alpha differs from model Softmax foreground"
                << " (possible duplicate Softmax)\n";
      return 7;
    }
    if (argc == 3) {
      std::atomic<int> composed{0};
      std::atomic<int> capture_failed{0};
      std::atomic<int> captured{0};
      std::atomic<std::uint64_t> infer_us{0};
      std::atomic<std::uint64_t> compose_us{0};
      std::atomic<std::uint64_t> preview_us{0};
      std::atomic<std::uint32_t> camera_width{0};
      std::atomic<std::uint32_t> camera_height{0};
      {
        realtime_video_effects::CameraCapture capture;
        // An empty device id uses the first camera that can actually open.
        capture.Start("camera_smoke", L"",
            [&](const realtime_processed_video::Frame& camera) {
              ++captured;
              if (composed.load() >= 12) return;
              camera_width.store(camera.width);
              camera_height.store(camera.height);
              realtime_processed_video::PersonMask person;
              realtime_processed_video::BackgroundSettings blur;
              blur.mode = realtime_processed_video::BackgroundMode::blur;
              blur.blur_radius = 12;
              realtime_processed_video::Frame processed;
              const auto start = std::chrono::steady_clock::now();
              if (!segmenter.Infer(camera, &person)) return;
              const auto after_infer = std::chrono::steady_clock::now();
              if (!realtime_processed_video::Compose(
                      camera, person, blur, &processed)) return;
              const auto after_compose = std::chrono::steady_clock::now();
              if (!processed.IsValid() || !processed.effect_applied ||
                  !realtime_processed_video::PreviewRgba(processed)) return;
              const auto end = std::chrono::steady_clock::now();
              infer_us.fetch_add(std::chrono::duration_cast<std::chrono::microseconds>(
                  after_infer - start).count());
              compose_us.fetch_add(std::chrono::duration_cast<std::chrono::microseconds>(
                  after_compose - after_infer).count());
              preview_us.fetch_add(std::chrono::duration_cast<std::chrono::microseconds>(
                  end - after_compose).count());
              ++composed;
            },
            [&](const std::string& reason) {
              std::cerr << "Camera capture failure: " << reason << '\n';
              ++capture_failed;
            });
        std::this_thread::sleep_for(std::chrono::milliseconds(5000));
        capture.Stop();
      }
      const auto n = std::max(1, composed.load());
      std::cout << "Camera: " << camera_width.load() << 'x'
                << camera_height.load() << ", captured=" << captured.load()
                << ", processed=" << composed.load() << '\n';
      std::cout << "Average ms: infer=" << infer_us.load() / (n * 1000.0)
                << ", compose=" << compose_us.load() / (n * 1000.0)
                << ", preview=" << preview_us.load() / (n * 1000.0)
                << ", total=" << (infer_us.load() + compose_us.load() +
                                      preview_us.load()) / (n * 1000.0) << '\n';
      if (composed.load() == 0 || capture_failed.load() != 0) return 6;
    }
  } catch (const Ort::Exception& error) {
    std::cerr << "ONNX Runtime: " << error.what() << '\n';
    return 5;
  }
  return 0;
}
