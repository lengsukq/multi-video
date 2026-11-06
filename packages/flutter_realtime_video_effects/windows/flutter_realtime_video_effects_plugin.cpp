#include "include/flutter_realtime_video_effects/flutter_realtime_video_effects_plugin_c_api.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/plugin_registrar.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <deque>
#include <filesystem>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <wincodec.h>
#include <wrl/client.h>

#include "mf_camera_capture.h"
#include "pphumanseg_inference.h"
#include "processed_video_frame_api.h"

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using realtime_processed_video::BackgroundMode;
using realtime_processed_video::BackgroundSettings;
using realtime_processed_video::Frame;
using realtime_processed_video::FrameHub;
using realtime_processed_video::PersonMask;

// One effects plugin instance per Flutter engine/registrar.
// Native provider callbacks enter via exported C API; this keeps the common
// frame source in one DLL instead of creating a second isolated FrameHub.
struct CallbackFrameSink final : realtime_processed_video::FrameSink {
  CallbackFrameSink(void* target, RealtimeProcessedOnFrame callback)
      : target(target), callback(callback) {}
  void OnFrame(const Frame& frame) override {
    std::lock_guard<std::mutex> lock(mutex);
    if (!active) return;
    callback(target, frame.pixels->data(), frame.width, frame.height,
             frame.stride, frame.timestamp_ns);
  }
  void Close() {
    std::lock_guard<std::mutex> lock(mutex);
    active = false;
  }
  std::mutex mutex;
  bool active = true;
  void* target;
  RealtimeProcessedOnFrame callback;
};

struct Subscription {
  std::shared_ptr<CallbackFrameSink> sink;
};

class VideoEffectsPlugin;
std::mutex instance_mutex;
VideoEffectsPlugin* active_plugin = nullptr;

const Value* Field(const Map& map, const char* key) {
  auto it = map.find(Value(key));
  return it == map.end() ? nullptr : &it->second;
}
std::string String(const Value* value) {
  if (!value) return {};
  if (auto* result = std::get_if<std::string>(value)) return *result;
  return {};
}
int Number(const Value* value, int fallback) {
  if (!value) return fallback;
  if (auto* i = std::get_if<std::int32_t>(value)) return *i;
  if (auto* i = std::get_if<std::int64_t>(value)) {
    if (*i < std::numeric_limits<int>::min() ||
        *i > std::numeric_limits<int>::max()) return -1;
    return static_cast<int>(*i);
  }
  return -1;
}
bool Boolean(const Value* value) {
  return value && std::get_if<bool>(value) && std::get<bool>(*value);
}
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  auto chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   text.c_str(), static_cast<int>(text.size()),
                                   nullptr, 0);
  if (chars <= 0) return {};
  std::wstring out(chars, L' ');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.c_str(),
                      static_cast<int>(text.size()), out.data(), chars);
  return out;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const auto len = WideCharToMultiByte(CP_UTF8, 0, text.data(),
      static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string out(len, ' ');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
}
std::filesystem::path ModelFile() {
  wchar_t name[32768] = {};
  const auto count = GetModuleFileNameW(nullptr, name, 32768);
  if (!count || count == 32768) return {};
  const auto assets = std::filesystem::path(name).parent_path() /
      "data" / "flutter_assets" / "packages";
  const auto modular = assets / "flutter_realtime_video_effects" /
      "assets" / "windows" / "pphumanseg.onnx";
  if (std::filesystem::exists(modular)) return modular;
  // The public pub.dev artifact folds the internal packages into one SDK.
  return assets / "flutter_realtime_sdk" / "assets" / "bundled" /
      "flutter_realtime_video_effects" / "windows" / "pphumanseg.onnx";
}

bool DecodeImage(const std::vector<std::uint8_t>& encoded,
                 BackgroundSettings* config) {
  if (!config || encoded.empty() || encoded.size() > 16 * 1024 * 1024)
    return false;
  Microsoft::WRL::ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) return false;
  Microsoft::WRL::ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(encoded.data()), static_cast<DWORD>(encoded.size()))))
    return false;
  Microsoft::WRL::ComPtr<IWICBitmapDecoder> decoder;
  Microsoft::WRL::ComPtr<IWICBitmapFrameDecode> frame;
  Microsoft::WRL::ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame))) return false;
  // Check untrusted compressed-image dimensions before instantiating a
  // converter. A small JPEG/PNG can expand into a huge bitmap.
  UINT width = 0, height = 0;
  if (FAILED(frame->GetSize(&width, &height)) ||
      !width || !height || width > 4096 || height > 4096) return false;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
          WICBitmapDitherTypeNone, nullptr, 0,
          WICBitmapPaletteTypeCustom))) return false;
  auto next = std::vector<std::uint8_t>(
      static_cast<std::size_t>(width) * height * 4);
  if (FAILED(converter->CopyPixels(nullptr, width * 4,
        static_cast<UINT>(next.size()), next.data()))) return false;
  config->replacement_width = width;
  config->replacement_height = height;
  config->replacement_bgra = std::move(next);
  return true;
}

