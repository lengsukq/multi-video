cmake_minimum_required(VERSION 3.16)
project(realtime_processed_video_native_tests LANGUAGES CXX)

enable_testing()

foreach(test_name IN ITEMS
    processed_video_compositor_test
    processed_video_blur_test
    processed_video_frame_hub_test
    processed_video_i420_test)
  add_executable(${test_name} ${test_name}.cpp)
  target_compile_features(${test_name} PRIVATE cxx_std_17)
  add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()
