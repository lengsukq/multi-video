#
# Generated file, do not edit.
#

list(APPEND FLUTTER_PLUGIN_LIST
  agora_rtc_engine
  connectivity_plus
  flutter_realtime_media_agora
  flutter_realtime_media_artc
  flutter_realtime_media_livekit
  flutter_realtime_media_trtc
  flutter_realtime_screen_annotation
  flutter_realtime_video_effects
  flutter_webrtc
  iris_method_channel
  livekit_client
  permission_handler_windows
  tencent_cloud_chat_sdk
  tencent_rtc_sdk
  url_launcher_windows
  webview_flutter_windows
)

list(APPEND FLUTTER_FFI_PLUGIN_LIST
  jni
)

set(PLUGIN_BUNDLED_LIBRARIES)

foreach(plugin ${FLUTTER_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${plugin}/windows plugins/${plugin})
  target_link_libraries(${BINARY_NAME} PRIVATE ${plugin}_plugin)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:${plugin}_plugin>)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${plugin}_bundled_libraries})
endforeach(plugin)

foreach(ffi_plugin ${FLUTTER_FFI_PLUGIN_LIST})
  add_subdirectory(flutter/ephemeral/.plugin_symlinks/${ffi_plugin}/windows plugins/${ffi_plugin})
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${ffi_plugin}_bundled_libraries})
endforeach(ffi_plugin)