bool ParseEffect(const Map& effect, BackgroundSettings* config) {
  if (!config) return false;
  const auto* raw_type = Field(effect, "type");
  // Do not interpret malformed effect values as "none": that would
  // accidentally publish an unblurred camera background. The caller must
  // explicitly select none, and unknown settings fail closed.
  if (!raw_type || !std::get_if<std::string>(raw_type)) return false;
  const auto type = String(raw_type);
  BackgroundSettings next;
  if (type == "none") {
    next.mode = BackgroundMode::none;
  } else if (type == "blur") {
    next.mode = BackgroundMode::blur;
    const auto strength = String(Field(effect, "blurStrength"));
    if (!strength.empty() && strength != "low" &&
        strength != "medium" && strength != "high") return false;
    next.blur_radius = strength == "low" ? 8 : strength == "high" ? 24 : 16;
  } else if (type == "replaceImage") {
    next.mode = BackgroundMode::replace_image;
    const auto* bytes = Field(effect, "imageBytes");
    if (!bytes) return false;
    std::vector<std::uint8_t> encoded;
    if (auto* raw = std::get_if<std::vector<std::uint8_t>>(bytes)) {
      encoded = *raw;
    } else if (auto* values = std::get_if<flutter::EncodableList>(bytes)) {
      if (values->size() > 16 * 1024 * 1024) return false;
      encoded.reserve(values->size());
      for (const auto& item : *values) {
        const auto* number = std::get_if<std::int32_t>(&item);
        if (!number || *number < 0 || *number > 255) return false;
        encoded.push_back(static_cast<std::uint8_t>(*number));
      }
    } else {
      return false;
    }
    if (!DecodeImage(encoded, &next))
      return false;
  } else {
    return false;
  }
  *config = std::move(next);
  return true;
}

struct PixelHolder {
  std::shared_ptr<const std::vector<std::uint8_t>> bytes;
  FlutterDesktopPixelBuffer buffer{};
};

