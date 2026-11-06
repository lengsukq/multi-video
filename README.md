# multi-video

**English** · [简体中文](README.zh-CN.md)

**multi-video** is the cross-platform demo and source repository for the provider-neutral **Flutter Realtime SDK**, supporting **meetings, live streaming, chat, classroom interaction, shared content, and optional UI**. The public SDK remains named `flutter_realtime_sdk`; this branding change does not rename SDK packages or APIs.

## Release status

| Distribution | Status | How to integrate |
| --- | --- | --- |
| [`flutter_realtime_sdk 0.1.0-dev.15`](https://pub.dev/packages/flutter_realtime_sdk/versions/0.1.0-dev.15) | **Published** preview (2026-11-03) | iOS single-package CocoaPods fixes, Agora RTC/Chat framework deduplication, and smoother two-finger whiteboard navigation |
| Monorepo source packages | Development only | Facade plus selected Provider/UI modules |

The hosted preview bundles 44 internal modules into **one pub.dev package**. This repository still has separate source modules, with different dependency instructions. Windows/Linux, some native vendor/device combinations, and third-party license verification remain release acceptance work.

## 1. Hosted SDK: quick start

Requires Flutter ≥ 3.47 and Dart ≥ 3.12. The combined native package requires Android API 28+, iOS 15+, and macOS 12+.

~~~yaml
dependencies:
  flutter_realtime_sdk: ^0.1.0-dev.15
~~~

~~~dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

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
// Bind room.states / room.events to your own UI.
// On explicit leave: await connection.dispose();
~~~

Register providers explicitly. Use a **trusted backend** for short-lived credentials, never vendor secrets in the Flutter app. The [Demo Server](demo-server/README.md) is optional; `RealtimeSource.credentials(...)` accepts your own provisioning. For presentation choose `RealtimeRoomView`, composable widgets, or a completely custom **Headless** UI. Classroom and Live presets are opt-in and require authoritative backend permissions. Demo gifts contain no payment logic.

### iOS host setup and whiteboard navigation (dev.15)

The aggregated iOS SDK is still CocoaPods-based. Disable Flutter SwiftPM
**in this host app only** until all aggregated native providers support it:

~~~yaml
flutter:
  config:
    enable-swift-package-manager: false
~~~

In the host `ios/Podfile` add the following hook before `post_install`
(merge with an existing `pre_install` if needed):

~~~ruby
pre_install do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)
end
~~~

This keeps the newer of the Agora RTC/Chat `aosl` frameworks without
deleting vendor binaries; the dev.15 Podspec excludes private C++ headers
from the Swift umbrella. On phones, the shared whiteboard supports stable
two-finger zoom/pan and rebases safely when fingers are added or lifted.
See the [host integration guide](doc/APP_INTEGRATION_QUICKSTART.zh-CN.md).

### Virtual-background update for Headless apps

Published **`0.1.0-dev.15`** retains `room.setCameraEnabled(bool)` and the `DefaultRealtimeVideoEffects` export, with meeting-mode selection, composed previews, repository-backed shared content, refreshed Meeting/Live/Chat/classroom/whiteboard UI, bundled design fonts, and a native macOS pre-join microphone meter. The meter reads the system default input and does not prove remote audio delivery:

~~~dart
// Available in the published dev.15 preview.
final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  services: const RealtimeRoomServices(
    videoEffectsFactory: DefaultRealtimeVideoEffects.new,
  ),
);
// On a connected room, check backgroundCapabilities first:
await room.setBackgroundEffect(const MediaBackgroundEffect.blur());
await room.setCameraEnabled(true); // not media.session.setVideoEnabled(true)
~~~

See [Headless integration](doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) and the exact installed version's README.

## 2. Source development (separate modules)

For SDK contributors editing this checkout, use **path dependencies**, not the combined hosted package:

~~~yaml
dependencies:
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
  # Optional UI:
  flutter_realtime_sdk_ui:
    path: ../multi-video/packages/flutter_realtime_sdk_ui
~~~

The source facade exports only Runtime. Register the selected provider and optional UI/presets explicitly; **do not mix this with the one-package installation above**.

| Internal area | Role |
| --- | --- |
| `flutter_realtime_sdk` / Runtime | Provider-neutral rooms, lifecycle, controls |
| Media/Chat Core + provider bundles | RTC/IM, capabilities, vendor adapters |
| `flutter_realtime_video_effects` | Camera-processing and background effects |
| `flutter_realtime_sdk_ui` | Reusable controls and optional room UI |
| Classroom/Live/shared-content presets | Teaching and live interactions |
| `example/` + `demo-server/` | Reference app/backend, not additional SDKs |

[Module index](doc/ARCHITECTURE.md) · [Single-package architecture](doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) · [Role semantics](doc/REALTIME_DESIGN_SYSTEM.md)

## 3. Run the Demo

The backend needs Node.js ≥ 22.18. Configure the vendor credentials **server-side**. Its address must be reachable from the app (Android emulator uses `10.0.2.2`, physical devices need LAN/HTTPS).

~~~bash
cd demo-server && npm install && npm start
# Separate terminal:
cd example && flutter pub get && flutter run -d macos
~~~

The Demo directly displays the SDK’s built-in Meeting/Live/Chat/Pre-Join pages. To build an Apple Silicon **Demo** DMG from the repository root, run `./build_macos_arm64.command`. This produces an app installer, **not** a pub.dev SDK package.

## 4. Capabilities and security

- [Provider/platform matrix](doc/SDK_CAPABILITY_MATRIX.zh-CN.md) · [中文](doc/SDK_CAPABILITY_MATRIX.zh-CN.md). Implemented does not mean tested on every real device.
- [Cloud recording](doc/CLOUD_RECORDING.md) is controlled by trusted backend and vendor cloud storage/recording, not local media encoding.
- The combined hosted SDK resolves bundled native vendor dependencies even when only one provider is registered at runtime.
- Browsers need HTTPS/localhost for camera and microphone; native hosts must declare their permission usage descriptions.
- iOS combined-package consumers need the IVS/Agora Podfile setup described in the [release README](scripts/templates/single_sdk_README.md). Some simulator builds, Windows/Linux, and live vendor scenarios remain unverified.
- Treat unit tests, builds, and vendor/device acceptance separately: [acceptance notes](doc/ACCEPTANCE.md).

## 5. Validation and related docs

**[Documentation index (integration, capabilities, features, release, archive)](doc/README.md)**.

~~~bash
python3 scripts/check_sdk_quality.py --resolve --analyze --test
python3 scripts/check_sdk_architecture.py
python3 scripts/format_sdk.py --check
python3 scripts/generate_capability_matrix.py --check
~~~

[First-time integration (中文)](doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) · [SDK Runtime/Headless (中文)](doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) · [UI composition](doc/REALTIME_DESIGN_SYSTEM.md) · [pub.dev release guide](doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) · [Example](example/README.md) · [Development](doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md)

**Full Chinese overview:** [README.zh-CN.md](README.zh-CN.md).
