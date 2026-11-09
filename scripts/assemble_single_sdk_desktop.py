#!/usr/bin/env python3
"""Bundle Web registrar and desktop native plugins into one SDK."""

import json
import shutil
from pathlib import Path

from audit_single_pub_package import ROOT

OUT = ROOT / "build" / "single_sdk_candidate"
ANNOTATION = ROOT / "packages" / "flutter_realtime_screen_annotation"
VIDEO_EFFECTS = ROOT / "packages" / "flutter_realtime_video_effects"
PROCESSED_VIDEO = ROOT / "packages" / "flutter_realtime_processed_video"
LIVEKIT = ROOT / "packages" / "flutter_realtime_media_livekit"
AGORA = ROOT / "packages" / "flutter_realtime_media_agora"
TRTC = ROOT / "packages" / "flutter_realtime_media_trtc"


def enable_platform(name: str, config: str) -> None:
    pubspec = OUT / "pubspec.yaml"
    source = pubspec.read_text()
    marker = "  plugin:\n    platforms:\n"
    if marker not in source:
        raise ValueError("Assemble Android/macOS plugin metadata first")
    if f"      {name}:\n" not in source:
        source = source.replace(marker, marker + f"      {name}:\n" + config, 1)
        pubspec.write_text(source)


def copy_platform(platform: str) -> Path:
    src = ANNOTATION / platform
    out = OUT / platform
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(
        src,
        out,
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo"),
    )
    return out


def windows() -> None:
    dst = copy_platform("windows")
    # The public SDK merges plugin registration into one DLL, but the
    # effects source and its vendor-independent frame hub stay in separate
    # source subdirectories to preserve local include paths.
    shutil.copytree(
        VIDEO_EFFECTS / "windows", dst / "effects",
        ignore=shutil.ignore_patterns(
            "test", "*.md", "*.py", "__pycache__", "*.pyc", "*.pyo"
        ),
    )
    shutil.copytree(PROCESSED_VIDEO / "windows" / "include",
                    dst / "processed_video" / "include")
    for package, folder in ((LIVEKIT, "livekit"), (AGORA, "agora"),
                            (TRTC, "trtc")):
        shutil.copytree(package / "windows", dst / folder)
    api = dst / "include" / "flutter_realtime_sdk"
    api.mkdir(parents=True, exist_ok=True)
    (api / "flutter_realtime_sdk_plugin_c_api.h").write_text("""#ifndef FLUTTER_REALTIME_SDK_PLUGIN_C_API_H_
#define FLUTTER_REALTIME_SDK_PLUGIN_C_API_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_SDK_EXPORT __declspec(dllexport)
#else
#define FLUTTER_SDK_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
FLUTTER_SDK_EXPORT void FlutterRealtimeSdkPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
""")
    (dst / "sdk_plugin_c_api.cpp").write_text("""#include "include/flutter_realtime_sdk/flutter_realtime_sdk_plugin_c_api.h"
#include "include/flutter_realtime_screen_annotation/flutter_realtime_screen_annotation_plugin_c_api.h"
#include "effects/include/flutter_realtime_video_effects/flutter_realtime_video_effects_plugin_c_api.h"
#include "livekit/include/flutter_realtime_media_livekit/flutter_realtime_media_livekit_plugin_c_api.h"
#include "agora/include/flutter_realtime_media_agora/flutter_realtime_media_agora_plugin_c_api.h"
#include "trtc/include/flutter_realtime_media_trtc/flutter_realtime_media_trtc_plugin_c_api.h"
void FlutterRealtimeSdkPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  FlutterRealtimeScreenAnnotationPluginCApiRegisterWithRegistrar(registrar);
  FlutterRealtimeVideoEffectsPluginCApiRegisterWithRegistrar(registrar);
  FlutterRealtimeMediaLivekitPluginCApiRegisterWithRegistrar(registrar);
  FlutterRealtimeMediaAgoraPluginCApiRegisterWithRegistrar(registrar);
  FlutterRealtimeMediaTrtcPluginCApiRegisterWithRegistrar(registrar);
}
""")
    cmake = (dst / "CMakeLists.txt")
    source = cmake.read_text().replace(
        'set(PROJECT_NAME "flutter_realtime_screen_annotation")',
        'set(PROJECT_NAME "flutter_realtime_sdk")'
    ).replace(
        'SHARED "screen_annotation_plugin.cpp"',
        'SHARED "screen_annotation_plugin.cpp" "sdk_plugin_c_api.cpp" '
        '"effects/flutter_realtime_video_effects_plugin.cpp" '
        '"livekit/livekit_processed_video_plugin.cpp" '
        '"agora/agora_processed_video_plugin.cpp" '
        '"trtc/trtc_processed_video_plugin.cpp"'
    ).replace(
        'set(flutter_realtime_screen_annotation_bundled_libraries',
        'set(flutter_realtime_sdk_bundled_libraries'
    )
    # The bundled SDK must ship the same pinned ONNX Runtime as the standalone
    # source plugin; never compile a silently disabled placeholder.
    source += (
        '\ntarget_include_directories(${PLUGIN_NAME} PRIVATE\n'
        '  "${CMAKE_CURRENT_SOURCE_DIR}/effects"\n'
        '  "${CMAKE_CURRENT_SOURCE_DIR}/livekit"\n'
        '  "${CMAKE_CURRENT_SOURCE_DIR}/agora"\n'
        '  "${CMAKE_CURRENT_SOURCE_DIR}/trtc"\n'
        '  "${CMAKE_CURRENT_SOURCE_DIR}/processed_video/include"\n'
        ')\n'
        'target_link_libraries(${PLUGIN_NAME} PRIVATE '
        'mfplat mfreadwrite mf mfuuid windowscodecs ole32 '
        'd3d11 d3dcompiler dxgi)\n'
        '# Keep Windows background effects responsive in Flutter Debug, and '
        'tolerate Media Foundation C4245 in recent MSVC.\n'
        'if(MSVC)\n'
        '  string(REPLACE "/RTC1" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")\n'
        '  string(REPLACE "/Od" "" CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG}")\n'
        '  target_compile_options(${PLUGIN_NAME} PRIVATE '
        '"$<$<CONFIG:Debug>:/O2>" /wd4245)\n'
        'endif()\n'
        # The Agora Windows Flutter plugin downloads pinned native SDK
        # headers during its CMake configure step; this module compiles only
        # after that dependency has been added.
        'set(AGORA_WINDOWS "${CMAKE_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/agora_rtc_engine/windows")\n'
        'file(GLOB_RECURSE AGORA_SDK_HEADERS "${AGORA_WINDOWS}/third_party/native/lib/*/sdk/high_level_api/include/IAgoraRtcEngine.h")\n'
        'if(NOT AGORA_SDK_HEADERS)\n'
        '  message(FATAL_ERROR "Agora native Windows SDK headers missing")\n'
        'endif()\n'
        'list(GET AGORA_SDK_HEADERS 0 AGORA_HEADER)\n'
        'get_filename_component(AGORA_NATIVE_INCLUDE "${AGORA_HEADER}" DIRECTORY)\n'
        'set(TRTC_WINDOWS "${CMAKE_SOURCE_DIR}/flutter/ephemeral/.plugin_symlinks/tencent_rtc_sdk/windows")\n'
        'if(NOT EXISTS "${TRTC_WINDOWS}/include/TRTC/ITRTCCloud.h")\n'
        '  message(FATAL_ERROR "Tencent TRTC Windows SDK headers missing")\n'
        'endif()\n'
        'target_include_directories(${PLUGIN_NAME} PRIVATE "${AGORA_NATIVE_INCLUDE}" "${TRTC_WINDOWS}/include")\n'
        'include("${CMAKE_CURRENT_SOURCE_DIR}/effects/onnxruntime.cmake")\n'
        'realtime_effects_configure_ort(${PLUGIN_NAME})\n'
        'if(REALTIME_EFFECTS_ORT_BUNDLED_PROVIDER_DLL)\n'
        '  target_sources(${PLUGIN_NAME} PRIVATE "effects/directml_provider.cpp")\n'
        'endif()\n'
        'set(flutter_realtime_sdk_bundled_libraries\n'
        '  "${REALTIME_EFFECTS_ORT_BUNDLED_DLL}"\n'
        '  "${REALTIME_EFFECTS_ORT_BUNDLED_PROVIDER_DLL}"\n'
        '  "${REALTIME_EFFECTS_ORT_BUNDLED_LICENSE}" PARENT_SCOPE)\n'
    )
    cmake.write_text(source)
    enable_platform("windows", "        pluginClass: FlutterRealtimeSdkPluginCApi\n")


