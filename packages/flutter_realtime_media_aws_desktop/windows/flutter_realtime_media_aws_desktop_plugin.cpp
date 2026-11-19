#include "include/flutter_realtime_media_aws_desktop/flutter_realtime_media_aws_desktop_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <dwmapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "processed_video_frame_api.h"

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

#ifndef DWMWA_CLOAKED
#define DWMWA_CLOAKED 14
#endif

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr UINT kWmProcessedFrame = WM_APP + 0x41;
constexpr UINT kWmScreenCaptureEvent = WM_APP + 0x42;
constexpr auto kFrameMinInterval = std::chrono::milliseconds(66);
constexpr uint32_t kMaxScreenCaptureDimension = 1280;

struct RawFrame {
  std::vector<uint8_t> bgra;
  uint32_t width = 0;
  uint32_t height = 0;
  uint64_t timestamp_ns = 0;
};

struct EncodedFrame {
  std::string source_id;
  uint64_t timestamp_ns = 0;
  std::string data_url;
};

struct DisplayTarget {
  std::string id;
  std::string device_name;
  std::string label;
  int left = 0;
  int top = 0;
  int width = 0;
  int height = 0;
  bool primary = false;
};

struct WindowTarget {
  std::string id;
  std::string label;
  HWND hwnd = nullptr;
};

struct ScreenCaptureEvent {
  std::string source_id;
  uint64_t timestamp_ns = 0;
  std::string data_url;
  bool stopped = false;
  std::string reason;
};

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string out(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
      out.data(), size, nullptr, nullptr);
  return out;
}

std::string TrimUtf8(std::string value) {
  while (!value.empty() &&
         std::isspace(static_cast<unsigned char>(value.back()))) {
    value.pop_back();
  }
  size_t first = 0;
  while (first < value.size() &&
         std::isspace(static_cast<unsigned char>(value[first]))) {
    ++first;
  }
  if (first > 0) value.erase(0, first);
  return value;
}

std::string FormatWindowId(HWND hwnd) {
  char buffer[32]{};
  std::snprintf(
      buffer, sizeof(buffer), "window:0x%llx",
      static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(hwnd)));
  return std::string(buffer);
}

std::optional<HWND> ParseWindowTargetId(const std::string& target_id) {
  constexpr const char kPrefix[] = "window:";
  if (target_id.rfind(kPrefix, 0) != 0) return std::nullopt;
  const std::string raw = target_id.substr(sizeof(kPrefix) - 1);
  if (raw.empty() || raw.front() == '-') return std::nullopt;
  char* end = nullptr;
  errno = 0;
  const int base =
      (raw.rfind("0x", 0) == 0 || raw.rfind("0X", 0) == 0) ? 16 : 10;
  const unsigned long long parsed = std::strtoull(raw.c_str(), &end, base);
  if (errno != 0 || end == raw.c_str() || *end != '\0' || parsed == 0) {
    return std::nullopt;
  }
  return reinterpret_cast<HWND>(static_cast<uintptr_t>(parsed));
}

std::vector<DisplayTarget> CollectDisplayTargets() {
  struct RawMonitor {
    std::wstring device_name;
    int left = 0;
    int top = 0;
    int width = 0;
    int height = 0;
    bool primary = false;
  };
  std::vector<RawMonitor> raw_monitors;

  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
        auto* list = reinterpret_cast<std::vector<RawMonitor>*>(data);
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        if (!GetMonitorInfoW(monitor, &info)) return TRUE;

        int left = info.rcMonitor.left;
        int top = info.rcMonitor.top;
        int width = info.rcMonitor.right - info.rcMonitor.left;
        int height = info.rcMonitor.bottom - info.rcMonitor.top;

        DEVMODEW dev_mode{};
        dev_mode.dmSize = sizeof(dev_mode);
        if (EnumDisplaySettingsW(
                info.szDevice, ENUM_CURRENT_SETTINGS, &dev_mode) &&
            dev_mode.dmPelsWidth > 0 && dev_mode.dmPelsHeight > 0) {
          if ((dev_mode.dmFields & DM_POSITION) != 0) {
            left = dev_mode.dmPosition.x;
            top = dev_mode.dmPosition.y;
          }
          width = static_cast<int>(dev_mode.dmPelsWidth);
          height = static_cast<int>(dev_mode.dmPelsHeight);
        }

        if (width <= 0 || height <= 0) return TRUE;
        RawMonitor entry;
        entry.device_name = info.szDevice;
        entry.left = left;
        entry.top = top;
        entry.width = width;
        entry.height = height;
        entry.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
        list->push_back(std::move(entry));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&raw_monitors));

  std::stable_sort(
      raw_monitors.begin(), raw_monitors.end(),
      [](const RawMonitor& a, const RawMonitor& b) {
        return a.primary && !b.primary;
      });

  if (raw_monitors.empty()) {
    const int width = GetSystemMetrics(SM_CXSCREEN);
    const int height = GetSystemMetrics(SM_CYSCREEN);
    if (width > 0 && height > 0) {
      raw_monitors.push_back({L"DISPLAY1", 0, 0, width, height, true});
    }
  }

  std::vector<DisplayTarget> targets;
  targets.reserve(raw_monitors.size());
  for (size_t i = 0; i < raw_monitors.size(); ++i) {
    const auto& item = raw_monitors[i];
    DisplayTarget target;
    target.id = "display:" + std::to_string(i + 1);
    target.device_name = WideToUtf8(item.device_name);
    target.left = item.left;
    target.top = item.top;
    target.width = item.width;
    target.height = item.height;
    target.primary = item.primary;
    const std::string dims =
        std::to_string(item.width) + "x" + std::to_string(item.height);
    target.label = raw_monitors.size() == 1
        ? "Main Display (" + dims + ")"
        : "Display " + std::to_string(i + 1) + " (" + dims + ")";
    targets.push_back(std::move(target));
  }
  return targets;
}

