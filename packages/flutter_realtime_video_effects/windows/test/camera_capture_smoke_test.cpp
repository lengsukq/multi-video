#include "../mf_camera_capture.h"

#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

// Device smoke test; captures no persistent images and sends no frames to a
// network. The camera must be available and not in use by another app.
int main() {
  const auto devices = realtime_video_effects::FindCameras();
  std::cout << "Media Foundation cameras: " << devices.size() << '\n';
  if (devices.empty()) return 1;
  bool any_working = false;
  for (std::size_t i = 0; i < devices.size(); ++i) {
    std::atomic<int> frames{0};
    std::atomic<bool> failed{false};
    {
      realtime_video_effects::CameraCapture capture;
      capture.Start("probe", devices[i].id,
          [&](const realtime_processed_video::Frame& frame) {
            if (frame.IsValid()) frames.fetch_add(1);
          },
          [&](const std::string& reason) {
            std::cerr << "Camera " << i << " failure: " << reason << '\n';
            failed.store(true);
          });
      std::this_thread::sleep_for(std::chrono::milliseconds(1700));
      capture.Stop();
    }
    std::cout << "Camera " << i << ": " << frames.load() << " frames"
              << (failed.load() ? " (failed)" : "") << '\n';
    any_working |= frames.load() > 0;
  }
  return any_working ? 0 : 2;
}