def linux() -> None:
    dst = copy_platform("linux")
    api = dst / "include" / "flutter_realtime_sdk"
    api.mkdir(parents=True, exist_ok=True)
    (api / "flutter_realtime_sdk_plugin.h").write_text("""#ifndef FLUTTER_REALTIME_SDK_PLUGIN_H_
#define FLUTTER_REALTIME_SDK_PLUGIN_H_
#include <flutter_linux/flutter_linux.h>
G_BEGIN_DECLS
__attribute__((visibility("default")))
void flutter_realtime_sdk_plugin_register_with_registrar(FlPluginRegistrar* registrar);
G_END_DECLS
#endif
""")
    (dst / "sdk_plugin.cc").write_text("""#include "include/flutter_realtime_sdk/flutter_realtime_sdk_plugin.h"
#include "include/flutter_realtime_screen_annotation/flutter_realtime_screen_annotation_plugin.h"
void flutter_realtime_sdk_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  flutter_realtime_screen_annotation_plugin_register_with_registrar(registrar);
}
""")
    cmake = dst / "CMakeLists.txt"
    source = cmake.read_text().replace(
        'set(PROJECT_NAME "flutter_realtime_screen_annotation")',
        'set(PROJECT_NAME "flutter_realtime_sdk")'
    ).replace(
        'SHARED "screen_annotation_plugin.cc"',
        'SHARED "screen_annotation_plugin.cc" "sdk_plugin.cc"'
    ).replace(
        'set(flutter_realtime_screen_annotation_bundled_libraries',
        'set(flutter_realtime_sdk_bundled_libraries'
    )
    cmake.write_text(source)
    enable_platform("linux", "        pluginClass: FlutterRealtimeSdkPlugin\n")


def web() -> None:
    source_file = OUT / "lib" / "src" / "_bundled" / "flutter_realtime_video_effects" / "flutter_realtime_video_effects_web.dart"
    if not source_file.exists():
        raise ValueError("Missing rewritten Web registration library")
    enable_platform(
        "web",
        "        pluginClass: FlutterRealtimeVideoEffectsWeb\n"
        "        fileName: src/_bundled/flutter_realtime_video_effects/flutter_realtime_video_effects_web.dart\n",
    )


def run() -> dict:
    if not (OUT / "pubspec.yaml").exists():
        raise ValueError("Run the Dart assembler first")
    windows()
    linux()
    web()
    return {"platforms": ["windows", "linux", "web"],
            "registrations": 3, "publishable": False}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
