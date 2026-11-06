#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <vector>

#include "processed_video_frame_hub.h"

namespace realtime_processed_video {

enum class BackgroundMode { none, blur, replace_image };

struct BackgroundSettings {
  BackgroundMode mode = BackgroundMode::none;
  int blur_radius = 12;
  std::vector<std::uint8_t> replacement_bgra;
  std::uint32_t replacement_width = 0;
  std::uint32_t replacement_height = 0;
};

// Flutter Windows PixelBufferTexture uploads pixels using GL_RGBA. Keep
// provider-facing frames BGRA, but convert the separate preview backing
// buffer once per captured frame to prevent red/blue channel swaps.
inline std::shared_ptr<const std::vector<std::uint8_t>> PreviewRgba(
    const Frame& frame) {
  if (!frame.IsValid()) return {};
  auto pixels = std::make_shared<std::vector<std::uint8_t>>(
      static_cast<std::size_t>(frame.width) * frame.height * 4);
  for (std::uint32_t y = 0; y < frame.height; ++y) {
    for (std::uint32_t x = 0; x < frame.width; ++x) {
      const auto* bgra = frame.pixels->data() +
          static_cast<std::size_t>(y) * frame.stride + x * 4;
      const auto offset =
          (static_cast<std::size_t>(y) * frame.width + x) * 4;
      (*pixels)[offset] = bgra[2];
      (*pixels)[offset + 1] = bgra[1];
      (*pixels)[offset + 2] = bgra[0];
      (*pixels)[offset + 3] = bgra[3];
    }
  }
  return pixels;
}

// The alpha mask is a low-resolution, row-major person probability buffer.
// The inference layer MUST NOT synthesize an all-person mask on failure.
struct PersonMask {
  std::vector<float> alpha;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  bool Valid() const {
    return width && height && width <= 4096 && height <= 4096 &&
           alpha.size() == static_cast<std::size_t>(width) * height;
  }
};

inline std::uint8_t Channel(float value) {
  return static_cast<std::uint8_t>(
      std::max(0.0f, std::min(255.0f, value)));
}

inline float MaskAt(const PersonMask& mask, std::uint32_t x,
                    std::uint32_t y, std::uint32_t width,
                    std::uint32_t height) {
  const float mx = (static_cast<float>(x) + .5f) * mask.width / width - .5f;
  const float my = (static_cast<float>(y) + .5f) * mask.height / height - .5f;
  const float fx = std::max(0.0f, std::min(
      static_cast<float>(mask.width - 1), mx));
  const float fy = std::max(0.0f, std::min(
      static_cast<float>(mask.height - 1), my));
  const auto x0 = static_cast<std::uint32_t>(fx);
  const auto y0 = static_cast<std::uint32_t>(fy);
  const auto x1 = std::min(x0 + 1, mask.width - 1);
  const auto y1 = std::min(y0 + 1, mask.height - 1);
  const float ax = fx - x0, ay = fy - y0;
  const auto sample = [&](std::uint32_t cx, std::uint32_t cy) {
    return mask.alpha[static_cast<std::size_t>(cy) * mask.width + cx];
  };
  const float value =
      (1 - ay) * ((1 - ax) * sample(x0, y0) + ax * sample(x1, y0)) +
      ay * ((1 - ax) * sample(x0, y1) + ax * sample(x1, y1));
  return std::isfinite(value) ? std::clamp(value, 0.0f, 1.0f) : 0.0f;
}

// Separable box blur using row/column prefix sums. Work is O(width * height)
// even for the high-strength blur (radius 24): the previous nested-radius
// implementation could consume most of the MF capture thread at 720p/1080p.
// Prefix sums use 32-bit integers (<= 4096 * 255 per channel). Keep this
// header portable so the same assertions run on macOS/Linux and MSVC.
inline std::vector<std::uint8_t> BlurBgra(const Frame& frame, int radius) {
  if (!frame.IsValid() || frame.width > 4096 || frame.height > 4096) return {};
  const auto w = frame.width, h = frame.height;
  const auto count = static_cast<std::size_t>(w) * h * 4;
  std::vector<std::uint8_t> horizontal(count), blurred(count);
  radius = std::clamp(radius, 1, 32);
  std::vector<unsigned int> sums((static_cast<std::size_t>(w) + 1) * 3);
  for (std::uint32_t y = 0; y < h; ++y) {
    const auto* row = frame.pixels->data() + static_cast<std::size_t>(y) * frame.stride;
    sums[0] = sums[1] = sums[2] = 0;
    for (std::uint32_t x = 0; x < w; ++x) {
      for (int c = 0; c < 3; ++c) {
        sums[(static_cast<std::size_t>(x) + 1) * 3 + c] =
            sums[static_cast<std::size_t>(x) * 3 + c] + row[x * 4 + c];
      }
    }
    for (std::uint32_t x = 0; x < w; ++x) {
      const auto start = x > static_cast<std::uint32_t>(radius) ? x - radius : 0;
      const auto end = std::min(w - 1, x + static_cast<std::uint32_t>(radius));
      for (int c = 0; c < 3; ++c) {
        horizontal[(static_cast<std::size_t>(y) * w + x) * 4 + c] =
            static_cast<std::uint8_t>((
                sums[(static_cast<std::size_t>(end) + 1) * 3 + c] -
                sums[static_cast<std::size_t>(start) * 3 + c]) /
                (end - start + 1));
      }
      horizontal[(static_cast<std::size_t>(y) * w + x) * 4 + 3] = 255;
    }
  }
  sums.resize((static_cast<std::size_t>(h) + 1) * 3);
  for (std::uint32_t x = 0; x < w; ++x) {
    sums[0] = sums[1] = sums[2] = 0;
    for (std::uint32_t y = 0; y < h; ++y) {
      for (int c = 0; c < 3; ++c) {
        sums[(static_cast<std::size_t>(y) + 1) * 3 + c] =
            sums[static_cast<std::size_t>(y) * 3 + c] +
            horizontal[(static_cast<std::size_t>(y) * w + x) * 4 + c];
      }
    }
    for (std::uint32_t y = 0; y < h; ++y) {
      const auto start = y > static_cast<std::uint32_t>(radius) ? y - radius : 0;
      const auto end = std::min(h - 1, y + static_cast<std::uint32_t>(radius));
      for (int c = 0; c < 3; ++c) {
        blurred[(static_cast<std::size_t>(y) * w + x) * 4 + c] =
            static_cast<std::uint8_t>((
                sums[(static_cast<std::size_t>(end) + 1) * 3 + c] -
                sums[static_cast<std::size_t>(start) * 3 + c]) /
                (end - start + 1));
      }
      blurred[(static_cast<std::size_t>(y) * w + x) * 4 + 3] = 255;
    }
  }
  return blurred;
}

// A soft background does not need full-resolution blur intermediate buffers.
// At 720p+, sample an averaged 2x2 image and blur it at half resolution.
// The final composite samples the soft background at full output resolution,
// while keeping the person and person-mask boundaries at their original size.
// Small images retain the exact full-resolution blur behavior.
inline std::vector<std::uint8_t> BlurBgraHalfResolution(
    const Frame& frame, int radius) {
  if (!frame.IsValid() || frame.width < 640 || frame.height < 360)
    return {};
  const auto sw = (frame.width + 1) / 2;
  const auto sh = (frame.height + 1) / 2;
  const auto stride = sw * 4;
  auto sampled = std::make_shared<std::vector<std::uint8_t>>(
      static_cast<std::size_t>(stride) * sh);
  for (std::uint32_t y = 0; y < sh; ++y) {
    const auto iy = y * 2;
    const auto* row0 = frame.pixels->data() +
        static_cast<std::size_t>(iy) * frame.stride;
    const auto* row1 = frame.pixels->data() +
        static_cast<std::size_t>(std::min(iy + 1, frame.height - 1)) *
            frame.stride;
    auto* out = sampled->data() + static_cast<std::size_t>(y) * stride;
    for (std::uint32_t x = 0; x < sw; ++x) {
      const auto ix = x * 2;
      const auto nx = std::min(ix + 1, frame.width - 1);
      for (int c = 0; c < 3; ++c) {
        out[x * 4 + c] = static_cast<std::uint8_t>(
            (static_cast<unsigned>(row0[ix * 4 + c]) +
             row0[nx * 4 + c] + row1[ix * 4 + c] +
             row1[nx * 4 + c] + 2) / 4);
      }
      out[x * 4 + 3] = 255;
    }
  }
  return BlurBgra(Frame{frame.source_id, sampled, sw, sh, stride,
                        frame.timestamp_ns, frame.effect_applied},
                  std::max(1, (std::clamp(radius, 1, 32) + 1) / 2));
}

// Returns false rather than exposing unsegmented camera pixels whenever the
// requested effect cannot be applied.
inline bool Compose(const Frame& camera, const PersonMask& person,
                    const BackgroundSettings& settings, Frame* output) {
  if (!output || !camera.IsValid() || camera.width > 4096 ||
      camera.height > 4096) return false;
  if (settings.mode != BackgroundMode::none && !person.Valid()) return false;
  const auto pixel_count =
      static_cast<std::size_t>(camera.width) * camera.height;
  const std::size_t stride = static_cast<std::size_t>(camera.width) * 4;
  std::vector<std::uint8_t> background;
  bool half_blur = false;
  std::uint32_t background_width = camera.width;
  if (settings.mode == BackgroundMode::blur) {
    background = BlurBgraHalfResolution(camera, settings.blur_radius);
    half_blur = !background.empty();
    if (half_blur) background_width = (camera.width + 1) / 2;
    else background = BlurBgra(camera, settings.blur_radius);
    if (background.empty()) return false;
  } else if (settings.mode == BackgroundMode::replace_image) {
    if (!settings.replacement_width || !settings.replacement_height ||
        settings.replacement_width > 4096 ||
        settings.replacement_height > 4096 ||
        settings.replacement_bgra.size() <
            static_cast<std::size_t>(settings.replacement_width) *
                settings.replacement_height * 4)
      return false;
  }

  auto buffer = std::make_shared<std::vector<std::uint8_t>>(pixel_count * 4);
  // Compute mask coordinate mapping once, not once per camera pixel. This
  // avoids repeated division, clamping and bilinear lookups at 720p/1080p.
  struct MaskX {
    std::uint32_t left, right;
    float blend;
  };
  std::vector<MaskX> mask_x;
  if (settings.mode != BackgroundMode::none) {
    mask_x.reserve(camera.width);
    for (std::uint32_t x = 0; x < camera.width; ++x) {
      const float fx = std::clamp(
          (static_cast<float>(x) + .5f) * person.width / camera.width - .5f,
          0.0f, static_cast<float>(person.width - 1));
      const auto x0 = static_cast<std::uint32_t>(fx);
      mask_x.push_back({x0, std::min(x0 + 1, person.width - 1), fx - x0});
    }
  }
  const auto rw = settings.replacement_width;
  const auto rh = settings.replacement_height;
  float replace_scale = 1.0f;
  float replace_x_offset = 0.0f, replace_y_offset = 0.0f;
  if (settings.mode == BackgroundMode::replace_image) {
    replace_scale = std::max(
        static_cast<float>(camera.width) / rw,
        static_cast<float>(camera.height) / rh);
    replace_x_offset = (camera.width - rw * replace_scale) * .5f;
    replace_y_offset = (camera.height - rh * replace_scale) * .5f;
  }
  for (std::uint32_t y = 0; y < camera.height; ++y) {
    std::uint32_t y0 = 0, y1 = 0;
    float ay = 0.0f;
    if (settings.mode != BackgroundMode::none) {
      const float fy = std::clamp(
          (static_cast<float>(y) + .5f) * person.height / camera.height - .5f,
          0.0f, static_cast<float>(person.height - 1));
      y0 = static_cast<std::uint32_t>(fy);
      y1 = std::min(y0 + 1, person.height - 1);
      ay = fy - y0;
    }
    const float* mask_top = settings.mode == BackgroundMode::none
        ? nullptr : person.alpha.data() + static_cast<std::size_t>(y0) * person.width;
    const float* mask_bottom = settings.mode == BackgroundMode::none
        ? nullptr : person.alpha.data() + static_cast<std::size_t>(y1) * person.width;
    const auto replacement_y = settings.mode == BackgroundMode::replace_image
        ? std::min(rh - 1, static_cast<std::uint32_t>(std::clamp(
              (y + .5f - replace_y_offset) / replace_scale,
              0.0f, static_cast<float>(rh - 1)))) : 0;
    for (std::uint32_t x = 0; x < camera.width; ++x) {
      const std::size_t at = static_cast<std::size_t>(y) * stride + x * 4;
      const auto* src = camera.pixels->data() +
                        static_cast<std::size_t>(y) * camera.stride + x * 4;
      float alpha = 1.0f;
      if (settings.mode != BackgroundMode::none) {
        const auto& sample = mask_x[x];
        const float a0 = mask_top[sample.left] +
            (mask_top[sample.right] - mask_top[sample.left]) * sample.blend;
        const float a1 = mask_bottom[sample.left] +
            (mask_bottom[sample.right] - mask_bottom[sample.left]) * sample.blend;
        alpha = std::clamp(a0 + (a1 - a0) * ay, 0.0f, 1.0f);
      }
      const std::uint8_t* bg = nullptr;
      if (settings.mode == BackgroundMode::blur) {
        // A blurred image is low-frequency; adjacent output pixels can reuse
        // the same half-resolution background pixel without visible aliasing.
        bg = half_blur
            ? background.data() +
                (static_cast<std::size_t>(y / 2) * background_width + x / 2) * 4
            : background.data() + at;
      } else if (settings.mode == BackgroundMode::replace_image) {
        // Fill/cover framing, centered and aspect-preserving.
        const auto rx = std::min(rw - 1,
            static_cast<std::uint32_t>(std::clamp(
                (x + .5f - replace_x_offset) / replace_scale,
                0.0f, static_cast<float>(rw - 1))));
        bg = settings.replacement_bgra.data() +
             (static_cast<std::size_t>(replacement_y) * rw + rx) * 4;
      }
      if (bg) {
        // Quantize alpha once per pixel and blend all channels using fixed
        // point. This keeps fully-opaque/transparent pixels exact while
        // avoiding three float conversions and clamps per pixel at 720p.
        const auto opacity = static_cast<std::uint32_t>(
            std::clamp(alpha, 0.0f, 1.0f) * 256.0f + .5f);
        const auto inverse = 256u - opacity;
        for (int c = 0; c < 3; ++c) {
          (*buffer)[at + c] = static_cast<std::uint8_t>(
              (opacity * src[c] + inverse * bg[c] + 128u) >> 8);
        }
      } else {
        (*buffer)[at] = src[0];
        (*buffer)[at + 1] = src[1];
        (*buffer)[at + 2] = src[2];
      }
      (*buffer)[at + 3] = 255;
    }
  }
  *output = Frame{camera.source_id, buffer, camera.width, camera.height,
                  static_cast<std::uint32_t>(stride),
                  camera.timestamp_ns,
                  settings.mode != BackgroundMode::none};
  return true;
}

}  // namespace realtime_processed_video
