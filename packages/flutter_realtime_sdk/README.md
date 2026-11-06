# flutter_realtime_sdk

**English** · [简体中文](README.zh-CN.md)

Provider-neutral Flutter SDK for meetings, live streams and standalone chat.
**This is the ONLY publicly published SDK package name.**
Its development facade is currently lightweight (runtime only); the generated
distribution includes provider factories, optional UI and presets behind
this **same public import**. Only runtime registration and widget composition
remain optional; all shipped vendor SDK dependencies may still enter the app.

[Single-package release architecture and current blockers](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md).

The hosted single-package preview `0.1.0-dev.15` is currently published on
[pub.dev](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.15).
It retains meeting and classroom modes, whiteboard sharing, composable UI,
and provider-neutral runtime controls; dev.15 additionally fixes CocoaPods
integration for the aggregated iOS plugin and mobile two-finger whiteboard
zoom/pan. iOS hosts need the package's `pre_install` helper and a
project-level SwiftPM opt-out (see the published README). Earlier releases are
superseded; this source module remains
unpublished and has `publish_to: none`.
Unlike the hosted package, this
development module has `publish_to: none` and is not published independently.

**First integration into your own app:** follow the
[Chinese end-to-end quickstart](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md)
before choosing individual features. The guide covers local path dependencies,
backend/token setup, creator vs guest roles, Headless/UI, and platform checks.

> **Status:** this directory is an internal development module with
> `publish_to: none` and local dependencies. Use the **hosted package's
> README** for single-package installation, native setup, and its exact
> version-specific APIs.

## Requirements and installation

- Flutter ≥ **3.47**, Dart ≥ **3.12**; supported platforms depend on your chosen Provider and host configuration.
- Add this facade and **only** the Provider bundles you intend to use to the host `pubspec.yaml`.
- **Currently in this source checkout only**, reference facade and selected
  providers as separate path dependencies. This is **not the final pub.dev UX**:

```yaml
dependencies:
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
```

These paths assume the host Flutter project and the SDK checkout are sibling folders. Replace them with the real relative paths in your workspace. For the published preview, use `flutter pub add flutter_realtime_sdk:0.1.0-dev.15` instead and follow the published package's README.

**Language and distribution:** [English source README](README.md) ·
[中文源码 README](README.zh-CN.md) ·
[English hosted release template](../../scripts/templates/single_sdk_README.md) ·
[中文单包发行模板](../../scripts/templates/single_sdk_README.zh-CN.md).

## Create, join and dispose

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
);

final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: '123456',
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);

final room = connection.mediaRoom!;
final subscription = room.states.listen((state) {
  // Update application-owned state / custom UI here.
});
// Keep BOTH connection and subscription alive while the user participates.
// In the host application's explicit leave/logout handler, run:
// await subscription.cancel();
// await connection.dispose();
```

- Use `RealtimeRequest.create(type: ..., user: ...)` for a new room.
- Use `RealtimeExperience.live` for a broadcast or `RealtimeExperience.chat` for standalone product chat. Chat connections use `connection.chatRoom`; meeting/live use `connection.mediaRoom`.
- For a host-owned credential service use `RealtimeSource.credentials(...)` rather than exposing long-lived vendor secrets. The provided Demo Server is a reference, **not required** if you implement compatible provisioning.
- `Realtime.preJoin(...)` and `createLocalPreview(...)` are available without mandatory SDK UI. Handle permissions and release local previews separately.

## Optional feature and UI packages

```dart
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  featurePlugins: const [ClassroomPreset(), LivePreset()],
);
```

These presets require a trusted authoritative backend (or explicitly provided repositories). Classroom hands, Q&A and Live gift/like events are *not* automatically enabled by importing the facade. Gifts are a demonstration of non-payment interactions.
For whiteboard and shared-content modes, also register
`SharedContentPreset()` (and its source module when using local path dependencies).
When both it and `ClassroomPreset()` are registered, order is irrelevant.
Classroom endpoints must still be implemented on your trusted backend.

In the **development monorepo**, optional ready-to-use widgets still require
`flutter_realtime_sdk_ui` as a separate path dependency. In the **published
single-package preview**, `RealtimeRoomView(room: connection.mediaRoom!)`
comes from this one public SDK import; a Headless app simply does not mount
those widgets. Because the package may contain their dependencies, UI is
runtime-optional, not necessarily dependency-tree optional.

## Provider registration

| Provider bundle | Factory |
| --- | --- |
| `flutter_realtime_provider_livekit` | `createLivekitProvider()` |
| `flutter_realtime_provider_agora` | `createAgoraProvider()` |
| `flutter_realtime_provider_trtc` | `createTrtcProvider()` |
| `flutter_realtime_provider_artc` | `createArtcProvider()` |
| `flutter_realtime_provider_aws` | `createAwsProvider()` |
| `flutter_realtime_provider_agora_chat` | `createAgoraChatProvider()` |
| `flutter_realtime_provider_ivs_chat` | `createIvsChatProvider()` |
| `flutter_realtime_provider_tencent_chat` | `createTencentChatProvider()` |

Backend-issued provider identifiers must resolve to a bundle registered by the host. AWS routes Meeting to Chime and Live to IVS. Check `MediaCapabilities`, `ChatCapabilities` and the platform matrix at runtime; do not infer features solely from the provider name.

## Security, recording and support

- App ID may be public where the vendor allows it; **App Certificate, Customer Secret, cloud access keys and user signing keys belong server-side only**.
- Cloud recording starts/stops in the trusted backend, not in this package; storage, MP4 conversion and billable recording lifecycle depend on the actual vendor. See [cloud recording](https://github.com/lengsukq/multi-video/blob/main/doc/CLOUD_RECORDING.md).
- Web media requires HTTPS or localhost for permissions; configure native camera/microphone permissions in the host app.
- [SDK integration (Chinese)](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) · [Platform capability matrix](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md) · [Full Demo](https://github.com/lengsukq/multi-video/tree/main/example).

Platform support in the capability matrix describes implemented drivers, **not an assurance of end-to-end real-device testing for every provider/platform combination**.
