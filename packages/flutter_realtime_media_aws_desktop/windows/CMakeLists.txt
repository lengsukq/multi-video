cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_realtime_media_aws_desktop")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

get_filename_component(REALTIME_PACKAGE_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(REALTIME_PROCESSED_VIDEO_INCLUDE
  "${REALTIME_PACKAGE_WINDOWS_DIR}/../../flutter_realtime_processed_video/windows/include" ABSOLUTE)
if(NOT EXISTS "${REALTIME_PROCESSED_VIDEO_INCLUDE}/processed_video_frame_api.h")
  message(FATAL_ERROR "Shared processed-video headers missing: ${REALTIME_PROCESSED_VIDEO_INCLUDE}")
endif()

add_library(${PLUGIN_NAME} SHARED
  "flutter_realtime_media_aws_desktop_plugin.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX WIN32_LEAN_AND_MEAN)
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${REALTIME_PROCESSED_VIDEO_INCLUDE}"
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  windowscodecs
  ole32
  gdi32
  user32
  dwmapi
)

set(flutter_realtime_media_aws_desktop_bundled_libraries
  ""
  PARENT_SCOPE
)
