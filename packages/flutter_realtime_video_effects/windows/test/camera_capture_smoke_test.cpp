#include "../mf_camera_capture.h"

#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

// Inspect actual device modes before choosing the low-latency Windows format.
void PrintNativeModes() {
  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(initialized)) return;
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    CoUninitialize();
    return;
  }
  Microsoft::WRL::ComPtr<IMFAttributes> attrs;
  if (SUCCEEDED(MFCreateAttributes(&attrs, 1))) {
    attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                   MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    if (SUCCEEDED(MFEnumDeviceSources(attrs.Get(), &devices, &count))) {
      if (count) {
        Microsoft::WRL::ComPtr<IMFMediaSource> source;
        Microsoft::WRL::ComPtr<IMFSourceReader> reader;
        if (SUCCEEDED(devices[0]->ActivateObject(IID_PPV_ARGS(&source))) &&
            SUCCEEDED(MFCreateSourceReaderFromMediaSource(
                source.Get(), nullptr, &reader))) {
          for (DWORD i = 0; i < 64; ++i) {
            Microsoft::WRL::ComPtr<IMFMediaType> type;
            if (FAILED(reader->GetNativeMediaType(
                    MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &type))) break;
            UINT32 w = 0, h = 0, n = 0, d = 1;
            GUID subtype{};
            MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h);
            MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &n, &d);
            type->GetGUID(MF_MT_SUBTYPE, &subtype);
            std::cout << "mode " << i << ": " << w << "x" << h
                      << " @" << (d ? static_cast<double>(n) / d : 0)
                      << "fps fourcc=" << subtype.Data1 << '\n';
          }
        }
      }
      for (UINT32 i = 0; i < count; ++i) devices[i]->Release();
      CoTaskMemFree(devices);
    }
  }
  MFShutdown();
  CoUninitialize();
}

// Device smoke test; captures no persistent images and sends no frames to a
// network. The camera must be available and not in use by another app.
int main() {
  PrintNativeModes();
  const auto devices = realtime_video_effects::FindCameras();
  std::cout << "Media Foundation cameras: " << devices.size() << '\n';
  if (devices.empty()) return 1;
  bool any_working = false;
  for (std::size_t i = 0; i < devices.size(); ++i) {
    std::atomic<int> frames{0};
    std::atomic<bool> failed{false};
    std::atomic<std::uint64_t> first_ns{0};
    std::atomic<std::uint64_t> last_ns{0};
    const auto started = std::chrono::steady_clock::now();
    {
      realtime_video_effects::CameraCapture capture;
      capture.Start("probe", devices[i].id,
          [&](const realtime_processed_video::Frame& frame) {
            if (frame.IsValid()) {
              const auto timestamp = static_cast<std::uint64_t>(
                  std::chrono::duration_cast<std::chrono::nanoseconds>(
                      std::chrono::steady_clock::now() - started).count());
              std::uint64_t zero = 0;
              first_ns.compare_exchange_strong(zero, timestamp);
              last_ns.store(timestamp);
              frames.fetch_add(1);
            }
          },
          [&](const std::string& reason) {
            std::cerr << "Camera " << i << " failure: " << reason << '\n';
            failed.store(true);
          });
      std::this_thread::sleep_for(std::chrono::milliseconds(1700));
      capture.Stop();
    }
    std::cout << "Camera " << i << ": " << frames.load() << " frames"
              << (failed.load() ? " (failed)" : "");
    const auto captured = frames.load();
    if (captured > 1 && last_ns.load() > first_ns.load())
      std::cout << ", active fps="
                << static_cast<double>(captured - 1) * 1e9 /
                       (last_ns.load() - first_ns.load())
                << ", first-frame ms=" << first_ns.load() / 1e6;
    std::cout << '\n';
    any_working |= frames.load() > 0;
  }
  return any_working ? 0 : 2;
}
