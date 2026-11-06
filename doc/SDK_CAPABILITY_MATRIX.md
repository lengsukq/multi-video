# SDK Capability Matrix

> **Current-source audit: 2026-11-06** · Last confirmed published aggregate package:
> `flutter_realtime_sdk 0.1.0-dev.27`. See the
> [detailed current-source provider/platform/feature audit (Chinese)](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md).
> This page also preserves historical acceptance snapshots. **Driver registered,
> implementation present, package built and real-device E2E passed are four distinct claims**.
> Older snapshots do not override the newer source audit.
> Windows native fixes, MSVC CI gates and remaining vendor gaps:
> [Windows SDK implementation and acceptance plan (Chinese)](WINDOWS_SDK_IMPLEMENTATION_2026-11-06.zh-CN.md).

### Current capability summary

| Area | Implemented/declared in current source | Important limitation |
| --- | --- | --- |
| RTC | Five public media providers / six engines: LiveKit, Agora, TRTC, ARTC, AWS Chime (Meeting) and IVS (Live) | Windows drivers: LiveKit/Agora/TRTC; Linux no default driver; ARTC macOS requires separately supplied vendor framework |
| Product Chat | Agora Chat, Tencent Cloud Chat, IVS Chat; explicitly registered independently from RTC | Session-local RTC fallback only if both data send and receive are allowed; IVS Real-Time has no RTC data |
| Owner ends room | Logical owner ends the room on leave; guest/viewer leaves self; remote clients detect backend closure by 5-second presence heartbeat | Logical-room closure is **not** instantaneous vendor-level disconnect; RTC cleanup and network delays vary |
| iOS system sharing | iOS 27+ ScreenCaptureKit source pathways added for all six RTC engines; LiveKit 15–26 has ReplayKit Broadcast Extension fallback | Signed host configuration, actual background cross-app frames, remote media and per-vendor real-device E2E pending |
| Video effects | Android/macOS/Web bridge code; iOS native bridge built unsigned, Windows native/ONNX source present | iOS remote processed pixels and Windows native builds/devices not fully accepted |
| Classroom/live/recording | Whiteboard, Q&A, polls, gifts, recording control plane; historical live recording success feedback on LiveKit/Chime/IVS | Course-specific recording/replay management and comprehensive vendor recording/audio acceptance remain incomplete |

**English** | [简体中文](SDK_CAPABILITY_MATRIX.zh-CN.md)

The application should branch on `MediaCapabilities` / `MediaFeature`, not
on `providerId`. A provider may expose a smaller capability set on a specific
platform or role.

## Generated declarations and acceptance evidence

[Platform, role and feature declarations](generated/SDK_DECLARATIONS.md) are generated from optional drivers and adapter source.
`python3 scripts/generate_capability_matrix.py --check` rejects stale output.
Declarations, target builds and real calls are separate evidence; the [unified acceptance entry point](ACCEPTANCE.md) records devices, vendor versions, remote visuals and cleanup.


## Optional provider-bundle platform drivers

**This table describes the driver declarations in the development workspace.**
The private development package `packages/flutter_realtime_sdk` keeps the
provider modules optional. **The published `flutter_realtime_sdk 0.1.0-dev.27`
is instead a single assembled Pub package**: external apps declare only this
one dependency, then explicitly register their chosen providers with
`Realtime(providers: [...])`. There is no need to add internal provider
packages to the host, but the aggregate still resolves native dependencies
that may be unused at runtime. Runtime lazy registration is not native-binary
installation pruning.
Runtime resolves the registered provider for the current platform. A dash
means that the selected bundle lacks that target's driver, which yields a
typed unsupported-platform/unregistered-provider failure rather than an
implicit vendor fallback.

| Public Media provider | Android | iOS | macOS | Windows | Web |
| --- | --- | --- | --- | --- | --- |
| LiveKit | Yes | Yes | Yes | Yes | Yes |
| Agora RTC | Yes | Yes | Yes | Yes | Yes |
| Tencent TRTC | Yes | Yes | Yes | Yes | Yes |
| Alibaba ARTC | Yes | Yes | Conditional* | — | Yes |
| AWS | Yes | Yes | Yes** | — | Yes |

