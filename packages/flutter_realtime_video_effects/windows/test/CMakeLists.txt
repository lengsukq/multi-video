cmake_minimum_required(VERSION 3.16)
project(realtime_video_effects_onnx_model_smoke LANGUAGES CXX)

if(NOT DEFINED ONNXRUNTIME_ROOT)
  message(FATAL_ERROR "Pass -DONNXRUNTIME_ROOT=<extracted official ONNX runtime>")
endif()

get_filename_component(REALTIME_EFFECTS_WINDOWS "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
get_filename_component(REALTIME_PROCESSED_INCLUDE
    "${REALTIME_EFFECTS_WINDOWS}/../../flutter_realtime_processed_video/windows/include" ABSOLUTE)
add_executable(onnx_model_smoke_test onnx_model_smoke_test.cpp)
target_compile_features(onnx_model_smoke_test PRIVATE cxx_std_17)
target_compile_definitions(onnx_model_smoke_test PRIVATE REALTIME_VIDEO_EFFECTS_ONNX NOMINMAX)
target_compile_options(onnx_model_smoke_test PRIVATE /utf-8 /EHsc)
target_include_directories(onnx_model_smoke_test PRIVATE
    "${ONNXRUNTIME_ROOT}/include" "${REALTIME_PROCESSED_INCLUDE}")
target_link_libraries(onnx_model_smoke_test PRIVATE
    "${ONNXRUNTIME_ROOT}/lib/onnxruntime.lib"
    mfplat mfreadwrite mf mfuuid ole32 uuid)
add_custom_command(TARGET onnx_model_smoke_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
        "${ONNXRUNTIME_ROOT}/lib/onnxruntime.dll"
        "$<TARGET_FILE_DIR:onnx_model_smoke_test>")

add_executable(camera_capture_smoke_test camera_capture_smoke_test.cpp)
target_compile_features(camera_capture_smoke_test PRIVATE cxx_std_17)
target_compile_definitions(camera_capture_smoke_test PRIVATE NOMINMAX)
target_compile_options(camera_capture_smoke_test PRIVATE /utf-8 /EHsc)
target_include_directories(camera_capture_smoke_test PRIVATE "${REALTIME_PROCESSED_INCLUDE}")
target_link_libraries(camera_capture_smoke_test PRIVATE
    mfplat mfreadwrite mf mfuuid ole32 uuid)

add_executable(d3d11_compositor_smoke_test d3d11_compositor_smoke_test.cpp)
target_compile_features(d3d11_compositor_smoke_test PRIVATE cxx_std_17)
target_compile_definitions(d3d11_compositor_smoke_test PRIVATE NOMINMAX)
target_compile_options(d3d11_compositor_smoke_test PRIVATE /utf-8 /EHsc)
target_include_directories(d3d11_compositor_smoke_test PRIVATE
    "${REALTIME_PROCESSED_INCLUDE}")
target_link_libraries(d3d11_compositor_smoke_test PRIVATE
    d3d11 d3dcompiler dxgi)

add_executable(video_pixel_pool_smoke_test video_pixel_pool_smoke_test.cpp)
target_compile_features(video_pixel_pool_smoke_test PRIVATE cxx_std_17)
target_compile_definitions(video_pixel_pool_smoke_test PRIVATE NOMINMAX)
target_compile_options(video_pixel_pool_smoke_test PRIVATE /utf-8 /EHsc)
target_include_directories(video_pixel_pool_smoke_test PRIVATE
    "${REALTIME_PROCESSED_INCLUDE}")

# Optional vendor-neutral GPU benchmark; uses official MIT-licensed
# ONNX Runtime DirectML NuGet binaries. This never alters the app runtime.
if(DEFINED DIRECTML_ROOT AND EXISTS "${DIRECTML_ROOT}/build/native/include/dml_provider_factory.h")
  add_executable(effects_pipeline_smoke_test
      effects_pipeline_smoke_test.cpp
      "${REALTIME_EFFECTS_WINDOWS}/directml_provider.cpp")
  target_compile_features(effects_pipeline_smoke_test PRIVATE cxx_std_17)
  target_compile_options(effects_pipeline_smoke_test PRIVATE /utf-8 /EHsc)
  target_compile_definitions(effects_pipeline_smoke_test PRIVATE
      NOMINMAX REALTIME_VIDEO_EFFECTS_ONNX=1 REALTIME_VIDEO_EFFECTS_DIRECTML=1)
  target_include_directories(effects_pipeline_smoke_test PRIVATE
      "${DIRECTML_ROOT}/build/native/include"
      "${REALTIME_PROCESSED_INCLUDE}")
  target_link_libraries(effects_pipeline_smoke_test PRIVATE
      "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime.lib"
      d3d11 d3dcompiler dxgi mfplat mfreadwrite mf mfuuid ole32 uuid psapi)
  add_custom_command(TARGET effects_pipeline_smoke_test POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime.dll"
          "$<TARGET_FILE_DIR:effects_pipeline_smoke_test>"
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime_providers_shared.dll"
          "$<TARGET_FILE_DIR:effects_pipeline_smoke_test>")
  add_executable(directml_benchmark directml_benchmark.cpp)
  target_compile_features(directml_benchmark PRIVATE cxx_std_17)
  target_compile_options(directml_benchmark PRIVATE /utf-8 /EHsc)
  target_include_directories(directml_benchmark PRIVATE
      "${DIRECTML_ROOT}/build/native/include")
  target_link_libraries(directml_benchmark PRIVATE
      "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime.lib"
      dxgi ole32)
  add_custom_command(TARGET directml_benchmark POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime.dll"
          "$<TARGET_FILE_DIR:directml_benchmark>"
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
          "${DIRECTML_ROOT}/runtimes/win-x64/native/onnxruntime_providers_shared.dll"
          "$<TARGET_FILE_DIR:directml_benchmark>")
endif()