std::vector<WindowTarget> CollectWindowTargets() {
  struct EnumContext {
    DWORD current_pid = GetCurrentProcessId();
    std::vector<WindowTarget> windows;
  } ctx;

  EnumWindows(
      [](HWND hwnd, LPARAM param) -> BOOL {
        auto* context = reinterpret_cast<EnumContext*>(param);
        if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;

        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid == context->current_pid) return TRUE;

        const LONG_PTR ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        if ((ex_style & WS_EX_TOOLWINDOW) != 0) return TRUE;
        if (GetWindow(hwnd, GW_OWNER) != nullptr &&
            (ex_style & WS_EX_APPWINDOW) == 0) {
          return TRUE;
        }

        DWORD cloaked = 0;
        if (SUCCEEDED(DwmGetWindowAttribute(
                hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked))) &&
            cloaked != 0) {
          return TRUE;
        }

        const int title_len = GetWindowTextLengthW(hwnd);
        if (title_len <= 0) return TRUE;
        std::wstring wide_title(static_cast<size_t>(title_len) + 1, L'\0');
        const int copied = GetWindowTextW(
            hwnd, wide_title.data(), title_len + 1);
        if (copied <= 0) return TRUE;
        wide_title.resize(static_cast<size_t>(copied));
        const std::string title = TrimUtf8(WideToUtf8(wide_title));
        if (title.empty()) return TRUE;

        RECT rect{};
        if (FAILED(DwmGetWindowAttribute(
                hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &rect, sizeof(rect)))) {
          if (!GetWindowRect(hwnd, &rect)) return TRUE;
        }
        const int width = rect.right - rect.left;
        const int height = rect.bottom - rect.top;
        if (width < 64 || height < 64) return TRUE;

        context->windows.push_back({FormatWindowId(hwnd), title, hwnd});
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ctx));

  return ctx.windows;
}

std::optional<DisplayTarget> ResolveDisplayTarget(const std::string& target_id) {
  const auto displays = CollectDisplayTargets();
  if (displays.empty()) return std::nullopt;
  if (target_id.empty()) return displays.front();
  for (const auto& item : displays) {
    if (item.id == target_id ||
        (!item.device_name.empty() &&
         target_id == "display:" + item.device_name)) {
      return item;
    }
  }
  return std::nullopt;
}