| Product Chat provider | Android | iOS | macOS | Windows | Web |
| --- | --- | --- | --- | --- | --- |
| Agora Chat | Yes | Yes | Yes | — | Yes |
| Tencent Cloud Chat | Yes | Yes | Yes | Yes | Yes |
| Amazon IVS Chat | Yes | Yes | Yes | — | Yes |

The optional bundles do not currently advertise general Linux support. Advanced applications can
add or override drivers with `RealtimeProviderPlugin` without modifying Core.

## Host application requirements

The all-provider SDK Demo currently targets Android API 28+ (compile SDK 37),
iOS 15+, macOS 12+, Windows 10+, and standard Flutter Web in a secure browser
context. Use Flutter 3.47+, Dart 3.12+, and Java 17 for the Android build.
Individual low-level adapter packages may support lower Android versions when
used without the full SDK bundle.

Android plugin manifests contribute the required runtime permissions. Host
iOS/macOS apps must include camera and microphone usage descriptions; macOS
apps also need camera/microphone entitlements. The example contains these
settings. Browsers request device access from the user, and Web deployments
must use HTTPS or localhost. Pre-Join and connection failures report denied
permissions through the SDK's typed diagnostics.

ARTC's iOS binary supports device builds but does not link into the iOS
Simulator. CI therefore targets an iOS device build without codesigning.
`Conditional*` means the ARTC macOS bridge is implemented and build-verified,
but the repository does not redistribute Alibaba's official Mac framework.
Without that framework the adapter fails explicitly with `unsupportedPlatform`.

The Web entries currently refer to the standard JavaScript Flutter Web target.
`flutter build web` is verified, but the current Tencent Cloud Chat dependency
still uses `dart:html`, `dart:js`, and FFI-backed code paths, so Flutter's
Wasm dry-run reports incompatibilities. Do not advertise the bundled Web stack
as Wasm-ready until those upstream dependencies migrate.

The macOS build is verified with CocoaPods. `Yes**` for AWS means the
optional AWS bundle uses one internal WebKit runtime: Meeting loads the
pinned Chime JS SDK and Live loads the pinned IVS Web Broadcast SDK. The same
public `aws` provider and the same Dart session APIs are used; applications do
not create a WebView or add JavaScript assets. Flutter currently warns that
several plugins do not yet provide macOS Swift Package Manager support; this is
a packaging limitation rather than a driver-routing failure.

Amazon IVS Chat is also available on macOS through the same hidden WebKit
runtime, using the locally bundled Chat JavaScript bridge. The chat bridge is
loaded only when an IVS Chat session is first opened.

The current verification host is macOS: Android debug APK, iOS device Release
without codesigning, macOS Release, and JavaScript Web builds are verified.
Windows entries above are available in the corresponding optional bundles and covered by
platform-selection tests. CI is configured to build the Windows example on a
Windows runner; a macOS development host cannot produce a native Windows build
result locally.

The SDK package owns its Web bridge and pinned vendor JavaScript assets. The
facade loads them on the first media or Product Chat connection; applications
do not add script tags, CDN links, or a separate npm build step. Missing or
unreachable bundled assets produce `webSdkUnavailable`.

AWS is presented as one public vendor. Its concrete engine is mode-dependent:
`Meeting -> Chime`, `Live -> IVS Real-Time`. The Chime/IVS columns below describe
the internal engine capabilities used by that AWS routing.

