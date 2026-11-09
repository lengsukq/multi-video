#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include "processed_video_frame_hub.h"

namespace realtime_video_effects {

// Bounded Windows-only allocation cache for 720p/1080p CPU pixel buffers.
// Every in-flight frame owns its buffer exclusively. A buffer becomes
// reusable only when the LAST shared_ptr (including Flutter's texture
// release callback or the RTC callback) releases it.
class VideoPixelPool final {
 public:
  explicit VideoPixelPool(std::size_t max_cached = 3)
      : state_(std::make_shared<State>(max_cached)) {}

  std::shared_ptr<std::vector<std::uint8_t>> Acquire(std::size_t bytes) {
    auto state = state_;
    std::unique_ptr<std::vector<std::uint8_t>> reuse;
    {
      std::lock_guard<std::mutex> guard(state->mutex);
      for (auto it = state->available.begin(); it != state->available.end(); ++it) {
        if ((*it)->size() == bytes) {
          reuse = std::move(*it);
          state->available.erase(it);
          break;
        }
      }
    }
    if (!reuse) reuse = std::make_unique<std::vector<std::uint8_t>>(bytes);
    return std::shared_ptr<std::vector<std::uint8_t>>(
        reuse.release(), [state, bytes](std::vector<std::uint8_t>* raw) {
          std::unique_ptr<std::vector<std::uint8_t>> returned(raw);
          if (bytes > 1920u * 1080u * 4u || returned->size() != bytes) return;
          std::lock_guard<std::mutex> guard(state->mutex);
          if (state->available.size() < state->max_cached)
            state->available.push_back(std::move(returned));
        });
  }

  // Discard idle buffers when an effect is disabled. In-flight frame memory
  // remains valid until its final reader releases the shared_ptr.
  void Trim() {
    std::lock_guard<std::mutex> guard(state_->mutex);
    state_->available.clear();
  }

 private:
  struct State {
    explicit State(std::size_t max) : max_cached(max) {
      available.reserve(max_cached);
    }
    std::mutex mutex;
    std::vector<std::unique_ptr<std::vector<std::uint8_t>>> available;
    std::size_t max_cached = 3;
  };
  std::shared_ptr<State> state_;
};

inline std::shared_ptr<const std::vector<std::uint8_t>> PreviewRgbaPooled(
    const realtime_processed_video::Frame& frame, VideoPixelPool& pool) {
  if (!frame.IsValid()) return {};
  auto output = pool.Acquire(static_cast<std::size_t>(frame.width) *
                             frame.height * 4);
  for (std::uint32_t y = 0; y < frame.height; ++y) {
    const auto* src = frame.pixels->data() +
        static_cast<std::size_t>(y) * frame.stride;
    auto* dst = output->data() + static_cast<std::size_t>(y) * frame.width * 4;
    for (std::uint32_t x = 0; x < frame.width; ++x) {
      dst[x * 4 + 0] = src[x * 4 + 2];
      dst[x * 4 + 1] = src[x * 4 + 1];
      dst[x * 4 + 2] = src[x * 4 + 0];
      dst[x * 4 + 3] = src[x * 4 + 3];
    }
  }
  return output;
}

}  // namespace realtime_video_effects
