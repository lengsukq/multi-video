#include "../d3d11_video_compositor.h"
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

using namespace realtime_processed_video;
using realtime_video_effects::WindowsGpuCompositor;

int main() {
  constexpr std::uint32_t w = 1280, h = 720;
  const auto low_plan = realtime_video_effects::ChooseWindowsBlurPlan(8, 4);
  const auto medium_plan = realtime_video_effects::ChooseWindowsBlurPlan(16, 4);
  const auto high_plan = realtime_video_effects::ChooseWindowsBlurPlan(24, 4);
  if (low_plan.radius != 2 || low_plan.passes != 1 ||
      medium_plan.radius != 8 || medium_plan.passes != 2 ||
      high_plan.radius != 12 || high_plan.passes != 3) {
    std::cerr << "Unexpected Windows blur quality profile\n";
    return 13;
  }
  auto pixels = std::make_shared<std::vector<std::uint8_t>>(w * h * 4);
  for (std::uint32_t y = 0; y < h; ++y) {
    for (std::uint32_t x = 0; x < w; ++x) {
      const auto at = (static_cast<std::size_t>(y) * w + x) * 4;
      (*pixels)[at] = static_cast<std::uint8_t>((x + y) % 256);
      (*pixels)[at + 1] = static_cast<std::uint8_t>((x / 3 + y) % 256);
      (*pixels)[at + 2] = static_cast<std::uint8_t>((y / 2) % 256);
      (*pixels)[at + 3] = 255;
    }
  }
  Frame camera{"gpu-probe", pixels, w, h, w * 4, 123456, false};
  PersonMask mask;
  mask.width = mask.height = 192;
  mask.alpha.assign(mask.width * mask.height, 0);
  auto replace = std::make_shared<BackgroundSettings>();
  replace->mode = BackgroundMode::replace_image;
  replace->replacement_width = 320;
  replace->replacement_height = 240;
  replace->replacement_bgra.resize(320 * 240 * 4);
  for (std::size_t i = 0; i < replace->replacement_bgra.size(); i += 4) {
    replace->replacement_bgra[i] = 15;
    replace->replacement_bgra[i + 1] = 90;
    replace->replacement_bgra[i + 2] = 210;
    replace->replacement_bgra[i + 3] = 255;
  }
  WindowsGpuCompositor gpu;
  Frame actual;
  if (!gpu.Compose(camera, mask, replace, &actual)) {
    std::cerr << "GPU replacement unavailable\n";
    return 1;
  }
  Frame expected;
  if (!Compose(camera, mask, *replace, &expected)) return 2;
  std::size_t mismatched = 0;
  for (std::size_t i = 0; i < actual.pixels->size(); ++i)
    if (std::abs(int((*actual.pixels)[i]) - (*expected.pixels)[i]) > 1)
      ++mismatched;
  std::cout << "replace mismatched channels: " << mismatched << "\n";
  if (mismatched > 100) return 3;

  mask.alpha.assign(mask.width * mask.height, 1);
  if (!gpu.Compose(camera, mask, replace, &actual)) return 4;
  mismatched = 0;
  for (std::size_t i = 0; i < actual.pixels->size(); ++i)
    if (std::abs(int((*actual.pixels)[i]) - (*pixels)[i]) > 1)
      ++mismatched;
  std::cout << "foreground mismatched channels: " << mismatched << "\n";
  if (mismatched > 100) return 5;

  // Regression: test real fractional model probabilities, not just binary
  // masks. Fully recognized people must not be treated as 73%-opaque.
  for (std::uint32_t y = 0; y < mask.height; ++y)
    for (std::uint32_t x = 0; x < mask.width; ++x)
      mask.alpha[static_cast<std::size_t>(y) * mask.width + x] =
          static_cast<float>(x) / (mask.width - 1);
  if (!gpu.Compose(camera, mask, replace, &actual) ||
      !Compose(camera, mask, *replace, &expected)) return 8;
  mismatched = 0;
  for (std::size_t i = 0; i < actual.pixels->size(); ++i) {
    if (std::abs(int((*actual.pixels)[i]) - (*expected.pixels)[i]) > 3)
      ++mismatched;
  }
  std::cout << "soft alpha mismatched channels: " << mismatched << "\n";
  if (mismatched > 100) return 9;

  WindowsGpuCompositor blur_gpu;
  mask.alpha.assign(mask.width * mask.height, 0);
  auto blur = std::make_shared<BackgroundSettings>();
  blur->mode = BackgroundMode::blur;
  blur->blur_radius = 8;
  if (!blur_gpu.Compose(camera, mask, blur, &actual)) {
    std::cerr << "GPU blur unavailable\n";
    return 6;
  }
  Frame cpu_blur;
  if (!Compose(camera, mask, *blur, &cpu_blur)) return 10;
  double blur_mean_error = 0.0;
  for (std::size_t i = 0; i < actual.pixels->size(); i += 4) {
    for (int c = 0; c < 3; ++c)
      blur_mean_error += std::abs(
          int((*actual.pixels)[i + c]) - (*cpu_blur.pixels)[i + c]);
  }
  blur_mean_error /= static_cast<double>(w) * h * 3;
  std::cout << "blur CPU-vs-GPU mean channel error: " << blur_mean_error
            << "\n";
  if (blur_mean_error > 16.0) return 11;
  // Regression: visual strength must actually increase, not just change a
  // UI setting. Alternating 64px strips model recognizable background edges.
  auto striped = std::make_shared<std::vector<std::uint8_t>>(w * h * 4);
  for (std::uint32_t y = 0; y < h; ++y)
    for (std::uint32_t x = 0; x < w; ++x) {
      const auto at = (static_cast<std::size_t>(y) * w + x) * 4;
      const auto value = static_cast<std::uint8_t>((x / 64) % 2 ? 255 : 0);
      (*striped)[at] = (*striped)[at + 1] = (*striped)[at + 2] = value;
      (*striped)[at + 3] = 255;
    }
  const Frame stripe_camera{"gpu-strength", striped, w, h, w * 4, 123457,
                            false};
  double strength_contrast[3]{};
  double strength_frame_ms[3]{};
  const int radii[3] = {8, 16, 24};
  for (int level = 0; level < 3; ++level) {
    WindowsGpuCompositor compositor;
    const auto quality = std::make_shared<BackgroundSettings>();
    quality->mode = BackgroundMode::blur;
    quality->blur_radius = radii[level];
    Frame result;
    // The first frame compiles shaders and constructs GPU resources, and
    // the first eight frames include CPU-vs-GPU fallback calibration.
    // Exclude those one-time costs from steady-state frame latency.
    for (int warm = 0; warm < 12; ++warm)
      if (!compositor.Compose(stripe_camera, mask, quality, &result)) return 14;
    const auto profile_start = std::chrono::steady_clock::now();
    constexpr int frames_per_level = 20;
    for (int run = 0; run < frames_per_level; ++run)
      if (!compositor.Compose(stripe_camera, mask, quality, &result)) return 14;
    strength_frame_ms[level] =
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - profile_start).count() /
        frames_per_level;
    const auto left = (static_cast<std::size_t>(360) * w + 96) * 4;
    const auto right = (static_cast<std::size_t>(360) * w + 160) * 4;
    strength_contrast[level] =
        std::abs(int((*result.pixels)[left]) - (*result.pixels)[right]);
  }
  std::cout << "blur stripe contrast low/medium/high: "
            << strength_contrast[0] << "/" << strength_contrast[1] << "/"
            << strength_contrast[2] << "\n";
  std::cout << "GPU blur avg ms low/medium/high: "
            << strength_frame_ms[0] << "/" << strength_frame_ms[1] << "/"
            << strength_frame_ms[2] << "\n";
  if (!(strength_contrast[0] > strength_contrast[1] + 10 &&
        strength_contrast[1] > strength_contrast[2] + 10)) {
    std::cerr << "Windows blur strengths are not distinguishable\n";
    return 15;
  }
  const auto start = std::chrono::steady_clock::now();
  int runs = 0;
  for (int i = 0; i < 24; ++i) {
    if (!blur_gpu.Compose(camera, mask, blur, &actual)) break;
    ++runs;
  }
  const auto elapsed = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - start).count();
  std::cout << "blur runs=" << runs << " avg=" << elapsed / std::max(1, runs)
            << "ms, effect=" << actual.effect_applied << "\n";
  blur_gpu.Release();
  if (!blur_gpu.Compose(camera, mask, blur, &actual) ||
      !actual.IsValid() || !actual.effect_applied) {
    std::cerr << "GPU compositor failed to restart after release\n";
    return 12;
  }
  return runs >= 8 && actual.effect_applied ? 0 : 7;
}