| Capability | LiveKit | Chime | Agora | TRTC | ARTC | IVS Real-Time |
| --- | --- | --- | --- | --- | --- | --- |
| Meeting audio/video | Yes | Yes | Yes | Yes | Yes | Yes |
| Broadcast host/viewer | Yes | No (participant only) | Yes | Yes | Yes | Yes |
| RTC data send | Yes | Yes | Host/participant | Host/participant | Host/participant | No |
| RTC data receive | Yes | Yes | Yes | Yes | Yes | No |
| RTC Chat fallback | Yes when role can send | Yes | Host/participant | Host/participant | Host/participant | No |
| SDK message-size limit | 15 KiB | 2 KiB | 1 KiB | 1 KiB | 1 KiB | — |
| Targeted data | Yes | No | No | No | No | No |
| Unreliable data | Yes | No | No | No | No | No |
| Device enumeration/selection | Yes, platform dependent | Audio output | Not exposed by adapter | Not exposed by adapter | Not exposed by adapter | Mic/camera probe; camera switch on Android/iOS |
| Pre-Join native device probe | Mic/camera | No native probe | No native probe | No native probe | No native probe | Mic/camera |
| Pre-Join provider network probe | Unsupported without issued credentials | No native probe | No native probe | No native probe | No native probe | Unsupported without participant token |
| Network stats | Yes | Not exposed by adapter | Yes | Yes | Not exposed by adapter | Basic RTC stats |
| Screen share | Web/Android/macOS; iOS 27+ ScreenCaptureKit and 15–26 ReplayKit fallback; Windows source | Web Content Share; iOS 27+ source; native Android/macOS not wired | Web/Android/macOS/Windows source; iOS 27+ custom screen track; older iOS gap | Web/Android/macOS/Windows source; iOS 27+ auxiliary track; older iOS gap | Web/Android source; iOS 27+ external screen track; macOS publisher gap | Web screen replaces camera; iOS 27+ Stage camera replacement; Android/macOS publisher gap |
| Processed-video sink for blur / image replacement | Android/macOS/Web; iOS code and unsigned release build; Windows source unverified | Android/macOS conditional/Web; iOS needs real-device verification | Android/macOS/Web; iOS code; Windows native verification pending | Android/macOS/Web; iOS code; Windows native verification pending | Android/macOS conditional/Web; iOS vendor combinations unverified | Android/macOS conditional/Web; iOS vendor combinations unverified |
| Host participant list | Backend + logical owner | Meeting creator via logical owner credential | Backend + logical owner | Backend + logical owner | Backend + logical owner | Backend + logical owner |
| Host remove participant | LiveKit host | No | No | No | No | IVS DisconnectParticipant |
| Host close room | Host via backend | Meeting creator via control plane | Host via backend | Host via backend | Host via backend | Host via backend |

Virtual background has two separate capability layers:

| Effects platform bridge | Android | macOS | Web | iOS | Windows |
| --- | --- | --- | --- | --- | --- |
| Capture + None/Blur/Replace image | Implemented | Implemented | Implemented | Vision / Core Image source and unsigned iOS Release build, device E2E pending | Media Foundation + ONNX source; Windows native build/device E2E pending |
| Realtime local preview | Flutter Texture | Flutter Texture | HTML video | Flutter Texture source; device E2E pending | Flutter Texture source; native build pending |
| Processed source type | Native RGBA Frame Hub | Native `CVPixelBuffer` Frame Hub | `MediaStreamTrack` | BGRA `CVPixelBuffer` Frame Hub | Windows Frame Hub / vendor-custom video source, not yet accepted |

`flutter_realtime_video_effects` owns capture, segmentation and composition.
Every provider adapter implements the sink side only (`ProcessedVideoSink`):

| Provider sink | Android input | macOS input | Web input |
| --- | --- | --- | --- |
| LiveKit | I420 + rotation → WebRTC | `CVPixelBuffer` → WebRTC | Shared track |
| Chime | I420 + rotation → custom video source | Shared native frame → local WebKit encoded transport* | Track clone → video input |
| Agora | Packed RGBA, stride in pixels, rotation metadata | BGRA pixel buffer, stride in pixels | Track clone → custom video track |
| TRTC | Packed RGBA + rotation | `CVPixelBuffer` | Track clone → custom video track |
| ARTC | Packed RGBA + rotation | `CVPixelBuffer` custom input* | Track clone → custom video track |
| IVS Real-Time | RGBA → upright EGL input surface | Shared native frame → local WebKit encoded transport* | Track clone → local stage stream |

\* macOS ARTC requires the installed vendor SDK's custom-input API. macOS
Chime/IVS require a positive WebKit canvas capture / image decode capability
probe. These adapters reject unsupported runtimes; implementation does not
imply support on every OS/browser version. iOS and Windows effects now have
bridge/source code, **but must not be advertised as fully vendor/device-verified**.

