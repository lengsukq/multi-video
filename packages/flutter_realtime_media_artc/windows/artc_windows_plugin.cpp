#include "include/flutter_realtime_media_artc/flutter_realtime_media_artc_plugin_c_api.h"
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>
#include <windows.h>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>
#ifdef ARTC_WINDOWS_SDK_AVAILABLE
#include <rtc/engine_interface.h>
#endif

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;

std::string ArgString(const Map* args, const char* name) {
  if (!args) return {};
  auto it = args->find(Value(name));
  if (it == args->end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value ? *value : std::string();
}

std::optional<unsigned int> ParseScreenShareId(const std::string& value) {
  if (value.empty() || value.front() == '-') return std::nullopt;
  char* end = nullptr;
  errno = 0;
  const int base = value.rfind("0x", 0) == 0 ||
          value.rfind("0X", 0) == 0 ? 16 : 10;
  const auto parsed = std::strtoul(value.c_str(), &end, base);
  if (errno || end == value.c_str() || *end != '\0' ||
      parsed > std::numeric_limits<unsigned int>::max()) {
    return std::nullopt;
  }
  return static_cast<unsigned int>(parsed);
}
bool ArgBool(const Map* args, const char* name) {
  if (!args) return false;
  auto it = args->find(Value(name));
  if (it == args->end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value && *value;
}
Map Event(const std::string& type) {
  return {{Value("type"), Value(type)}};
}
Map UserEvent(const std::string& type, const std::string& uid) {
  auto event = Event(type);
  event[Value("userId")] = Value(uid);
  return event;
}
void Failure(std::unique_ptr<Result> result, const std::string& message,
             const char* code = "native_error") {
  result->Error(code, message);
}

// Pixel-buffer lifetime follows Flutter's texture callback contract. The
// latest SDK frame and the buffer submitted to Flutter are separate, so the
// vendor's capture thread never invalidates a render-thread pointer.
struct ArtcFrameTexture {
  std::mutex mutex;
  std::vector<std::uint8_t> latest;
  std::vector<std::uint8_t> rendered;
  std::size_t width = 0;
  std::size_t height = 0;
  FlutterDesktopPixelBuffer buffer{};
  std::unique_ptr<flutter::TextureVariant> texture;
  std::int64_t id = -1;

  const FlutterDesktopPixelBuffer* Copy() {
    std::lock_guard<std::mutex> lock(mutex);
    if (latest.empty() || !width || !height) return nullptr;
    rendered = latest;
    buffer = {rendered.data(), width, height, nullptr, nullptr};
    return &buffer;
  }
  void Update(const std::uint8_t* data, int frame_width, int frame_height,
              int stride) {
    if (!data || frame_width <= 0 || frame_height <= 0 ||
        frame_width > 4096 || frame_height > 4096 ||
        stride < frame_width * 4 ||
        stride > 4096 * 4) return;
    std::lock_guard<std::mutex> lock(mutex);
    width = static_cast<std::size_t>(frame_width);
    height = static_cast<std::size_t>(frame_height);
    latest.resize(width * height * 4);
    for (int y = 0; y < frame_height; ++y) {
      std::memcpy(latest.data() + static_cast<std::size_t>(y) * width * 4,
                  data + static_cast<std::size_t>(y) * stride, width * 4);
    }
  }
};

class ArtcWindowsPlugin final : public flutter::Plugin {
 public:
  explicit ArtcWindowsPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    auto view = registrar_->GetView();
    if (view) hwnd_ = GetAncestor(view->GetNativeWindow(), GA_ROOT);
    message_ = RegisterWindowMessageW(L"flutter_realtime_media_artc.dispatch");
    delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [this](HWND, UINT msg, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (msg != message_) return std::nullopt;
          DrainDispatch();
          return 0;
        });
    methods_ = std::make_unique<flutter::MethodChannel<Value>>(
        registrar_->messenger(),
        "com.oneplusdream.flutter_realtime_media_artc/methods",
        &flutter::StandardMethodCodec::GetInstance());
    methods_->SetMethodCallHandler([this](const auto& call, auto result) {
      Handle(call, std::move(result));
    });
    events_ = std::make_unique<flutter::EventChannel<Value>>(
        registrar_->messenger(),
        "com.oneplusdream.flutter_realtime_media_artc/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<Value>>(
            [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const Value*)
                -> std::unique_ptr<flutter::StreamHandlerError<Value>> {
              sink_.reset();
              return nullptr;
            }));
  }
  ~ArtcWindowsPlugin() override {
    active_ = false;
    methods_->SetMethodCallHandler(nullptr);
    events_->SetStreamHandler(nullptr);
    ReleaseEngine();
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_id_);
  }
  static void Register(flutter::PluginRegistrarWindows* registrar) {
    registrar->AddPlugin(std::make_unique<ArtcWindowsPlugin>(registrar));
  }

 private:
  void Post(std::function<void()> task) {
    if (!active_ || !hwnd_) return;
    {
      std::lock_guard<std::mutex> lock(dispatch_mutex_);
      dispatch_.push_back(std::move(task));
    }
    PostMessage(hwnd_, message_, 0, 0);
  }
  void DrainDispatch() {
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(dispatch_mutex_);
      tasks.swap(dispatch_);
    }
    if (active_) for (auto& task : tasks) task();
  }
  void Emit(Map value) {
    Post([this, value = std::move(value)]() {
      if (sink_) sink_->Success(Value(value));
    });
  }

