#pragma once

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_AWS_DESKTOP_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_AWS_DESKTOP_PLUGIN_EXPORT __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

FLUTTER_AWS_DESKTOP_PLUGIN_EXPORT void
FlutterRealtimeMediaAwsDesktopPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#ifdef __cplusplus
}
#endif
