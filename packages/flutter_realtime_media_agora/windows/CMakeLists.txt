cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_realtime_media_agora")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")
# Flutter exposes plugin sources through Windows symlinks. Resolve the real
# package location before accessing headers shared with the sibling package.
get_filename_component(REALTIME_PACKAGE_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(REALTIME_PROCESSED_VIDEO_INCLUDE
  "${REALTIME_PACKAGE_WINDOWS_DIR}/../../flutter_realtime_processed_video/windows/include" ABSOLUTE)
if(NOT EXISTS "${REALTIME_PROCESSED_VIDEO_INCLUDE}/processed_video_frame_client.h")
  message(FATAL_ERROR "Shared processed-video headers missing: ${REALTIME_PROCESSED_VIDEO_INCLUDE}")
endif()
set(AGORA_WINDOWS "${CMAKE_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/agora_rtc_engine/windows")
file(GLOB_RECURSE AGORA_SDK_HEADERS
  "${AGORA_WINDOWS}/third_party/native/lib/*/sdk/high_level_api/include/IAgoraRtcEngine.h")
if(NOT AGORA_SDK_HEADERS)
  message(FATAL_ERROR "agora_rtc_engine Windows C++ SDK headers not available")
endif()
list(GET AGORA_SDK_HEADERS 0 AGORA_HEADER)
get_filename_component(AGORA_NATIVE_INCLUDE "${AGORA_HEADER}" DIRECTORY)
add_library(${PLUGIN_NAME} SHARED "agora_processed_video_plugin.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${AGORA_NATIVE_INCLUDE}"
  "${REALTIME_PROCESSED_VIDEO_INCLUDE}")
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
set(flutter_realtime_media_agora_bundled_libraries "" PARENT_SCOPE)
