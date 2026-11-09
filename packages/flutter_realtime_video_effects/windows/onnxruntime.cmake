# Deterministic Windows x64 ONNX Runtime runtime and import library.
# Builds may override this via REALTIME_ONNXRUNTIME_ROOT to work offline.
set(REALTIME_EFFECTS_ORT_VERSION "1.23.2")
set(REALTIME_EFFECTS_ORT_SHA256 "0b38df9af21834e41e73d602d90db5cb06dbd1ca618948b8f1d66d607ac9f3cd")
set(REALTIME_EFFECTS_ORT_URL
    "https://github.com/microsoft/onnxruntime/releases/download/v${REALTIME_EFFECTS_ORT_VERSION}/onnxruntime-win-x64-${REALTIME_EFFECTS_ORT_VERSION}.zip")

# Official ONNX Runtime DirectML NuGet (MIT), pinned and SHA256 verified.
# If unavailable we continue using the original standalone CPU runtime.
set(REALTIME_EFFECTS_DML_VERSION "1.24.4")
set(REALTIME_EFFECTS_DML_SHA256 "57e9f11b73437bef7a309496135d4c1f96b1a8e9ddba60013fa27bfc1d788681")
set(REALTIME_EFFECTS_DML_URL
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/${REALTIME_EFFECTS_DML_VERSION}/microsoft.ml.onnxruntime.directml.${REALTIME_EFFECTS_DML_VERSION}.nupkg")

option(REALTIME_EFFECTS_DISABLE_DIRECTML "Build Windows virtual backgrounds without DirectML" OFF)

function(realtime_effects_configure_ort target)
  if(CMAKE_SIZEOF_VOID_P LESS 8)
    message(FATAL_ERROR "Windows virtual backgrounds require x64")
  endif()
  if(NOT REALTIME_EFFECTS_DISABLE_DIRECTML)
    set(dml_root "$ENV{REALTIME_ONNXRUNTIME_DML_ROOT}")
    if(NOT dml_root)
      set(dml_root "${CMAKE_CURRENT_BINARY_DIR}/realtime-effects-dml")
      if(NOT EXISTS "${dml_root}/build/native/include/dml_provider_factory.h")
        file(MAKE_DIRECTORY "${dml_root}")
        set(archive "${dml_root}/onnxruntime-directml.nupkg")
        message(STATUS "Fetching optional pinned ONNX Runtime DirectML ${REALTIME_EFFECTS_DML_VERSION}")
        file(DOWNLOAD "${REALTIME_EFFECTS_DML_URL}" "${archive}"
          EXPECTED_HASH "SHA256=${REALTIME_EFFECTS_DML_SHA256}"
          TLS_VERIFY ON TIMEOUT 90 INACTIVITY_TIMEOUT 25 STATUS download_status)
        list(GET download_status 0 download_code)
        if(download_code EQUAL 0)
          execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xvf "${archive}"
            WORKING_DIRECTORY "${dml_root}" OUTPUT_QUIET
            RESULT_VARIABLE extraction_code)
          if(NOT extraction_code EQUAL 0)
            message(WARNING "DirectML package extraction failed; CPU fallback enabled")
          endif()
        else()
          message(WARNING "DirectML download unavailable; CPU fallback enabled: ${download_status}")
        endif()
      endif()
    endif()
    if(EXISTS "${dml_root}/build/native/include/dml_provider_factory.h" AND
        EXISTS "${dml_root}/runtimes/win-x64/native/onnxruntime.lib" AND
        EXISTS "${dml_root}/runtimes/win-x64/native/onnxruntime.dll")
      target_include_directories(${target} PRIVATE "${dml_root}/build/native/include")
      target_link_libraries(${target} PRIVATE
        "${dml_root}/runtimes/win-x64/native/onnxruntime.lib" dxgi)
      target_compile_definitions(${target} PRIVATE
        REALTIME_VIDEO_EFFECTS_ONNX=1 REALTIME_VIDEO_EFFECTS_DIRECTML=1)
      set(REALTIME_EFFECTS_ORT_BUNDLED_DLL
        "${dml_root}/runtimes/win-x64/native/onnxruntime.dll" PARENT_SCOPE)
      set(REALTIME_EFFECTS_ORT_BUNDLED_PROVIDER_DLL
        "${dml_root}/runtimes/win-x64/native/onnxruntime_providers_shared.dll" PARENT_SCOPE)
      if(EXISTS "${dml_root}/LICENSE")
        set(REALTIME_EFFECTS_ORT_BUNDLED_LICENSE "${dml_root}/LICENSE" PARENT_SCOPE)
      endif()
      message(STATUS "Windows effects: DirectML enabled (CPU fallback always available)")
      return()
    endif()
  endif()
  set(ort_root "$ENV{REALTIME_ONNXRUNTIME_ROOT}")
  if(NOT ort_root)
    set(extract_root "${CMAKE_CURRENT_BINARY_DIR}/realtime-effects-ort")
    set(ort_root "${extract_root}/onnxruntime-win-x64-${REALTIME_EFFECTS_ORT_VERSION}")
    if(NOT EXISTS "${ort_root}/include/onnxruntime_cxx_api.h")
      file(MAKE_DIRECTORY "${extract_root}")
      set(archive "${extract_root}/onnxruntime-win-x64-${REALTIME_EFFECTS_ORT_VERSION}.zip")
      message(STATUS "Fetching pinned official ONNX Runtime v${REALTIME_EFFECTS_ORT_VERSION} x64 package")
      file(DOWNLOAD "${REALTIME_EFFECTS_ORT_URL}" "${archive}"
        EXPECTED_HASH "SHA256=${REALTIME_EFFECTS_ORT_SHA256}"
        TLS_VERIFY ON STATUS download_status)
      list(GET download_status 0 download_code)
      if(NOT download_code EQUAL 0)
        message(FATAL_ERROR "ONNX Runtime download or SHA256 verification failed: ${download_status}")
      endif()
      execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xzf "${archive}"
        WORKING_DIRECTORY "${extract_root}"
        RESULT_VARIABLE extract_code)
      if(NOT extract_code EQUAL 0)
        message(FATAL_ERROR "Could not unpack pinned Windows ONNX Runtime package")
      endif()
    endif()
  endif()
  if(NOT EXISTS "${ort_root}/include/onnxruntime_cxx_api.h" OR
     NOT EXISTS "${ort_root}/lib/onnxruntime.lib" OR
     NOT EXISTS "${ort_root}/lib/onnxruntime.dll")
    message(FATAL_ERROR
      "Windows virtual background requires the official ONNX Runtime x64 headers/import lib/DLL: ${ort_root}")
  endif()
  target_include_directories(${target} PRIVATE "${ort_root}/include")
  target_link_libraries(${target} PRIVATE "${ort_root}/lib/onnxruntime.lib")
  target_compile_definitions(${target} PRIVATE REALTIME_VIDEO_EFFECTS_ONNX=1)
  set(REALTIME_EFFECTS_ORT_BUNDLED_DLL "${ort_root}/lib/onnxruntime.dll" PARENT_SCOPE)
  # Preserve the redistributable license alongside the packaged runtime.
  if(EXISTS "${ort_root}/LICENSE")
    set(REALTIME_EFFECTS_ORT_BUNDLED_LICENSE "${ort_root}/LICENSE" PARENT_SCOPE)
  endif()
endfunction()