class Source final : public std::enable_shared_from_this<Source> {
 public:
  using FailureCallback = std::function<void(const std::string&, const std::string&)>;
  Source(flutter::TextureRegistrar* textures, FrameHub* hub,
         std::string id, std::wstring camera, BackgroundSettings settings,
         int fps, FailureCallback on_failure)
      : textures_(textures), hub_(hub), id_(std::move(id)),
        camera_id_(std::move(camera)), settings_(std::move(settings)),
        frame_rate_(fps), on_failure_(std::move(on_failure)) {
    texture_ = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([this](size_t, size_t)
            -> const FlutterDesktopPixelBuffer* {
          std::lock_guard<std::mutex> lock(lock_);
          if (!preview_.IsValid()) return nullptr;
          auto* holder = new PixelHolder{};
          holder->bytes = preview_.pixels;
          holder->buffer.buffer = holder->bytes->data();
          holder->buffer.width = preview_.width;
          holder->buffer.height = preview_.height;
          holder->buffer.release_context = holder;
          holder->buffer.release_callback = [](void* context) {
            delete static_cast<PixelHolder*>(context);
          };
          return &holder->buffer;
        }));
    texture_id_ = textures_->RegisterTexture(texture_.get());
    hub_->Activate(id_, settings_.mode != BackgroundMode::none);
  }

  ~Source() {
    if (!disposed_.load()) {
      capture_.Stop();
      hub_->Clear(id_);
      if (texture_id_ >= 0) textures_->UnregisterTexture(texture_id_);
    }
  }
  std::int64_t texture_id() const { return texture_id_; }

  void Dispose() {
    if (disposed_.exchange(true)) return;
    enabled_.store(false);
    capture_.Stop();
    hub_->Clear(id_);
    {
      std::lock_guard<std::mutex> guard(lock_);
      preview_ = Frame{};
    }
    const auto id = std::exchange(texture_id_, std::int64_t{-1});
    if (id >= 0) {
      // The engine unregisters textures asynchronously. Retain this object
      // (and its callback closure) until Flutter has finished using it.
      auto keep_alive = shared_from_this();
      textures_->UnregisterTexture(id, [keep_alive]() {});
    }
  }

  bool Start(const std::filesystem::path& model) {
    if (texture_id_ < 0 || !segmenter_.Open(model.wstring())) return false;
    RestartCapture();
    return true;
  }

  bool SetEffect(BackgroundSettings settings) {
    const auto previously_failed = failed_.exchange(false);
    {
      std::lock_guard<std::mutex> guard(lock_);
      settings_ = std::move(settings);
      hub_->SetEffectRequired(id_, settings_.mode != BackgroundMode::none);
      preview_ = Frame{};
    }
    textures_->MarkTextureFrameAvailable(texture_id_);
    if (previously_failed && enabled_.load()) RestartCapture();
    return true;
  }

  bool SetEnabled(bool enabled) {
    if (disposed_.load()) return false;
    if (enabled && failed_.load()) return false;
    if (enabled == enabled_.load()) return true;
    enabled_.store(enabled);
    if (enabled) RestartCapture();
    else {
      capture_.Stop();
      {
        std::lock_guard<std::mutex> guard(lock_);
        preview_ = Frame{};
      }
      textures_->MarkTextureFrameAvailable(texture_id_);
    }
    return true;
  }

  bool SelectCamera(std::wstring id) {
    if (disposed_.load()) return false;
    auto available = realtime_video_effects::FindCameras();
    if (!id.empty() && std::none_of(available.begin(), available.end(),
        [&](const auto& camera) { return camera.id == id; })) return false;
    // Camera disconnection can mark the processor as failed. Selecting a
    // newly attached device is the explicit recovery path: stop the old
    // worker first, reset the failure and throttle, then start the new one.
    capture_.Stop();
    camera_id_ = std::move(id);
    failed_.store(false);
    last_processed_ = {};
    if (enabled_.load()) RestartCapture();
    return true;
  }

 private:
  void RestartCapture() {
    std::weak_ptr<Source> weak = shared_from_this();
    capture_.Start(id_, camera_id_,
        [weak](const Frame& frame) {
          if (auto source = weak.lock()) source->OnCameraFrame(frame);
        },
        [weak](const std::string&) {
          if (auto source = weak.lock()) source->Fail("mf.camera.capture");
        });
  }

  void Fail(const std::string& reason) {
    if (disposed_.load() || failed_.exchange(true)) return;
    {
      std::lock_guard<std::mutex> guard(lock_);
      preview_ = Frame{};
    }
    if (texture_id_ >= 0) textures_->MarkTextureFrameAvailable(texture_id_);
    on_failure_(id_, reason);
  }

  void OnCameraFrame(const Frame& camera) {
    if (!enabled_.load() || failed_.load()) return;
    const auto now = std::chrono::steady_clock::now();
    const auto interval = std::chrono::nanoseconds(
        1000000000LL / std::max(1, frame_rate_));
    if (last_processed_ != std::chrono::steady_clock::time_point{} &&
        now - last_processed_ < interval) return;
    last_processed_ = now;
    BackgroundSettings settings;
    {
      std::lock_guard<std::mutex> guard(lock_);
      settings = settings_;
    }
    PersonMask mask;
    if (settings.mode != BackgroundMode::none &&
        !segmenter_.Infer(camera, &mask)) {
      Fail("videoEffects.segmentation.failed");
      return;
    }
    Frame result;
    if (!realtime_processed_video::Compose(camera, mask, settings, &result)) {
      Fail("videoEffects.composite.failed");
      return;
    }
    // A concurrent none->blur switch can reject a stale raw frame. Ignore
    // that obsolete frame rather than permanently disabling a healthy source.
    if (!hub_->Publish(result)) return;
    auto preview_rgba = realtime_processed_video::PreviewRgba(result);
    if (!preview_rgba) {
      Fail("videoEffects.preview.invalidFrame");
      return;
    }
    result.pixels = std::move(preview_rgba);
    {
      std::lock_guard<std::mutex> guard(lock_);
      preview_ = std::move(result);
    }
    textures_->MarkTextureFrameAvailable(texture_id_);
  }

  flutter::TextureRegistrar* textures_;
  FrameHub* hub_;
  const std::string id_;
  std::wstring camera_id_;
  BackgroundSettings settings_;
  const int frame_rate_;
  FailureCallback on_failure_;
  realtime_video_effects::PersonSegmenter segmenter_;
  realtime_video_effects::CameraCapture capture_;
  std::unique_ptr<flutter::TextureVariant> texture_;
  std::int64_t texture_id_ = -1;
  std::atomic<bool> enabled_{true};
  std::atomic<bool> failed_{false};
  std::atomic<bool> disposed_{false};
  std::mutex lock_;
  Frame preview_;
  std::chrono::steady_clock::time_point last_processed_{};
};