#ifdef ARTC_WINDOWS_SDK_AVAILABLE
  struct NativeEvents final : AliRTCSdk::AliEngineEventListener {
    ArtcWindowsPlugin* owner;
    explicit NativeEvents(ArtcWindowsPlugin* plugin) : owner(plugin) {}
    void OnJoinChannelResult(int code, const char*, const char*, int) override {
      owner->Post([this, code]() {
        auto result = std::move(owner->pending_join_);
        if (!result) return;
        if (code == 0) result->Success();
        else Failure(std::move(result), "ARTC native join failed: " + std::to_string(code));
      });
    }
    void OnLeaveChannelResult(int code, AliRTCSdk::AliEngineStats) override {
      owner->Post([this, code]() {
        auto result = std::move(owner->pending_leave_);
        if (!result) return;
        if (code == 0) result->Success();
        else Failure(std::move(result), "ARTC native leave failed: " + std::to_string(code));
      });
    }
    void OnRemoteUserOnLineNotify(const char* uid, int) override {
      owner->Emit(UserEvent("participantJoined", uid ? uid : ""));
    }
    void OnRemoteUserOffLineNotify(
        const char* uid, AliRTCSdk::AliEngineUserOfflineReason) override {
      owner->Emit(UserEvent("participantLeft", uid ? uid : ""));
    }
    void OnRemoteTrackAvailableNotify(
        const char* uid, AliRTCSdk::AliEngineAudioTrack audio,
        AliRTCSdk::AliEngineVideoTrack video) override {
      const std::string user = uid ? uid : "";
      auto camera = UserEvent("videoChanged", user);
      camera[Value("available")] = Value(
          video == AliRTCSdk::AliEngineVideoTrackCamera ||
          video == AliRTCSdk::AliEngineVideoTrackBoth);
      owner->Emit(std::move(camera));
      auto screen = UserEvent("screenChanged", user);
      screen[Value("available")] = Value(
          video == AliRTCSdk::AliEngineVideoTrackScreen ||
          video == AliRTCSdk::AliEngineVideoTrackBoth);
      owner->Emit(std::move(screen));
      auto microphone = UserEvent("audioChanged", user);
      microphone[Value("available")] =
          Value(audio != AliRTCSdk::AliEngineAudioTrackNo);
      owner->Emit(std::move(microphone));
    }
    void OnAuthInfoWillExpire() override { owner->Emit(Event("authWillExpire")); }
    void OnAuthInfoExpired() override { owner->Emit(Event("authWillExpire")); }
    void OnScreenSharePublishStateChanged(
        AliRTCSdk::AliEnginePublishState,
        AliRTCSdk::AliEnginePublishState new_state,
        int, const char*) override {
      auto event = Event("localScreenChanged");
      event[Value("available")] =
          Value(new_state == AliRTCSdk::AliEngineStatsPublished);
      owner->Emit(std::move(event));
    }
    void OnDataChannelMessage(
        const char* uid, const AliRTCSdk::AliEngineDataChannelMsg& msg) override {
      if (!msg.data || msg.dataLen <= 0 || msg.dataLen > 65536) return;
      auto value = UserEvent("message", uid ? uid : "");
      value[Value("data")] = Value(std::string(
          static_cast<const char*>(msg.data), static_cast<std::size_t>(msg.dataLen)));
      owner->Emit(std::move(value));
    }
  };
  struct VideoObserver final : AliRTCSdk::IVideoFrameObserver {
    ArtcWindowsPlugin* owner;
    explicit VideoObserver(ArtcWindowsPlugin* plugin) : owner(plugin) {}
    AliRTCSdk::AliEngineVideoFormat GetVideoFormatPreference() override {
      return AliRTCSdk::AliEngineVideoFormatBGRA;
    }
    bool OnCaptureVideoSample(AliRTCSdk::AliEngineVideoSource source,
                              AliRTCSdk::AliEngineVideoRawData& raw) override {
      owner->UpdateFrame(owner->local_uid_, source, true, raw);
      return false;
    }
    bool OnPreEncodeVideoSample(AliRTCSdk::AliEngineVideoSource,
                                AliRTCSdk::AliEngineVideoRawData&) override {
      return false;
    }
    bool OnRemoteVideoSample(const char* uid,
                             AliRTCSdk::AliEngineVideoSource source,
                             AliRTCSdk::AliEngineVideoRawData& raw) override {
      owner->UpdateFrame(uid ? uid : "", source, false, raw);
      return false;
    }
  };
  static std::string FrameKey(const std::string& uid, bool local, bool screen) {
    return std::string(local ? "local:" : "remote:") + uid +
           (screen ? ":screen" : ":camera");
  }
  void UpdateFrame(const std::string& uid, AliRTCSdk::AliEngineVideoSource source,
                   bool local, const AliRTCSdk::AliEngineVideoRawData& raw) {
    if (raw.format != AliRTCSdk::AliEngineVideoFormatBGRA ||
        !raw.dataPtr || raw.width <= 0 || raw.height <= 0) return;
    const int stride = raw.stride >= raw.width * 4 ? raw.stride : raw.width * 4;
    if (raw.dataLength > 0 &&
        static_cast<std::int64_t>(stride) * raw.height > raw.dataLength) return;
    const auto key = FrameKey(uid, local,
        source == AliRTCSdk::AliEngineVideoSourceScreenShare);
    std::shared_ptr<ArtcFrameTexture> frame;
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      auto it = textures_.find(key);
      if (it == textures_.end()) return;
      frame = it->second;
    }
    frame->Update(static_cast<const std::uint8_t*>(raw.dataPtr),
                  raw.width, raw.height, stride);
    registrar_->texture_registrar()->MarkTextureFrameAvailable(frame->id);
  }
  bool InitializeEngine() {
    if (engine_) return true;
    engine_ = AliRTCSdk::AliEngine::Create("");
    if (!engine_) return false;
    engine_->SetEngineEventListener(&native_events_);
    engine_->QueryInterface(AliRTCSdk::AliEngineInterfaceMediaEngine,
                            reinterpret_cast<void**>(&media_));
    if (media_) media_->RegisterVideoSampleObserver(&video_observer_);
    return true;
  }