bool CaptureDisplayFrame(
    const DisplayTarget& target,
    uint64_t timestamp_ns,
    RawFrame* out_frame) {
  if (!out_frame || target.width <= 0 || target.height <= 0 ||
      target.width > 16384 || target.height > 16384) {
    return false;
  }
  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = target.width;
  bmi.bmiHeader.biHeight = -target.height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(
      screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_obj = SelectObject(mem_dc, dib);
  const BOOL copied = BitBlt(
      mem_dc, 0, 0, target.width, target.height,
      screen_dc, target.left, target.top, SRCCOPY | CAPTUREBLT);
  if (copied) {
    CURSORINFO cursor_info{};
    cursor_info.cbSize = sizeof(cursor_info);
    if (GetCursorInfo(&cursor_info) &&
        (cursor_info.flags & CURSOR_SHOWING) != 0 &&
        cursor_info.hCursor != nullptr) {
      int cursor_x = cursor_info.ptScreenPos.x - target.left;
      int cursor_y = cursor_info.ptScreenPos.y - target.top;
      ICONINFO icon_info{};
      if (GetIconInfo(cursor_info.hCursor, &icon_info)) {
        cursor_x -= static_cast<int>(icon_info.xHotspot);
        cursor_y -= static_cast<int>(icon_info.yHotspot);
        if (icon_info.hbmMask) DeleteObject(icon_info.hbmMask);
        if (icon_info.hbmColor) DeleteObject(icon_info.hbmColor);
      }
      if (cursor_x >= -64 && cursor_y >= -64 &&
          cursor_x < target.width + 64 && cursor_y < target.height + 64) {
        DrawIconEx(
            mem_dc, cursor_x, cursor_y, cursor_info.hCursor,
            0, 0, 0, nullptr, DI_NORMAL);
      }
    }
    GdiFlush();
    const size_t byte_count =
        static_cast<size_t>(target.width) * static_cast<size_t>(target.height) * 4;
    out_frame->width = static_cast<uint32_t>(target.width);
    out_frame->height = static_cast<uint32_t>(target.height);
    out_frame->timestamp_ns = timestamp_ns;
    out_frame->bgra.resize(byte_count);
    std::memcpy(out_frame->bgra.data(), bits, byte_count);
  }

  SelectObject(mem_dc, old_obj);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return copied == TRUE;
}

bool CaptureWindowFrame(
    HWND hwnd,
    uint64_t timestamp_ns,
    RawFrame* out_frame,
    bool* out_window_closed) {
  if (out_window_closed) *out_window_closed = false;
  if (!hwnd || !IsWindow(hwnd)) {
    if (out_window_closed) *out_window_closed = true;
    return false;
  }
  if (IsIconic(hwnd)) {
    // Keep the last rendered frame while minimized instead of terminating share.
    return false;
  }
  if (!IsWindowVisible(hwnd)) {
    if (out_window_closed) *out_window_closed = true;
    return false;
  }

  RECT rect{};
  if (!GetWindowRect(hwnd, &rect)) return false;
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width < 2 || height < 2 || width > 16384 || height > 16384) {
    return false;
  }

  HDC screen_dc = GetDC(nullptr);
  if (!screen_dc) return false;
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  if (!mem_dc) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HBITMAP dib = CreateDIBSection(
      screen_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!dib || !bits) {
    if (dib) DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  HGDIOBJ old_obj = SelectObject(mem_dc, dib);
  BOOL captured = PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT);
  if (!captured) {
    captured = PrintWindow(hwnd, mem_dc, 0);
  }
  if (!captured) {
    HDC window_dc = GetWindowDC(hwnd);
    if (window_dc) {
      captured = BitBlt(
          mem_dc, 0, 0, width, height, window_dc, 0, 0, SRCCOPY);
      ReleaseDC(hwnd, window_dc);
    }
  }

  if (captured && out_frame) {
    GdiFlush();
    const size_t byte_count =
        static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    out_frame->width = static_cast<uint32_t>(width);
    out_frame->height = static_cast<uint32_t>(height);
    out_frame->timestamp_ns = timestamp_ns;
    out_frame->bgra.resize(byte_count);
    std::memcpy(out_frame->bgra.data(), bits, byte_count);
  }

  SelectObject(mem_dc, old_obj);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
  return captured == TRUE;
}

std::string EncodeBase64(const uint8_t* data, size_t length) {
  static constexpr char kAlphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  out.reserve(((length + 2) / 3) * 4);
  size_t i = 0;
  while (i + 3 <= length) {
    const uint32_t triple = (static_cast<uint32_t>(data[i]) << 16) |
                            (static_cast<uint32_t>(data[i + 1]) << 8) |
                            static_cast<uint32_t>(data[i + 2]);
    out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 6) & 0x3F]);
    out.push_back(kAlphabet[triple & 0x3F]);
    i += 3;
  }
  const size_t remaining = length - i;
  if (remaining == 1) {
    const uint32_t triple = static_cast<uint32_t>(data[i]) << 16;
    out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
    out.push_back('=');
    out.push_back('=');
  } else if (remaining == 2) {
    const uint32_t triple = (static_cast<uint32_t>(data[i]) << 16) |
                            (static_cast<uint32_t>(data[i + 1]) << 8);
    out.push_back(kAlphabet[(triple >> 18) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 12) & 0x3F]);
    out.push_back(kAlphabet[(triple >> 6) & 0x3F]);
    out.push_back('=');
  }
  return out;
}