"Same frames" means one capture and one effects pipeline per source. Provider
sinks may convert pixel formats, apply the shared rotation metadata, or clone a
track for ownership. They do not open another camera or run another segmenter.
Pixels never pass through Dart/MethodChannel. The macOS AWS sink uses JPEG
inside its local native-to-WebKit transport; that extra encode/decode cost still
exists, but fixed 24 fps polling is removed. New frame notifications coalesce
when decoding is busy. Its provider video display also follows decoded frames
up to 30 fps instead of a fixed 10 fps timer.

The Demo's Pre-Join uses the SDK platform bridge without joining a room.
`RealtimeRoomView` attaches an SDK source before initial camera publication.
Both SDK paths request 30 fps; achieved FPS depends on capture, processing and
vendor/network constraints. Selecting None bypasses segmentation/composition;
the stable source remains usable by the preview and provider. Platforms without
a compatible bridge retain their ordinary camera path when effects are off.
Video views default to contain the whole frame; explicit cover remains available
where supported by the renderer.

Current video-effects source and real-device verification boundaries are
summarized in the [2026-11-06 capability audit](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md).
Source and build tests do not replace end-to-end multi-provider acceptance.

## Product chat

Product chat is not inferred from the media provider or `MediaCapabilities`.
It uses `ChatSession` / `ChatCapabilities` from
`flutter_realtime_chat_core`.

| Capability | Amazon IVS Chat | Tencent Cloud Chat | Agora Chat | RTC Data fallback |
| --- | --- | --- | --- | --- |
| Send message | Yes | Yes | Yes | When media has bidirectional data |
| Receive live message | Yes | Yes | Yes | Yes |
| Delete message | Host/moderator token: client | Demo member credentials do not expose it; custom owner/admin credentials may | Demo member credentials do not expose it; custom owner/admin credentials may | No |
| Disconnect user | Host/moderator token: client | Demo uses reference control-plane REST; owner/admin credentials may declare client | Demo uses reference control-plane REST; owner/admin credentials may declare client | No |
| Member list | Demo logical directory | Demo logical directory | Demo logical directory | No management directory |
| Management execution | Client-first, backend when required | Demo: backend; owner/admin credentials may be client | Demo: backend; owner/admin credentials may be client | Unsupported |
| Automatic credential refresh | Yes | UserSig refresh | Token refresh | Follows MediaSession |
| Server history | Service capability; no Core v1 pagination API | Service capability; no Core v1 pagination API | Service capability; no Core v1 pagination API | Current-session memory only |
| Provider-independent from media | Yes | Yes | Yes | No |

The built-in UI always consumes `ChatSession` for user-facing chat. If the
backend binds a product-chat provider, that session is authoritative. If no
product Chat Provider is bound, `flutter_realtime_chat_rtc` can create a
session-local fallback only when the media session supports both RTC data send
and receive. Product-chat connection failures do not auto-fallback.

Raw RTC data remains a media transport feature and a separate Debug/control
surface. `showRtcDataMessages` does not inject raw payloads into Chat. The RTC
fallback keeps only current-session history and provides no server-side history
or moderation. Chat capability is independent from audio/video publish rights.

Privileged operations use typed `ChatManagementExecution` values:
`client`, `backend`, `hybrid`, or `unsupported`. The high-level
`RealtimeChatModeration` prefers enforceable provider-client operations and
only falls back to an optional control plane when the vendor security model
requires a server-side admin API. Applications therefore do not branch on
provider ids and never need long-lived provider secrets in the Flutter app.

## Provider-neutral APIs

### Pre-Join

`MediaClient.runPreJoinCheck()` provides a provider-neutral readiness result
before room creation/join. Core checks backend reachability, target provider
registration, permission state, device availability when available, and basic
network reachability. Adapters may add checks through `MediaPreJoinProbe`.

Pre-Join result semantics are intentionally stricter than feature discovery:

- `required` + `failed` / `unsupported` / `unknown` is blocking.
- `recommended` non-passing results are warnings.
- `skipped` produces no check.
- An adapter must never report `passed` for a diagnostic it did not actually
  perform.
- Provider-native network checks that require issued join credentials should
  return `unsupported`; Pre-Join must not create a room just for diagnosis.

Backend `GET /health` is optional diagnostics and is not required for Backend
Contract compatibility. A missing endpoint can produce a warning while the
basic HTTP path remains reachable. Transport/timeout errors are network
failures; explicit errors from an implemented health endpoint remain backend
failures.

Room discovery is available through `MediaClient.listRooms()`. It returns
`MediaRoomSummary` only; discovery never exposes user/device identity,
participant ids, or provider credentials.

Sessions can use `listMediaDevices()` / `selectMediaDevice()` when the
corresponding capability is declared. Convenience helpers
`listMicrophones()`, `listCameras()`, `listAudioOutputs()`,
`selectMicrophone()`, `selectCamera()`, and `selectAudioOutput()` keep common
application code provider-neutral. Unsupported operations fail with
`MediaErrorCode.unsupportedFeature`.

Providers that expose RTC metrics implement `MediaStatsProvider`. Consumers
read `session.connectionStats` for the latest sample or listen to
`session.stats`. Metrics are optional by design: adapters do not fabricate
values that the provider does not expose.

`session.sendData(...)` is the advanced message entry point. The legacy
`sendMessage(...)` remains compatible. `MediaSendOptions` describes topic,
target participants, reliability, and ordering; Core validates requested
semantics and message-size limits against `MediaCapabilities` before dispatch.
Incoming provider data is exposed uniformly through `session.dataMessages`;
`canReceiveData` is declared separately from `canSendData` so callers can
distinguish send-only roles from full bidirectional transports.

`MediaRoomSession.recoveries` normalizes reconnecting, recovered, and failed
transitions without changing the logical participant identity. Provider
credential refresh remains responsible for preserving provider, room, role,
and participant identity.

Host management is backend-authoritative. `MediaRoomSession.listParticipants`,
`removeParticipant`, and `closeRoom` send the current participant id to the
backend, which verifies the stored host role. A local `MediaRole.host` value
alone never grants moderation permission.

## Adding another provider

Declare only capabilities that the adapter actually implements. New provider
features should be mapped to the provider-neutral models first; provider-only
escape hatches may still be exposed by the adapter package for advanced use.
Unsupported operations must return typed errors rather than silently succeed.

For Pre-Join, implement `MediaPreJoinProbe` only when the adapter can perform a
real diagnostic without joining a room. Return explicit `unsupported` or
`unknown` checks for unavailable diagnostics and preserve the requirement
severity supplied by Core.

## Teaching tools and Live interactions

This section documents **current source coverage** without embedding obsolete October implementation snapshots.

| Domain | Implemented | Remaining limitations |
| --- | --- | --- |
| Classroom | Raise hand, teacher speaking grants, Q&A, quizzes, polls, announcements, timers, attendance and participation metrics | Server-enforced microphone permissions vary by vendor; homework submission and material upload/preview are incomplete |
| Whiteboard and shared content | Paged drawing, annotation, undo/clear, late-join snapshots, revision control and shared stage | Cross-app system capture requires the correct platform bridge, permissions, remote tracks and real-device tests |
| Live interactions | Likes, virtual gifts, recent gift banners, subscribe-only viewer roles and owner room closure | Gifts do not implement real payments; product chat is independent from RTC Data and subject to role limits |
| Cloud recording | Common start/stop/status/results APIs driven by a trusted vendor backend | Full course recording history/replay and provider-wide real-device audio/video acceptance are incomplete |

**Read:** [current provider/platform audit](SDK_CAPABILITY_AUDIT_2026-11-06.zh-CN.md), [classroom](CLASSROOM_SDK.md), [whiteboard](WHITEBOARD_SDK.md), [live](LIVE_INTERACTIONS_SDK.md), [screen share](SCREEN_SHARING_PROVIDER_STATUS.md), and [cloud recording](CLOUD_RECORDING.md).
