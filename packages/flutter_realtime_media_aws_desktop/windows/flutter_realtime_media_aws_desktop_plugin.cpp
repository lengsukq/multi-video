#include "include/flutter_realtime_media_aws_desktop/flutter_realtime_media_aws_desktop_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "processed_video_frame_api.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr UINT kWmProcessedFrame = WM_APP + 0x41;
constexpr auto kFrameMinInterval = std::chrono::milliseconds(66);

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
    std::string* out_data_url) {
  if (!factory || frame.width == 0 || frame.height == 0 || frame.bgra.empty()) {
    return false;
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
  if (FAILED(frame_encode->SetSize(frame.width, frame.height))) return false;

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

  if (FAILED(frame_encode->WriteSource(bitmap.Get(), nullptr))) return false;
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

  static ApiSymbols ResolveProcessedVideoSymbols() {
    ApiSymbols symbols;
    HMODULE modules[2] = {
        GetModuleHandleA("flutter_realtime_video_effects_plugin.dll"),
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
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  void HandleMethodCall(
      const flutter::MethodCall<EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto& method = call.method_name();
    if (method == "probeProcessedVideoInput") {
      result->Success(EncodableValue(ResolveProcessedVideoSymbols().valid()));
      return;
    }
    if (method == "subscribeProcessedVideo") {
      const auto* args = std::get_if<EncodableMap>(call.arguments());
      std::string source_id;
      if (args) {
        auto it = args->find(EncodableValue("sourceId"));
        if (it != args->end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) {
            source_id = *s;
          }
        }
      }
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
      std::string source_id;
      std::string message = "Windows WebView2 processed video failed.";
      if (args) {
        auto sid = args->find(EncodableValue("sourceId"));
        if (sid != args->end()) {
          if (const auto* s = std::get_if<std::string>(&sid->second)) {
            source_id = *s;
          }
        }
        auto msg = args->find(EncodableValue("message"));
        if (msg != args->end()) {
          if (const auto* m = std::get_if<std::string>(&msg->second)) {
            message = *m;
          }
        }
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
      if (!EncodeBgraToJpegDataUrl(factory.Get(), *next_raw, &data_url)) {
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
};

}  // namespace

void FlutterRealtimeMediaAwsDesktopPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  AwsDesktopWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
