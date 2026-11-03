# flutter_realtime_video_effects

Provider-neutral local video effects and processed-video bridge for the
multi-provider livestream/meeting SDK.

Dart exchanges configuration and a `sourceId` only. Camera frames stay inside
the platform bridge and never travel over a MethodChannel.

```text
Camera
  ↓
flutter_realtime_video_effects   capture + segmentation + compose
  ↓
ProcessedVideoSource(sourceId)   local preview: Flutter Texture / HTML video
  ↓
Provider ProcessedVideoSink      published track
```

| Platform bridge | Status | Output |
| --- | --- | --- |
| Android | Implemented | Native RGBA frame hub + Flutter Texture preview |
| macOS | Implemented | Native `CVPixelBuffer` frame hub + Flutter Texture preview |
| Web | Implemented | Processed `MediaStreamTrack` + HTML video preview |
| iOS | Native bridge + iOS Release build verified; real-device E2E pending | Vision + Core Image BGRA `CVPixelBuffer` hub / Flutter Texture; LiveKit, Agora, TRTC native sinks |
| Windows | Native plugin and three provider sinks written; Windows native build and device E2E pending | Media Foundation, PPHumanSeg ONNX, BGRA compositing, Flutter Texture, LiveKit/Agora/TRTC custom video tracks |

Provider adapters own only the sink side (`ProcessedVideoSink`). When an
adapter cannot consume the platform output directly, attachment fails closed
instead of routing frames through Dart or publishing the raw camera frame.

The iOS bridge is **development source**, not part of published
`flutter_realtime_sdk 0.1.0-dev.12`. It has no physical-iPhone/remote-pixel
acceptance record yet. LiveKit, Agora and Tencent TRTC have native iOS
processed-video sink code and the iOS unsigned Release build passes.
Windows now has native camera and ONNX person-segmentation source code, with
verified model bytes/Apache-2.0 license and portable C++ compositor tests.
**This code has not been built or tested on Windows**. Windows CMake fetches
the official, SHA256-pinned ONNX Runtime 1.23.2 x64 distribution, linking and
bundling the DLL and license. Offline builds can set
`REALTIME_ONNXRUNTIME_ROOT` to the installed C++ SDK. A missing or invalid
runtime is a build error; it must not silently disable requested effects.
LiveKit, Agora and TRTC have native Windows processed-video
publisher bridges in source, including a custom VideoSource patch in the
vendored `flutter_webrtc` fork. Their implementation is not considered verified
until a Windows x64 native build and dual-device RTC test pass. A local Texture
must never be mistaken for successful remote camera publication.
The Windows C++ Frame Hub rejects raw frames when a virtual background is
required. Verify real remote pixels before claiming Windows production support.

## Shared frame contract

- Create/configure/enable/select/dispose through `VideoEffectsBridge`. A
  `ProcessedVideoSource` carries identity and preview metadata, not frame bytes.
- Android publishes tightly packed, top-down RGBA (`rowStride = width * 4`),
  a monotonic nanosecond timestamp and clockwise `rotationDegrees`. Pixels are
  unmirrored; preview mirroring is independent. The hub's read-only buffer is
  valid during the synchronous sink callback. A sink retaining it must copy it.
- macOS publishes retained BGRA `CVPixelBuffer`s in upright orientation, with
  actual bytes-per-row and a nanosecond timestamp. Consumers must respect row
  padding and retain the pixel buffer for asynchronous work.
- Web exposes one stable canvas `MediaStreamTrack`; provider adapters clone it
  when owning/stopping their input. Changing camera/effect preserves that output.
- Provider adapters consume this common content and only adapt vendor input
  format/orientation/ownership. They never recapture or rerun segmentation.
  macOS Chime/IVS use a local JPEG adapter to WebKit and require a successful
  runtime capability probe; frame-ready notifications replace fixed polling.
- None skips segmentation and effect composition. Android/macOS use the raw
  capture path; Web copies camera frames to its stable output canvas. SDK Pre-Join
  and room sources request 30 fps. Capture/compute/network limits may lower FPS.
- Preview uses contain by default so the entire camera frame stays visible.
  `BoxFit.cover` can be requested explicitly.

## Local verification

The capability matrix records implementation and actual validation separately.
Current regression entry points (using dependencies already installed locally):

```sh
node --test packages/flutter_realtime_video_effects/test/web_bridge_test.mjs \
  packages/flutter_realtime_media_aws_desktop/test/aws_desktop_runtime_test.mjs \
  tool/provider_web_assets/src/bridge.test.js
# macOS: real native frame encoding, local scheme decoding and canvas video output
packages/flutter_realtime_media_aws_desktop/test/run_macos_native_frame_feed_test.sh
cd example/android
./gradlew :flutter_realtime_video_effects:testDebugUnitTest \
  :flutter_realtime_media_ivs:compileDebugJavaWithJavac \
  :flutter_realtime_video_effects:externalNativeBuildDebug --offline
```

## Web assets

`assets/web/` is generated by
`scripts/build_provider_web_assets.sh` (MediaPipe Tasks Vision runtime, wasm
and models) and is committed on purpose, exactly like
`packages/flutter_realtime_sdk/assets/provider_web_runtime`. For a bridge-only JS change, sync the source to
`assets/web/video-effects-bridge.js`; vendor runtime/model changes require
rebuilding the bundles.

See the repository [README](../../README.md) and
[capability matrix](../../doc/SDK_CAPABILITY_MATRIX.md) for the end-to-end usage
and platform status.
