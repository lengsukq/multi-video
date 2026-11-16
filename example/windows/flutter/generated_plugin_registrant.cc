//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <agora_rtc_engine/agora_rtc_engine_plugin.h>
#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <flutter_realtime_media_agora/flutter_realtime_media_agora_plugin_c_api.h>
#include <flutter_realtime_media_artc/flutter_realtime_media_artc_plugin_c_api.h>
#include <flutter_realtime_media_livekit/flutter_realtime_media_livekit_plugin_c_api.h>
#include <flutter_realtime_media_trtc/flutter_realtime_media_trtc_plugin_c_api.h>
#include <flutter_realtime_screen_annotation/flutter_realtime_screen_annotation_plugin_c_api.h>
#include <flutter_realtime_video_effects/flutter_realtime_video_effects_plugin_c_api.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <iris_method_channel/iris_method_channel_plugin_c_api.h>
#include <livekit_client/live_kit_plugin.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <tencent_cloud_chat_sdk/tencent_cloud_chat_sdk_plugin_c_api.h>
#include <tencent_rtc_sdk/trtc_plugin_c_api.h>
#include <url_launcher_windows/url_launcher_windows.h>
#include <webview_flutter_windows/webview_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AgoraRtcEnginePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AgoraRtcEnginePlugin"));
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ConnectivityPlusWindowsPlugin"));
  FlutterRealtimeMediaAgoraPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeMediaAgoraPluginCApi"));
  FlutterRealtimeMediaArtcPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeMediaArtcPluginCApi"));
  FlutterRealtimeMediaLivekitPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeMediaLivekitPluginCApi"));
  FlutterRealtimeMediaTrtcPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeMediaTrtcPluginCApi"));
  FlutterRealtimeScreenAnnotationPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeScreenAnnotationPluginCApi"));
  FlutterRealtimeVideoEffectsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterRealtimeVideoEffectsPluginCApi"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
  IrisMethodChannelPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("IrisMethodChannelPluginCApi"));
  LiveKitPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("LiveKitPlugin"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  TencentCloudChatSdkPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TencentCloudChatSdkPluginCApi"));
  TrtcPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("TrtcPluginCApi"));
  UrlLauncherWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("UrlLauncherWindows"));
  WebviewWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewWindowsPlugin"));
}
