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