bool EncodeBgraToJpegDataUrl(
    IWICImagingFactory* factory,
    const RawFrame& frame,
    uint32_t max_dimension,
    std::string* out_data_url) {
  if (!factory || frame.width == 0 || frame.height == 0 || frame.bgra.empty()) {
    return false;
  }
  uint32_t target_width = frame.width;
  uint32_t target_height = frame.height;
  if (max_dimension > 0) {
    const uint32_t longest = std::max(frame.width, frame.height);
    const double scale = longest > max_dimension
        ? static_cast<double>(max_dimension) / static_cast<double>(longest)
        : 1.0;
    const auto scaled_w =
        static_cast<uint32_t>(std::lround(static_cast<double>(frame.width) * scale));
    const auto scaled_h =
        static_cast<uint32_t>(std::lround(static_cast<double>(frame.height) * scale));
    target_width = std::max<uint32_t>(2, (scaled_w / 2) * 2);
    target_height = std::max<uint32_t>(2, (scaled_h / 2) * 2);
  }

  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return false;

  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &encoder))) {
    return false;
  }
  if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
    return false;
  }

  ComPtr<IWICBitmapFrameEncode> frame_encode;
  ComPtr<IPropertyBag2> props;
  if (FAILED(encoder->CreateNewFrame(&frame_encode, &props))) return false;
  if (props) {
    PROPBAG2 option{};
    option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
    VARIANT quality;
    VariantInit(&quality);
    quality.vt = VT_R4;
    quality.fltVal = 0.72f;
    props->Write(1, &option, &quality);
    VariantClear(&quality);
  }
  if (FAILED(frame_encode->Initialize(props.Get()))) return false;
  if (FAILED(frame_encode->SetSize(target_width, target_height))) return false;

  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat24bppBGR;
  if (FAILED(frame_encode->SetPixelFormat(&pixel_format))) return false;

  ComPtr<IWICBitmap> bitmap;
  const UINT stride = frame.width * 4;
  if (FAILED(factory->CreateBitmapFromMemory(
          frame.width,
          frame.height,
          GUID_WICPixelFormat32bppBGRA,
          stride,
          static_cast<UINT>(frame.bgra.size()),
          const_cast<BYTE*>(frame.bgra.data()),
          &bitmap))) {
    return false;
  }

  ComPtr<IWICBitmapSource> source_to_write = bitmap;
  if (target_width != frame.width || target_height != frame.height) {
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler))) return false;
    if (FAILED(scaler->Initialize(
            bitmap.Get(),
            target_width,
            target_height,
            WICBitmapInterpolationModeLinear))) {
      return false;
    }
    source_to_write = scaler;
  }

  if (FAILED(frame_encode->WriteSource(source_to_write.Get(), nullptr))) {
    return false;
  }
  if (FAILED(frame_encode->Commit())) return false;
  if (FAILED(encoder->Commit())) return false;

  HGLOBAL hglobal = nullptr;
  if (FAILED(GetHGlobalFromStream(stream.Get(), &hglobal)) || !hglobal) {
    return false;
  }
  const SIZE_T byte_size = GlobalSize(hglobal);
  void* locked = GlobalLock(hglobal);
  if (!locked || byte_size == 0) {
    if (locked) GlobalUnlock(hglobal);
    return false;
  }
  *out_data_url =
      "data:image/jpeg;base64," +
      EncodeBase64(static_cast<const uint8_t*>(locked), byte_size);
  GlobalUnlock(hglobal);
  return true;
}

class AwsDesktopWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto channel =
        std::make_unique<flutter::MethodChannel<EncodableValue>>(
            registrar->messenger(),
            "com.oneplusdream.flutter_realtime_media_aws_desktop/windows",
            &flutter::StandardMethodCodec::GetInstance());
    auto plugin = std::make_unique<AwsDesktopWindowsPlugin>(channel.get());
    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });
    plugin->channel_ = std::move(channel);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit AwsDesktopWindowsPlugin(
      flutter::MethodChannel<EncodableValue>* channel)
      : raw_channel_(channel) {
    CreateMessageWindow();
  }

  ~AwsDesktopWindowsPlugin() override {
    StopAllScreenCaptures();
    UnsubscribeProcessedVideo();
    DestroyMessageWindow();
  }

 private:
  struct ApiSymbols {
    RealtimeProcessedSubscribe subscribe = nullptr;
    RealtimeProcessedUnsubscribe unsubscribe = nullptr;
    RealtimeProcessedReportFailure report_failure = nullptr;
    bool valid() const { return subscribe != nullptr && unsubscribe != nullptr; }
  };

  struct ScreenCaptureWorker {
    std::string source_id;
    std::string target_id;
    bool is_window = false;
    HWND target_hwnd = nullptr;
    DisplayTarget display_target;
    std::mutex mutex;
    std::condition_variable cv;
    bool running = true;
    std::thread thread;
  };

  static ApiSymbols ResolveProcessedVideoSymbols() {
    ApiSymbols symbols;
    HMODULE modules[4] = {
        GetModuleHandleA("flutter_realtime_video_effects_plugin.dll"),
        GetModuleHandleA("flutter_realtime_sdk_effects_plugin.dll"),
        GetModuleHandleA("flutter_realtime_sdk_plugin.dll"),
        GetModuleHandleA(nullptr),
    };
    for (HMODULE mod : modules) {
      if (!mod) continue;
      auto sub = reinterpret_cast<RealtimeProcessedSubscribe>(
          GetProcAddress(mod, "RealtimeProcessedVideoSubscribe"));
      auto unsub = reinterpret_cast<RealtimeProcessedUnsubscribe>(
          GetProcAddress(mod, "RealtimeProcessedVideoUnsubscribe"));
      auto report = reinterpret_cast<RealtimeProcessedReportFailure>(
          GetProcAddress(mod, "RealtimeProcessedVideoReportFailure"));
      if (sub && unsub) {
        symbols.subscribe = sub;
        symbols.unsubscribe = unsub;
        symbols.report_failure = report;
        return symbols;
      }
    }
    return symbols;
  }

  void CreateMessageWindow() {
    WNDCLASSW wc{};
    wc.lpfnWndProc = &AwsDesktopWindowsPlugin::WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"AwsDesktopWindowsPluginMsgWindow";
    RegisterClassW(&wc);
    message_hwnd_ = CreateWindowExW(
        0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
        wc.hInstance, this);
  }

  void DestroyMessageWindow() {
    if (message_hwnd_) {
      DestroyWindow(message_hwnd_);
      message_hwnd_ = nullptr;
    }
  }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    AwsDesktopWindowsPlugin* self = nullptr;
    if (msg == WM_NCCREATE) {
      auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
      self = static_cast<AwsDesktopWindowsPlugin*>(cs->lpCreateParams);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    } else {
      self = reinterpret_cast<AwsDesktopWindowsPlugin*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    }
    if (self && msg == kWmProcessedFrame) {
      self->DispatchEncodedFrames();
      return 0;
    }
    if (self && msg == kWmScreenCaptureEvent) {
      self->DispatchScreenCaptureEvents();
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  static std::string LookupStringArg(
      const EncodableMap* args,
      const char* key) {
    if (!args) return {};
    auto it = args->find(EncodableValue(key));
    if (it == args->end()) return {};
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
    return {};
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto& method = call.method_name();
    if (method == "probeProcessedVideoInput") {
      result->Success(EncodableValue(ResolveProcessedVideoSymbols().valid()));
      return;
    }
    if (method == "listScreenShareSources") {
      EncodableList items;
      for (const auto& display : CollectDisplayTargets()) {
        items.emplace_back(EncodableMap{
            {EncodableValue("id"), EncodableValue(display.id)},
            {EncodableValue("name"), EncodableValue(display.label)},
            {EncodableValue("kind"), EncodableValue("display")},
        });
      }
      for (const auto& window : CollectWindowTargets()) {
        items.emplace_back(EncodableMap{
            {EncodableValue("id"), EncodableValue(window.id)},
            {EncodableValue("name"), EncodableValue(window.label)},
            {EncodableValue("kind"), EncodableValue("window")},
        });
      }
      result->Success(EncodableValue(std::move(items)));
      return;
    }
    if (method == "startScreenCapture") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      const std::string source_id = LookupStringArg(args, "sourceId");
      const std::string target_id = LookupStringArg(args, "targetId");
      if (source_id.empty()) {
        result->Error("invalid_argument", "sourceId is required.");
        return;
      }
      std::string error_code;
      std::string error_message;
      if (!StartScreenCapture(
              source_id, target_id, &error_code, &error_message)) {
        result->Error(
            error_code.empty() ? "native_error" : error_code,
            error_message.empty()
                ? "Unable to start Windows screen capture."
                : error_message);
        return;
      }
      result->Success();
      return;
    }
    if (method == "stopScreenCapture") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      const std::string source_id = LookupStringArg(args, "sourceId");
      if (source_id.empty()) {
        StopAllScreenCaptures();
      } else {
        StopScreenCapture(source_id);
      }
      result->Success();
      return;
    }
    if (method == "subscribeProcessedVideo") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      const std::string source_id = LookupStringArg(args, "sourceId");
      if (source_id.empty()) {
        result->Error("invalid_argument", "sourceId is required.");
        return;
      }
      if (!SubscribeProcessedVideo(source_id)) {
        result->Error(
            "unsupported_feature",
            "Windows native processed-video FrameHub is unavailable.");
        return;
      }
      result->Success();
      return;
    }
    if (method == "unsubscribeProcessedVideo") {
      UnsubscribeProcessedVideo();
      result->Success();
      return;
    }
    if (method == "reportProcessedVideoError") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      const std::string source_id = LookupStringArg(args, "sourceId");
      std::string message = LookupStringArg(args, "message");
      if (message.empty()) {
        message = "Windows WebView2 processed video failed.";
      }
      const ApiSymbols symbols = ResolveProcessedVideoSymbols();
      if (!source_id.empty() && symbols.report_failure) {
        symbols.report_failure(source_id.c_str(), message.c_str());
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  }

  bool StartScreenCapture(
      const std::string& source_id,
      const std::string& target_id,
      std::string* out_code,
      std::string* out_message) {
    StopScreenCapture(source_id);

    auto worker = std::make_unique<ScreenCaptureWorker>();
    worker->source_id = source_id;
    worker->target_id = target_id;

    if (target_id.rfind("window:", 0) == 0) {
      const auto parsed = ParseWindowTargetId(target_id);
      if (!parsed.has_value() || !IsWindow(*parsed) ||
          !IsWindowVisible(*parsed)) {
        if (out_code) *out_code = "invalid_argument";
        if (out_message) {
          *out_message = "The selected window is no longer available.";
        }
        return false;
      }
      DWORD pid = 0;
      GetWindowThreadProcessId(*parsed, &pid);
      if (pid == GetCurrentProcessId()) {
        if (out_code) *out_code = "invalid_argument";
        if (out_message) {
          *out_message = "Cannot share this application's own window.";
        }
        return false;
      }
      worker->is_window = true;
      worker->target_hwnd = *parsed;
    } else if (target_id.empty() || target_id.rfind("display:", 0) == 0) {
      const auto resolved = ResolveDisplayTarget(target_id);
      if (!resolved.has_value()) {
        if (out_code) *out_code = "invalid_argument";
        if (out_message) {
          *out_message = "The selected display is no longer available.";
        }
        return false;
      }
      worker->is_window = false;
      worker->display_target = *resolved;
    } else {
      if (out_code) *out_code = "invalid_argument";
      if (out_message) {
        *out_message = "Unsupported Windows screen-share source ID.";
      }
      return false;
    }

    ScreenCaptureWorker* raw_worker = worker.get();
    {
      std::lock_guard<std::mutex> lock(screen_workers_mutex_);
      screen_workers_[source_id] = std::move(worker);
    }
    raw_worker->thread = std::thread([this, raw_worker]() {
      ScreenCaptureLoop(raw_worker);
    });
    return true;
  }

  void StopScreenCapture(const std::string& source_id) {
    std::unique_ptr<ScreenCaptureWorker> worker;
    {
      std::lock_guard<std::mutex> lock(screen_workers_mutex_);
      auto it = screen_workers_.find(source_id);
      if (it == screen_workers_.end()) return;
      worker = std::move(it->second);
      screen_workers_.erase(it);
    }
    if (worker) {
      {
        std::lock_guard<std::mutex> lock(worker->mutex);
        worker->running = false;
      }
      worker->cv.notify_all();
      if (worker->thread.joinable()) {
        worker->thread.join();
      }
    }
    {
      std::lock_guard<std::mutex> lock(screen_events_mutex_);
      pending_screen_frames_.erase(source_id);
      pending_screen_stops_.erase(source_id);
    }
  }

  void StopAllScreenCaptures() {
    std::map<std::string, std::unique_ptr<ScreenCaptureWorker>> workers;
    {
      std::lock_guard<std::mutex> lock(screen_workers_mutex_);
      workers.swap(screen_workers_);
    }
    for (auto& entry : workers) {
      if (!entry.second) continue;
      {
        std::lock_guard<std::mutex> lock(entry.second->mutex);
        entry.second->running = false;
      }
      entry.second->cv.notify_all();
      if (entry.second->thread.joinable()) {
        entry.second->thread.join();
      }
    }
    {
      std::lock_guard<std::mutex> lock(screen_events_mutex_);
      pending_screen_frames_.clear();
      pending_screen_stops_.clear();
    }
  }

  void ScreenCaptureLoop(ScreenCaptureWorker* worker) {
    const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IWICImagingFactory> factory;
    CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&factory));

    for (;;) {
      const auto tick_start = std::chrono::steady_clock::now();
      {
        std::lock_guard<std::mutex> lock(worker->mutex);
        if (!worker->running) break;
      }

      if (factory) {
        const auto now_ns = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                tick_start.time_since_epoch())
                .count());
        RawFrame raw;
        bool window_closed = false;
        const bool captured = worker->is_window
            ? CaptureWindowFrame(
                  worker->target_hwnd, now_ns, &raw, &window_closed)
            : CaptureDisplayFrame(worker->display_target, now_ns, &raw);

        if (window_closed) {
          bool still_running = false;
          {
            std::lock_guard<std::mutex> lock(worker->mutex);
            still_running = worker->running;
            worker->running = false;
          }
          if (still_running) {
            {
              std::lock_guard<std::mutex> lock(screen_events_mutex_);
              pending_screen_frames_.erase(worker->source_id);
              pending_screen_stops_[worker->source_id] = ScreenCaptureEvent{
                  worker->source_id, 0, {}, true, "window_closed"};
            }
            if (message_hwnd_) {
              PostMessageW(message_hwnd_, kWmScreenCaptureEvent, 0, 0);
            }
          }
          break;
        }

        if (captured) {
          std::string data_url;
          if (EncodeBgraToJpegDataUrl(
                  factory.Get(), raw, kMaxScreenCaptureDimension, &data_url)) {
            bool active = false;
            {
              std::lock_guard<std::mutex> lock(worker->mutex);
              active = worker->running;
            }
            if (active) {
              {
                std::lock_guard<std::mutex> lock(screen_events_mutex_);
                pending_screen_frames_[worker->source_id] = ScreenCaptureEvent{
                    worker->source_id,
                    raw.timestamp_ns,
                    std::move(data_url),
                    false,
                    {},
                };
              }
              if (message_hwnd_) {
                PostMessageW(message_hwnd_, kWmScreenCaptureEvent, 0, 0);
              }
            }
          }
        }
      }

      const auto elapsed = std::chrono::steady_clock::now() - tick_start;
      if (elapsed < kFrameMinInterval) {
        std::unique_lock<std::mutex> lock(worker->mutex);
        worker->cv.wait_for(
            lock, kFrameMinInterval - elapsed,
            [worker]() { return !worker->running; });
        if (!worker->running) break;
      }
    }

    factory.Reset();
    if (SUCCEEDED(com_hr)) {
      CoUninitialize();
    }
  }

  void DispatchScreenCaptureEvents() {
    if (!channel_) return;
    std::vector<ScreenCaptureEvent> frames;
    std::vector<ScreenCaptureEvent> stops;
    {
      std::lock_guard<std::mutex> lock(screen_events_mutex_);
      for (auto& entry : pending_screen_frames_) {
        frames.push_back(std::move(entry.second));
      }
      pending_screen_frames_.clear();
      for (auto& entry : pending_screen_stops_) {
        stops.push_back(std::move(entry.second));
      }
      pending_screen_stops_.clear();
    }

    for (const auto& frame : frames) {
      EncodableMap args;
      args[EncodableValue("sourceId")] = EncodableValue(frame.source_id);
      args[EncodableValue("timestampNs")] =
          EncodableValue(static_cast<int64_t>(frame.timestamp_ns));
      args[EncodableValue("data")] = EncodableValue(frame.data_url);
      channel_->InvokeMethod(
          "onScreenFrame",
          std::make_unique<EncodableValue>(std::move(args)));
    }

    for (const auto& stop : stops) {
      StopScreenCapture(stop.source_id);
      EncodableMap args;
      args[EncodableValue("sourceId")] = EncodableValue(stop.source_id);
      args[EncodableValue("reason")] = EncodableValue(stop.reason);
      channel_->InvokeMethod(
          "onScreenCaptureStopped",
          std::make_unique<EncodableValue>(std::move(args)));
    }
  }

  static void OnNativeFrame(
      void* context,
      const uint8_t* bgra,
      uint32_t width,
      uint32_t height,
      uint32_t stride,
      uint64_t timestamp_ns) {
    auto* self = static_cast<AwsDesktopWindowsPlugin*>(context);
    if (!self) return;
    self->HandleNativeFrame(bgra, width, height, stride, timestamp_ns);
  }

  void HandleNativeFrame(
      const uint8_t* bgra,
      uint32_t width,
      uint32_t height,
      uint32_t stride,
      uint64_t timestamp_ns) {
    if (!bgra || width == 0 || height == 0 || stride < width * 4) return;
    const auto now = std::chrono::steady_clock::now();
    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      if (!worker_running_) return;
      if (now - last_enqueued_ < kFrameMinInterval) return;
      last_enqueued_ = now;
      RawFrame copy;
      copy.width = width;
      copy.height = height;
      copy.timestamp_ns = timestamp_ns;
      copy.bgra.resize(static_cast<size_t>(width) * height * 4);
      const size_t row_bytes = static_cast<size_t>(width) * 4;
      for (uint32_t y = 0; y < height; ++y) {
        std::memcpy(
            copy.bgra.data() + static_cast<size_t>(y) * row_bytes,
            bgra + static_cast<size_t>(y) * stride,
            row_bytes);
      }
      pending_raw_ = std::move(copy);
    }
    frame_cv_.notify_one();
  }

  bool SubscribeProcessedVideo(const std::string& source_id) {
    UnsubscribeProcessedVideo();
    const ApiSymbols symbols = ResolveProcessedVideoSymbols();
    if (!symbols.valid()) return false;

    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      active_source_id_ = source_id;
      unsubscribe_fn_ = symbols.unsubscribe;
      worker_running_ = true;
      last_enqueued_ = std::chrono::steady_clock::time_point{};
      pending_raw_.reset();
    }
    encoder_thread_ = std::thread([this]() { EncoderLoop(); });
    void* handle = symbols.subscribe(source_id.c_str(), this, &OnNativeFrame);
    if (!handle) {
      UnsubscribeProcessedVideo();
      return false;
    }
    subscription_handle_ = handle;
    return true;
  }

  void UnsubscribeProcessedVideo() {
    void* handle = subscription_handle_;
    RealtimeProcessedUnsubscribe unsub = unsubscribe_fn_;
    subscription_handle_ = nullptr;
    unsubscribe_fn_ = nullptr;
    if (handle && unsub) {
      unsub(handle);
    }
    {
      std::lock_guard<std::mutex> lock(frame_mutex_);
      worker_running_ = false;
      pending_raw_.reset();
    }
    frame_cv_.notify_all();
    if (encoder_thread_.joinable()) {
      encoder_thread_.join();
    }
    {
      std::lock_guard<std::mutex> lock(encoded_mutex_);
      pending_encoded_.reset();
      active_source_id_.clear();
    }
  }

  void EncoderLoop() {
    const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ComPtr<IWICImagingFactory> factory;
    CoCreateInstance(
        CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&factory));

    for (;;) {
      std::optional<RawFrame> next_raw;
      std::string source_id;
      {
        std::unique_lock<std::mutex> lock(frame_mutex_);
        frame_cv_.wait(lock, [this]() {
          return !worker_running_ || pending_raw_.has_value();
        });
        if (!worker_running_) break;
        next_raw = std::move(pending_raw_);
        pending_raw_.reset();
        source_id = active_source_id_;
      }
      if (!next_raw.has_value() || !factory) continue;

      std::string data_url;
      if (!EncodeBgraToJpegDataUrl(factory.Get(), *next_raw, 0, &data_url)) {
        continue;
      }
      {
        std::lock_guard<std::mutex> lock(encoded_mutex_);
        pending_encoded_ = EncodedFrame{
            source_id,
            next_raw->timestamp_ns,
            std::move(data_url),
        };
      }
      if (message_hwnd_) {
        PostMessageW(message_hwnd_, kWmProcessedFrame, 0, 0);
      }
    }

    factory.Reset();
    if (SUCCEEDED(com_hr)) {
      CoUninitialize();
    }
  }

  void DispatchEncodedFrames() {
    if (!channel_) return;
    std::optional<EncodedFrame> frame;
    {
      std::lock_guard<std::mutex> lock(encoded_mutex_);
      if (!pending_encoded_.has_value()) return;
      frame = std::move(pending_encoded_);
      pending_encoded_.reset();
    }
    EncodableMap args;
    args[EncodableValue("sourceId")] = EncodableValue(frame->source_id);
    args[EncodableValue("timestampNs")] =
        EncodableValue(static_cast<int64_t>(frame->timestamp_ns));
    args[EncodableValue("data")] = EncodableValue(frame->data_url);
    channel_->InvokeMethod(
        "onProcessedFrame",
        std::make_unique<EncodableValue>(args));
  }

  flutter::MethodChannel<EncodableValue>* raw_channel_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  HWND message_hwnd_ = nullptr;

  void* subscription_handle_ = nullptr;
  RealtimeProcessedUnsubscribe unsubscribe_fn_ = nullptr;

  std::mutex frame_mutex_;
  std::condition_variable frame_cv_;
  bool worker_running_ = false;
  std::string active_source_id_;
  std::chrono::steady_clock::time_point last_enqueued_{};
  std::optional<RawFrame> pending_raw_;
  std::thread encoder_thread_;

  std::mutex encoded_mutex_;
  std::optional<EncodedFrame> pending_encoded_;

  std::mutex screen_workers_mutex_;
  std::map<std::string, std::unique_ptr<ScreenCaptureWorker>> screen_workers_;
  std::mutex screen_events_mutex_;
  std::map<std::string, ScreenCaptureEvent> pending_screen_frames_;
  std::map<std::string, ScreenCaptureEvent> pending_screen_stops_;
};

}  // namespace

void FlutterRealtimeMediaAwsDesktopPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  AwsDesktopWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
