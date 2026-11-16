cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "flutter_realtime_media_artc")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")
get_filename_component(ARTC_REAL_WINDOWS_DIR "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(ARTC_REPO_ROOT "${ARTC_REAL_WINDOWS_DIR}/../../.." REALPATH)

# Local vendor cache is intentionally ignored by git. Consumer projects may
# pass FLUTTER_ARTC_WINDOWS_SDK_ROOT to locate their own licensed SDK.
set(ARTC_SDK_ROOT "$ENV{FLUTTER_ARTC_WINDOWS_SDK_ROOT}")
if(NOT ARTC_SDK_ROOT)
  set(ARTC_SDK_ROOT "${ARTC_REPO_ROOT}/.local/vendor-cache/ali-artc/AliVCSDK_ARTC-7.6.0")
endif()
set(ARTC_INCLUDE "${ARTC_SDK_ROOT}/include")
set(ARTC_BINARY_DIR "${ARTC_SDK_ROOT}/x64/Release")
set(ARTC_HAS_SDK FALSE)
if(EXISTS "${ARTC_INCLUDE}/rtc/engine_interface.h"
    AND EXISTS "${ARTC_BINARY_DIR}/AliRTCSdk.lib"
    AND EXISTS "${ARTC_BINARY_DIR}/AliRTCSdk.dll")
  set(ARTC_HAS_SDK TRUE)
endif()

add_library(${PLUGIN_NAME} SHARED "artc_windows_plugin.cpp")
apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
if(ARTC_HAS_SDK)
  target_compile_definitions(${PLUGIN_NAME} PRIVATE ARTC_WINDOWS_SDK_AVAILABLE=1)
  target_include_directories(${PLUGIN_NAME} PRIVATE "${ARTC_INCLUDE}")
  target_link_libraries(${PLUGIN_NAME} PRIVATE "${ARTC_BINARY_DIR}/AliRTCSdk.lib")
  # Third-party warnings must not disable /WX checks for our own sources.
  target_compile_options(${PLUGIN_NAME} PRIVATE /wd4251 /wd4275 /wd5208 /wd4091)
  file(GLOB ARTC_RUNTIME_DLLS "${ARTC_BINARY_DIR}/*.dll")
  set(flutter_realtime_media_artc_bundled_libraries
    "${ARTC_RUNTIME_DLLS}" PARENT_SCOPE)
  message(STATUS "ARTC Windows x64 native SDK enabled: ${ARTC_SDK_ROOT}")
else()
  set(flutter_realtime_media_artc_bundled_libraries "" PARENT_SCOPE)
  message(STATUS "ARTC Windows native SDK absent: fail-closed bridge only")
endif()
