#pragma once
#include <flutter_plugin_registrar.h>
#if defined(FLUTTER_PLUGIN_IMPL)
#define ARTC_FLUTTER_EXPORT __declspec(dllexport)
#else
#define ARTC_FLUTTER_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
ARTC_FLUTTER_EXPORT void FlutterRealtimeMediaArtcPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
