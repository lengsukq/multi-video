cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_realtime_media_livekit")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")
# Use the physical package path, not Flutter's .plugin_symlinks path.
get_filename_component(REALTIME_PACKAGE_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(REALTIME_PROCESSED_VIDEO_INCLUDE
  "${REALTIME_PACKAGE_WINDOWS_DIR}/../../flutter_realtime_processed_video/windows/include" ABSOLUTE)
if(NOT EXISTS "${REALTIME_PROCESSED_VIDEO_INCLUDE}/processed_video_frame_client.h")
  message(FATAL_ERROR "Shared processed-video headers missing: ${REALTIME_PROCESSED_VIDEO_INCLUDE}")
endif()
add_library(${PLUGIN_NAME} SHARED "livekit_processed_video_plugin.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
if(MSVC)
  # Dart remains debuggable, but unoptimized native pixel loops make the
  # 720p background effect unusably slow in Flutter Debug builds. Disable
  # Debug-only /RTC1 in this plugin directory before enabling /O2. CMake's
  # CMP0184 OLD mode puts /RTC1 in CMAKE_CXX_FLAGS_DEBUG, so /RTC- alone
  # cannot reliably override it on Visual Studio generators.
  string(REPLACE "/RTC1" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
  string(REPLACE "/Od" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")
  target_compile_options(${PLUGIN_NAME} PRIVATE
    "$<$<CONFIG:Debug>:/O2>")
endif()
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${REALTIME_PROCESSED_VIDEO_INCLUDE}")
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
set(flutter_realtime_media_livekit_bundled_libraries "" PARENT_SCOPE)