class VideoEffectsPlugin final : public flutter::Plugin {
 public:
  explicit VideoEffectsPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), textures_(registrar->texture_registrar()) {
    {
      std::lock_guard<std::mutex> lock(instance_mutex);
      active_plugin = this;
    }
    if (auto* view = registrar->GetView()) {
      window_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
    }
    proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT message, WPARAM, LPARAM)
            -> std::optional<LRESULT> {
          if (message != kErrorNotification) return std::nullopt;
          DrainErrorsOnPlatformThread();
          return 0;
        });
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(
        registrar->messenger(), "flutter_realtime_video_effects",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
    // Shared SDK controls use the processed-video channel during a room.
    // Both channels resolve the same source registry and error boundaries.
    source_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
        registrar->messenger(), "flutter_realtime_processed_video/sources",
        &flutter::StandardMethodCodec::GetInstance());
    source_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
  }

  ~VideoEffectsPlugin() override {
    {
      std::lock_guard<std::mutex> lock(instance_mutex);
      if (active_plugin == this) active_plugin = nullptr;
    }
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
    for (auto& item : sources_) item.second->Dispose();
    sources_.clear();
  }

  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    registrar->AddPlugin(std::make_unique<VideoEffectsPlugin>(registrar));
  }

  void* SubscribeSource(const char* source_id, void* context,
                        RealtimeProcessedOnFrame callback) {
    if (!source_id || !*source_id || !context || !callback) return nullptr;
    auto sink = std::make_shared<CallbackFrameSink>(context, callback);
    if (!hub_.Subscribe(source_id, sink)) return nullptr;
    return new Subscription{std::move(sink)};
  }

  void NotifyProviderFailure(const char* source_id, const char* message) {
    if (source_id && message && hub_.Contains(source_id))
      ReportError(source_id, message);
  }

 private:
  using Response = std::unique_ptr<flutter::MethodResult<Value>>;
  static constexpr UINT kErrorNotification = WM_APP + 0x31B;

  void ReportError(const std::string& source_id, const std::string& message) {
    {
      std::lock_guard<std::mutex> guard(error_mutex_);
      pending_errors_.emplace_back(source_id, message);
    }
    if (window_) PostMessageW(window_, kErrorNotification, 0, 0);
  }

  void DrainErrorsOnPlatformThread() {
    std::deque<std::pair<std::string, std::string>> errors;
    {
      std::lock_guard<std::mutex> guard(error_mutex_);
      errors.swap(pending_errors_);
    }
    for (const auto& error : errors) {
      channel_->InvokeMethod("sourceError", std::make_unique<Value>(
          Map{{Value("sourceId"), Value(error.first)},
              {Value("message"), Value(error.second)}}));
    }
  }

  void Handle(const flutter::MethodCall<Value>& call, Response result) {
    const auto* args = std::get_if<Map>(call.arguments());
    const Map empty;
    const auto& map = args ? *args : empty;
    const auto& method = call.method_name();
    if (method == "isSupported") {
      realtime_video_effects::PersonSegmenter probe;
      result->Success(Value(
          !realtime_video_effects::FindCameras().empty() &&
          probe.Open(ModelFile().wstring())));
      return;
    }
    if (method == "listCameras") {
      flutter::EncodableList cameras;
      for (const auto& camera : realtime_video_effects::FindCameras()) {
        cameras.emplace_back(Map{{Value("id"), Value(Utf8(camera.id))},
          {Value("label"), Value(Utf8(camera.name))},
          {Value("isFrontFacing"), Value(false)}});
      }
      result->Success(Value(cameras));
      return;
    }
    if (method == "createSource") {
      const int width = Number(Field(map, "width"), 1280);
      const int height = Number(Field(map, "height"), 720);
      const int frame_rate = Number(Field(map, "frameRate"), 24);
      if (width < 1 || width > 4096 || height < 1 || height > 4096 ||
          frame_rate < 1 || frame_rate > 60) {
        result->Error("invalid_argument", "Invalid video dimensions or rate");
        return;
      }
      BackgroundSettings background;
      const auto* raw_effect = Field(map, "effect");
      const auto* effect = raw_effect ? std::get_if<Map>(raw_effect) : nullptr;
      // The bridge always supplies an explicit effect; missing or malformed
      // maps must never silently activate the raw-camera path.
      if (!effect || !ParseEffect(*effect, &background)) {
        result->Error("invalid_effect", "Unable to decode background effect");
        return;
      }
      auto cameras = realtime_video_effects::FindCameras();
      const auto requested = Wide(String(Field(map, "cameraDeviceId")));
      if (cameras.empty() ||
          (!requested.empty() &&
           std::none_of(cameras.begin(), cameras.end(),
             [&](const auto& camera) { return camera.id == requested; }))) {
        result->Error("camera_unavailable", "Requested camera does not exist");
        return;
      }
      const auto source_id = "win_effects_" + std::to_string(++next_source_);
      const auto device = requested.empty() ? cameras.front().id : requested;
      auto source = std::make_shared<Source>(
          textures_, &hub_, source_id, device, background, frame_rate,
          [this](const std::string& id, const std::string& reason) {
            ReportError(id, reason);
          });
      if (!source->Start(ModelFile())) {
        source->Dispose();
        result->Error("unsupported", "ONNX model/runtime or texture unavailable");
        return;
      }
      const auto texture_id = source->texture_id();
      sources_.emplace(source_id, std::move(source));
      result->Success(Value(Map{
          {Value("id"), Value(source_id)},
          {Value("platform"), Value("windows")},
          {Value("kind"), Value("nativeFrameHub")},
          {Value("width"), Value(width)},
          {Value("height"), Value(height)},
          {Value("frameRate"), Value(frame_rate)},
          {Value("previewTextureId"), Value(texture_id)}}));
      return;
    }
    const auto id = String(Field(map, "sourceId"));
    auto it = sources_.find(id);
    if (method == "disposeSource") {
      if (it != sources_.end()) {
        it->second->Dispose();
        sources_.erase(it);
      }
      result->Success();
      return;
    }
    if (it == sources_.end()) {
      result->Error("source_not_found", "Unknown video effects source");
      return;
    }
    if (method == "setEnabled") {
      if (!it->second->SetEnabled(Boolean(Field(map, "enabled"))))
        result->Error("processing_failed", "Effects processing has failed");
      else result->Success();
      return;
    }
    if (method == "selectCamera") {
      if (!it->second->SelectCamera(Wide(String(Field(map, "deviceId")))))
        result->Error("camera_unavailable", "Camera does not exist");
      else result->Success();
      return;
    }
    if (method == "setEffect") {
      const auto* v = Field(map, "effect");
      const auto* effect = v ? std::get_if<Map>(v) : nullptr;
      BackgroundSettings next;
      if (!effect || !ParseEffect(*effect, &next)) {
        result->Error("invalid_effect", "Invalid background effect");
      } else {
        it->second->SetEffect(std::move(next));
        result->Success();
      }
      return;
    }
    result->NotImplemented();
  }

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  HWND window_ = nullptr;
  int proc_id_ = 0;
  std::mutex error_mutex_;
  std::deque<std::pair<std::string, std::string>> pending_errors_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::unique_ptr<flutter::MethodChannel<Value>> source_channel_;
  FrameHub hub_;
  std::unordered_map<std::string, std::shared_ptr<Source>> sources_;
  std::uint64_t next_source_ = 0;
};
}  // namespace

extern "C" __declspec(dllexport) void* RealtimeProcessedVideoSubscribe(
    const char* source_id, void* context, RealtimeProcessedOnFrame callback) {
  std::lock_guard<std::mutex> lock(instance_mutex);
  return active_plugin
      ? active_plugin->SubscribeSource(source_id, context, callback)
      : nullptr;
}

extern "C" __declspec(dllexport) void RealtimeProcessedVideoUnsubscribe(
    void* subscription) {
  std::unique_ptr<Subscription> owner(static_cast<Subscription*>(subscription));
  if (owner && owner->sink) owner->sink->Close();
}

extern "C" __declspec(dllexport) void RealtimeProcessedVideoReportFailure(
    const char* source_id, const char* message) {
  std::lock_guard<std::mutex> lock(instance_mutex);
  if (active_plugin)
    active_plugin->NotifyProviderFailure(source_id, message);
}

void FlutterRealtimeVideoEffectsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  VideoEffectsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
