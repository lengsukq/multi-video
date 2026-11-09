#include "../mf_camera_capture.h"
#include "../pphumanseg_inference.h"
#include "../d3d11_video_compositor.h"
#include <psapi.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <string>

using realtime_processed_video::BackgroundMode;
using realtime_processed_video::BackgroundSettings;
using realtime_processed_video::Frame;
using realtime_processed_video::PersonMask;

int main(int argc, char** argv) {
  if (argc < 2 || argc > 3) {
    std::cerr << "usage: effects_pipeline_smoke_test <model.onnx> [low|medium|high]\n";
    return 2;
  }
  const int length = MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, nullptr, 0);
  if (length < 2) return 2;
  std::wstring model(length, 0);
  MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, model.data(), length);
  model.resize(length - 1);

  realtime_video_effects::PersonSegmenter segmenter;
  if (!segmenter.Open(model)) {
    std::cerr << "Could not load human segmentation model\n";
    return 3;
  }
  realtime_video_effects::WindowsGpuCompositor gpu;
  realtime_video_effects::VideoPixelPool preview_buffers;
  auto settings = std::make_shared<BackgroundSettings>();
  settings->mode = BackgroundMode::blur;
  const std::string strength = argc == 3 ? argv[2] : "medium";
  if (strength != "low" && strength != "medium" && strength != "high") {
    std::cerr << "Invalid blur strength\n";
    return 2;
  }
  settings->blur_radius =
      strength == "low" ? 8 : strength == "high" ? 24 : 16;
  std::mutex mutex;
  std::condition_variable pending_cv;
  Frame pending;
  std::atomic<int> received{0};
  std::atomic<bool> camera_failed{false};
  realtime_video_effects::CameraCapture camera;
  camera.Start("camera-pipeline-test", L"",
      [&](const Frame& frame) {
        {
          std::lock_guard<std::mutex> guard(mutex);
          pending = frame;
        }
        received.fetch_add(1);
        pending_cv.notify_one();
      },
      [&](const std::string& reason) {
        std::cerr << "Camera failed: " << reason << "\n";
        camera_failed.store(true);
        pending_cv.notify_all();
      });
  const auto start = std::chrono::steady_clock::now();
  auto first_output = std::chrono::steady_clock::time_point{};
  auto last_output = first_output;
  auto last_inference = first_output;
  PersonMask mask;
  std::uint32_t width = 0, height = 0;
  int output_count = 0, inference_count = 0, gpu_count = 0;
  double total_gpu_ms = 0;
  double total_infer_ms = 0, total_compose_ms = 0, total_preview_ms = 0;
  FILETIME created{}, exited{}, kernel_before{}, user_before{};
  GetProcessTimes(GetCurrentProcess(), &created, &exited,
                  &kernel_before, &user_before);
  double mean_person_alpha = 0;
  double percent_confident_foreground = 0;
  float max_person_alpha = 0;
  while (std::chrono::steady_clock::now() - start <
         std::chrono::seconds(8) && !camera_failed.load()) {
    Frame frame;
    {
      std::unique_lock<std::mutex> guard(mutex);
      pending_cv.wait_for(guard, std::chrono::milliseconds(250), [&] {
        return pending.IsValid() || camera_failed.load();
      });
      frame = std::move(pending);
      pending = {};
    }
    if (!frame.IsValid()) continue;
    width = frame.width;
    height = frame.height;
    const auto now = std::chrono::steady_clock::now();
    if (!mask.Valid() || now - last_inference > std::chrono::milliseconds(83)) {
      const auto infer_started = std::chrono::steady_clock::now();
      if (!segmenter.Infer(frame, &mask)) {
        std::cerr << "Segmentation failed\n";
        camera.Stop();
        return 4;
      }
      total_infer_ms += std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - infer_started).count();
      ++inference_count;
      double total_alpha = 0;
      std::size_t confident_foreground = 0;
      for (const float alpha : mask.alpha) {
        total_alpha += alpha;
        max_person_alpha = std::max(max_person_alpha, alpha);
        confident_foreground += alpha > 0.85f;
      }
      mean_person_alpha += total_alpha / mask.alpha.size();
      percent_confident_foreground +=
          100.0 * confident_foreground / mask.alpha.size();
      last_inference = std::chrono::steady_clock::now();
    }
    Frame out;
    const auto before = std::chrono::steady_clock::now();
    bool used_gpu = gpu.Compose(frame, mask, settings, &out);
    if (!used_gpu &&
        !realtime_processed_video::Compose(frame, mask, *settings, &out)) {
      std::cerr << "Composition failed\n";
      camera.Stop();
      return 5;
    }
    if (used_gpu) {
      ++gpu_count;
      total_gpu_ms += std::chrono::duration<double, std::milli>(
          std::chrono::steady_clock::now() - before).count();
    }
    total_compose_ms += std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - before).count();
    if (!out.IsValid() || !out.effect_applied) {
      std::cerr << "Invalid output\n";
      camera.Stop();
      return 6;
    }
    const auto preview_started = std::chrono::steady_clock::now();
    const auto preview = realtime_video_effects::PreviewRgbaPooled(
        out, preview_buffers);
    if (!preview || preview->size() !=
            static_cast<std::size_t>(frame.width) * frame.height * 4) {
      camera.Stop();
      return 8;
    }
    total_preview_ms += std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - preview_started).count();
    last_output = std::chrono::steady_clock::now();
    if (first_output == std::chrono::steady_clock::time_point{})
      first_output = last_output;
    ++output_count;
  }
  camera.Stop();
  FILETIME kernel_after{}, user_after{};
  GetProcessTimes(GetCurrentProcess(), &created, &exited,
                  &kernel_after, &user_after);
  const auto filetime_to_ms = [](const FILETIME& time) {
    ULARGE_INTEGER value{};
    value.LowPart = time.dwLowDateTime;
    value.HighPart = time.dwHighDateTime;
    return static_cast<double>(value.QuadPart) / 10000.0;
  };
  const auto total_cpu_ms =
      filetime_to_ms(kernel_after) + filetime_to_ms(user_after) -
      filetime_to_ms(kernel_before) - filetime_to_ms(user_before);
  PROCESS_MEMORY_COUNTERS memory{};
  memory.cb = sizeof(memory);
  GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory));
  const auto seconds = std::chrono::duration<double>(
      last_output - first_output).count();
  std::cout << "strength=" << strength << " camera " << width << "x" << height
            << " received=" << received.load()
            << " segmented=" << inference_count
            << " output=" << output_count
            << " gpu=" << gpu_count
            << " output_fps="
            << (seconds > 0 ? (output_count - 1) / seconds : 0)
            << " gpu_ms="
            << (gpu_count > 0 ? total_gpu_ms / gpu_count : 0)
            << " inference_avg_ms="
            << (inference_count ? total_infer_ms / inference_count : 0)
            << " composition_avg_ms="
            << (output_count ? total_compose_ms / output_count : 0)
            << " preview_avg_ms="
            << (output_count ? total_preview_ms / output_count : 0)
            << " cpu_core_equivalent="
            << (total_cpu_ms / 8000.0)
            << " peak_working_set_mb="
            << (memory.PeakWorkingSetSize / 1048576.0)
            << " person_alpha_mean="
            << (inference_count ? mean_person_alpha / inference_count : 0)
            << " person_alpha_max=" << max_person_alpha
            << " confident_person_coverage_percent="
            << (inference_count ? percent_confident_foreground / inference_count : 0)
            << "\n";
  return output_count >= 50 && gpu_count >= 10 ? 0 : 7;
}
