cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_realtime_video_effects")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")
# Windows CMake traverses Flutter plugin symlinks differently from source
# directories. The shared frame headers live in a sibling source package.
get_filename_component(REALTIME_PACKAGE_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(REALTIME_PROCESSED_VIDEO_INCLUDE
  "${REALTIME_PACKAGE_WINDOWS_DIR}/../../flutter_realtime_processed_video/windows/include" ABSOLUTE)
if(NOT EXISTS "${REALTIME_PROCESSED_VIDEO_INCLUDE}/processed_video_frame_hub.h")
  message(FATAL_ERROR "Shared processed-video headers missing: ${REALTIME_PROCESSED_VIDEO_INCLUDE}")
endif()
add_library(${PLUGIN_NAME} SHARED "flutter_realtime_video_effects_plugin.cpp")
apply_standard_settings(${PLUGIN_NAME})
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${REALTIME_PROCESSED_VIDEO_INCLUDE}"
)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
    flutter flutter_wrapper_plugin mfplat mfreadwrite mf mfuuid windowscodecs ole32)

include("${CMAKE_CURRENT_SOURCE_DIR}/onnxruntime.cmake")
realtime_effects_configure_ort(${PLUGIN_NAME})
set(flutter_realtime_video_effects_bundled_libraries
    "${REALTIME_EFFECTS_ORT_BUNDLED_DLL}"
    "${REALTIME_EFFECTS_ORT_BUNDLED_LICENSE}" PARENT_SCOPE)
