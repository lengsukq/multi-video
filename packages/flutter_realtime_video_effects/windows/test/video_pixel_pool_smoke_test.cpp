#include "../video_effects_pixel_pool.h"

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

int main() {
  using realtime_video_effects::VideoPixelPool;
  VideoPixelPool pool(3);
  auto a = pool.Acquire(64);
  a->at(0) = 77;
  auto* address_a = a.get();
  auto held = a;
  a.reset();
  auto b = pool.Acquire(64);
  if (b.get() == address_a) return 1; // Still owned by an in-flight frame.
  held.reset();
  auto recycled = pool.Acquire(64);
  if (recycled.get() != address_a) return 2;
  if (recycled->at(0) != 77) return 3;
  recycled.reset();
  pool.Trim();
  auto after_trim = pool.Acquire(64);
  if (after_trim->size() != 64) return 5;

  // Pixel buffer pools must never share mutable storage with a published
  // frame or a Flutter texture that has not yet called release_callback.
  auto pixels = pool.Acquire(4 * 3);
  const std::uint8_t bgra[] = {12, 35, 220, 255,
                               38, 100, 190, 255,
                               90, 66, 50, 255};
  std::copy(std::begin(bgra), std::end(bgra), pixels->begin());
  realtime_processed_video::Frame frame{"probe", pixels, 3, 1, 12, 42, true};
  VideoPixelPool preview_pool(2);
  auto rgba = realtime_video_effects::PreviewRgbaPooled(frame, preview_pool);
  if (!rgba || rgba->at(0) != 220 || rgba->at(1) != 35 ||
      rgba->at(2) != 12 || rgba->at(3) != 255 ||
      rgba->at(4) != 190 || rgba->at(5) != 100 ||
      rgba->at(6) != 38 || rgba->at(7) != 255)
    return 4;
  std::cout << "pooled capture/output/preview buffers valid\n";
  return 0;
}
