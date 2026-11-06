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
