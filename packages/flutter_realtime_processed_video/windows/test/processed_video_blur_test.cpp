#include "../include/processed_video_compositor.h"

#include <cassert>
#include <cstdint>
#include <memory>
#include <vector>

using namespace realtime_processed_video;

// Slow reference from the original two-pass blur. Used only in tests so that
// the O(width*height) prefix-sum implementation can be checked byte-for-byte.
static std::vector<std::uint8_t> ReferenceBlur(const Frame& frame, int radius) {
  const auto w = frame.width, h = frame.height;
  std::vector<std::uint8_t> tmp(static_cast<std::size_t>(w) * h * 4);
  std::vector<std::uint8_t> output(tmp.size());
  radius = std::clamp(radius, 1, 32);
  for (std::uint32_t y = 0; y < h; ++y) {
    for (std::uint32_t x = 0; x < w; ++x) {
      const auto left = x > static_cast<std::uint32_t>(radius) ? x - radius : 0;
      const auto right = std::min(w - 1, x + static_cast<std::uint32_t>(radius));
      for (int c = 0; c < 3; ++c) {
        unsigned total = 0;
        for (auto xx = left; xx <= right; ++xx) {
          total += frame.pixels->at(static_cast<std::size_t>(y) * frame.stride +
                                     xx * 4 + c);
        }
        tmp[(static_cast<std::size_t>(y) * w + x) * 4 + c] =
            static_cast<std::uint8_t>(total / (right - left + 1));
      }
      tmp[(static_cast<std::size_t>(y) * w + x) * 4 + 3] = 255;
    }
  }
  for (std::uint32_t y = 0; y < h; ++y) {
    const auto top = y > static_cast<std::uint32_t>(radius) ? y - radius : 0;
    const auto bottom = std::min(h - 1, y + static_cast<std::uint32_t>(radius));
    for (std::uint32_t x = 0; x < w; ++x) {
      for (int c = 0; c < 3; ++c) {
        unsigned total = 0;
        for (auto yy = top; yy <= bottom; ++yy) {
          total += tmp[(static_cast<std::size_t>(yy) * w + x) * 4 + c];
        }
        output[(static_cast<std::size_t>(y) * w + x) * 4 + c] =
            static_cast<std::uint8_t>(total / (bottom - top + 1));
      }
      output[(static_cast<std::size_t>(y) * w + x) * 4 + 3] = 255;
    }
  }
  return output;
}

int main() {
  assert(BlurBgra(Frame{}, 16).empty());
  for (std::uint32_t width : {1u, 2u, 3u, 5u, 13u, 81u}) {
    for (std::uint32_t height : {1u, 2u, 4u, 7u, 19u}) {
      // Test non-contiguous camera buffer rows, edge pixels and odd widths.
      const auto stride = width * 4 + 12;
      auto pixels = std::make_shared<std::vector<std::uint8_t>>(
          static_cast<std::size_t>(stride) * height);
      for (std::size_t i = 0; i < pixels->size(); ++i) {
        (*pixels)[i] = static_cast<std::uint8_t>((i * 71 + 19) % 256);
      }
      const Frame frame{"test", pixels, width, height, stride, 123, false};
      assert(frame.IsValid());
      for (int radius : {0, 1, 2, 8, 24, 32, 90}) {
        assert(BlurBgra(frame, radius) == ReferenceBlur(frame, radius));
      }
    }
  }
}