#endif

  void ReleaseEngine() {
#ifdef ARTC_WINDOWS_SDK_AVAILABLE
    if (media_) {
      media_->UnRegisterVideoSampleObserver(&video_observer_);
      media_->Release();
      media_ = nullptr;
    }
    if (engine_) {
      engine_->SetEngineEventListener(nullptr);
      AliRTCSdk::AliEngine::Destroy();
      engine_ = nullptr;
    }
    if (pending_join_) Failure(std::move(pending_join_), "ARTC session disposed");
    if (pending_leave_) Failure(std::move(pending_leave_), "ARTC session disposed");
#endif
    local_mic_muted_ = true;
    std::map<std::string, std::shared_ptr<ArtcFrameTexture>> old;
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      old.swap(textures_);
    }
    for (auto& entry : old) {
      auto frame = entry.second;
      if (frame->id >= 0)
        registrar_->texture_registrar()->UnregisterTexture(
            frame->id, [frame]() {});
    }
  }

  void Handle(const flutter::MethodCall<Value>& call,
              std::unique_ptr<Result> result) {
    const auto& method = call.method_name();
    if (method == "isAvailable") {
#ifdef ARTC_WINDOWS_SDK_AVAILABLE
      const char* version = AliRTCSdk::AliEngine::GetSDKVersion();
      result->Success(Value(version && *version && hwnd_ != nullptr));
#else
      result->Success(Value(false));
#endif
      return;
    }
#ifndef ARTC_WINDOWS_SDK_AVAILABLE
    Failure(std::move(result),
            "ARTC Windows x64 runtime must be installed before joining.",
            "unsupported_platform");
    return;
#else
    const auto* args = call.arguments() ?
        std::get_if<Map>(call.arguments()) : nullptr;
    if (method == "dispose") {
      ReleaseEngine();
      result->Success();
      return;
    }
    if (method == "probeProcessedVideoInput") {
      result->Success(Value(false)); // No processed-frame injection yet.
      return;
    }
    if (method == "getTextureId") {
      const auto uid = ArgString(args, "userId");
      if (uid.empty()) {
        Failure(std::move(result), "ARTC texture requires userId", "invalid_argument");
        return;
      }
      const std::string key = FrameKey(uid, ArgBool(args, "isLocal"),
                                       ArgBool(args, "isScreenShare"));
      std::shared_ptr<ArtcFrameTexture> frame;
      {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        auto& slot = textures_[key];
        if (!slot) {
          slot = std::make_shared<ArtcFrameTexture>();
          auto keep_alive = slot;
          slot->texture = std::make_unique<flutter::TextureVariant>(
              flutter::PixelBufferTexture([keep_alive](size_t, size_t) {
                return keep_alive->Copy();
              }));
          slot->id = registrar_->texture_registrar()->RegisterTexture(
              slot->texture.get());
        }
        frame = slot;
      }
      result->Success(Value(frame->id));
      return;
    }
    if (method == "getTextureDimensions") {
      const auto uid = ArgString(args, "userId");
      const auto key = FrameKey(uid, ArgBool(args, "isLocal"),
                                ArgBool(args, "isScreenShare"));
      std::shared_ptr<ArtcFrameTexture> frame;
      {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        const auto it = textures_.find(key);
        if (it != textures_.end()) frame = it->second;
      }
      if (!frame) {
        result->Success();
        return;
      }
      std::lock_guard<std::mutex> lock(frame->mutex);
      if (frame->width == 0 || frame->height == 0) {
        result->Success();
      } else {
        result->Success(Value(Map{
          {Value("width"), Value(static_cast<int>(frame->width))},
          {Value("height"), Value(static_cast<int>(frame->height))}
        }));
      }
      return;
    }
    if (method == "join") {
      if (!args || pending_join_ || pending_leave_ || !InitializeEngine()) {
        Failure(std::move(result), "ARTC engine is busy or unavailable",
                "invalid_state");
        return;
      }
      const auto auth = ArgString(args, "authInfo");
      const auto channel = ArgString(args, "channelId");
      local_uid_ = ArgString(args, "userId");
      const auto name = ArgString(args, "displayName");
      const auto role = ArgString(args, "role");
      const auto mode = ArgString(args, "roomMode");
      if (auth.empty() || channel.empty() || local_uid_.empty()) {
        Failure(std::move(result), "Missing ARTC join credentials", "invalid_argument");
        return;
      }
      auto code = engine_->SetChannelProfile(
          mode == "communication" ? AliRTCSdk::AliEngineCommunication
                                  : AliRTCSdk::AliEngineInteractiveLive);
      if (code == 0) code = engine_->SetClientRole(
          role == "viewer" ? AliRTCSdk::AliEngineClientRoleLive
                           : AliRTCSdk::AliEngineClientRoleInteractive);
      // Pre-join is muted for every role. Setting the client role alone is
      // not enough: ARTC can publish microphone audio by default.
      if (code == 0) {
        code = engine_->PublishLocalAudioStream(false);
        if (code == 0) code = engine_->PublishLocalVideoStream(false);
      }
      local_mic_muted_ = true;
      if (code == 0) {
        pending_join_ = std::move(result);
        code = engine_->JoinChannel(auth.c_str(), channel.c_str(),
                                    local_uid_.c_str(), name.c_str());
      }
      if (code != 0) {
        if (pending_join_) result = std::move(pending_join_);
        Failure(std::move(result),
                "ARTC native join initialization failed: " + std::to_string(code));
      }
      return;
    }
    if (!engine_) {
      Failure(std::move(result), "ARTC engine is not initialized", "invalid_state");
      return;
    }
    if (method == "listScreenShareSources") {
      flutter::EncodableList sources;
      for (const auto kind : {
          AliRTCSdk::AliEngineScreenShareDesktop,
          AliRTCSdk::AliEngineScreenShareWindow}) {
        auto* list = engine_->GetScreenShareSourceInfo(kind);
        if (!list) continue;
        const auto count = list->GetCount();
        for (unsigned int i = 0; i < count; ++i) {
          const auto item = list->GetSourceInfo(i);
          const std::string source_id = item.sourceId.c_str();
          if (!ParseScreenShareId(source_id)) continue;
          const std::string source_name = item.sourceName.c_str();
          sources.emplace_back(Map{
            {Value("id"), Value(source_id)},
            {Value("name"), Value(source_name.empty()
                ? (kind == AliRTCSdk::AliEngineScreenShareWindow
                    ? "Application window" : "Entire display")
                : source_name)},
            {Value("kind"), Value(
                kind == AliRTCSdk::AliEngineScreenShareWindow
                    ? "window" : "display")},
          });
        }
        list->Release();
      }
      result->Success(Value(std::move(sources)));
      return;
    }
    if (method == "leave") {
      if (pending_leave_) {
        Failure(std::move(result), "ARTC leave already pending", "invalid_state");
        return;
      }
      pending_leave_ = std::move(result);
      const int code = engine_->LeaveChannel();
      if (code != 0) Failure(std::move(pending_leave_),
                             "ARTC leave failed: " + std::to_string(code));
      return;
    }
    int code = 0;
    if (method == "setMuted") {
      const bool muted = ArgBool(args, "muted");
      if (muted != local_mic_muted_) {
        if (muted) {
          // Stop capturing/transmitting and then remove the publication.
          code = engine_->MuteLocalMic(true);
          if (code == 0) {
            code = engine_->PublishLocalAudioStream(false);
            if (code != 0) engine_->MuteLocalMic(false);
          }
        } else {
          // Unmuting the capture alone cannot publish audio if the room
          // started with microphone publication disabled.
          code = engine_->PublishLocalAudioStream(true);
          if (code == 0) {
            code = engine_->MuteLocalMic(false);
            if (code != 0) engine_->PublishLocalAudioStream(false);
          }
        }
        if (code == 0) local_mic_muted_ = muted;
      }
    } else if (method == "setVideoEnabled") {
      const bool enabled = ArgBool(args, "enabled");
      code = engine_->EnableLocalVideo(enabled);
      if (code == 0) code = engine_->PublishLocalVideoStream(enabled);
    } else if (method == "sendMessage") {
      const auto data = ArgString(args, "message");
      if (data.size() > 1024) {
        Failure(std::move(result), "ARTC data message exceeds 1024 bytes",
                "invalid_argument");
        return;
      }
      AliRTCSdk::AliEngineDataChannelMsg message;
      message.type = AliRTCSdk::AliEngineDataChannelCustom;
      message.data = const_cast<char*>(data.data());
      message.dataLen = static_cast<int>(data.size());
      code = engine_->SendDataChannelMessage(message);
    } else if (method == "setScreenShareEnabled") {
      if (ArgBool(args, "enabled")) {
        AliRTCSdk::AliEngineScreenShareConfig config;
        config.isPushStream = true;
        const auto source_id = ArgString(args, "sourceId");
        const auto source_kind = ArgString(args, "sourceKind");
        if (!source_id.empty()) {
          const auto id = ParseScreenShareId(source_id);
          if (!id || (source_kind != "window" &&
                      source_kind != "display")) {
            Failure(std::move(result), "Invalid ARTC capture source ID",
                    "invalid_argument");
            return;
          }
          const auto vendor_kind = source_kind == "window"
              ? AliRTCSdk::AliEngineScreenShareWindow
              : AliRTCSdk::AliEngineScreenShareDesktop;
          auto* list = engine_->GetScreenShareSourceInfo(vendor_kind);
          bool found = false;
          if (list) {
            for (unsigned int i = 0; i < list->GetCount(); ++i) {
              if (source_id == list->GetSourceInfo(i).sourceId.c_str()) {
                found = true;
                break;
              }
            }
            list->Release();
          }
          if (!found) {
            Failure(std::move(result), "Selected ARTC window is no longer available",
                    "invalid_argument");
            return;
          }
          code = source_kind == "window"
              ? engine_->StartScreenShareByWindowId(*id, config)
              : engine_->StartScreenShareByDesktopId(*id, config);
        } else {
          // Preserve existing direct SDK call behavior for host applications
          // that don't opt into the new window/desktop chooser.
          AliRTCSdk::AliEngineScreenShareRegion region;
          region.originX = static_cast<float>(GetSystemMetrics(SM_XVIRTUALSCREEN));
          region.originY = static_cast<float>(GetSystemMetrics(SM_YVIRTUALSCREEN));
          region.width = static_cast<float>(GetSystemMetrics(SM_CXVIRTUALSCREEN));
          region.height = static_cast<float>(GetSystemMetrics(SM_CYVIRTUALSCREEN));
          code = engine_->StartScreenShareByScreenRegion(region, config);
        }
      } else {
        code = engine_->StopScreenShare();
      }
    } else if (method == "switchCamera" ||
               method == "attachProcessedVideoSource" ||
               method == "detachProcessedVideoSource") {
      Failure(std::move(result), "ARTC Windows feature is not implemented",
              "method_not_implemented");
      return;
    } else {
      result->NotImplemented();
      return;
    }
    if (code == 0) result->Success();
    else Failure(std::move(result),
                 "ARTC native operation failed: " + std::to_string(code));
#endif
  }

  flutter::PluginRegistrarWindows* registrar_;
  bool local_mic_muted_ = true;
  HWND hwnd_ = nullptr;
  UINT message_ = 0;
  int delegate_id_ = -1;
  std::atomic_bool active_{true};
  std::mutex dispatch_mutex_;
  std::deque<std::function<void()>> dispatch_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
  std::mutex textures_mutex_;
  std::map<std::string, std::shared_ptr<ArtcFrameTexture>> textures_;
#ifdef ARTC_WINDOWS_SDK_AVAILABLE
  AliRTCSdk::AliEngine* engine_ = nullptr;
  AliRTCSdk::IAliEngineMediaEngine* media_ = nullptr;
  NativeEvents native_events_{this};
  VideoObserver video_observer_{this};
  std::string local_uid_;
  std::unique_ptr<Result> pending_join_;
  std::unique_ptr<Result> pending_leave_;
#endif
};
}  // namespace

void FlutterRealtimeMediaArtcPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  ArtcWindowsPlugin::Register(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
