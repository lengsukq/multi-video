#pragma once

#include <stdint.h>

// C ABI shared by Windows effects, LiveKit, Agora, and TRTC plugins.
// Individual plugins are built as different DLLs; no STL type crosses DLLs.
// Frame pointers are valid only for the duration of OnFrame. Unsubscribe is
// synchronous and waits for an in-progress callback to exit.
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*RealtimeProcessedOnFrame)(
    void* context, const uint8_t* bgra, uint32_t width, uint32_t height,
    uint32_t stride, uint64_t timestamp_ns);

typedef void* (*RealtimeProcessedSubscribe)(
    const char* source_id, void* context, RealtimeProcessedOnFrame callback);
typedef void (*RealtimeProcessedUnsubscribe)(void* subscription);
typedef void (*RealtimeProcessedReportFailure)(
    const char* source_id, const char* message);

// The host resolves these symbols with GetProcAddress from either
// flutter_realtime_video_effects_plugin.dll or the single SDK DLL.
#ifdef _WIN32
#define REALTIME_PROCESSED_FRAME_EXPORT __declspec(dllexport)
#else
#define REALTIME_PROCESSED_FRAME_EXPORT
#endif
REALTIME_PROCESSED_FRAME_EXPORT void* RealtimeProcessedVideoSubscribe(
    const char* source_id, void* context, RealtimeProcessedOnFrame callback);
REALTIME_PROCESSED_FRAME_EXPORT void RealtimeProcessedVideoUnsubscribe(void* subscription);
REALTIME_PROCESSED_FRAME_EXPORT void RealtimeProcessedVideoReportFailure(
    const char* source_id, const char* message);

#ifdef __cplusplus
}
#endif
