# flutter_realtime_sdk_runtime

Provider-neutral room, event and SDK orchestration contracts for Flutter. This is the runtime under `flutter_realtime_sdk`; use it directly only when you need advanced provider composition or internal session integration.

> **Not yet published.** This package currently uses `publish_to: none` and local path dependencies. Read the [release guide](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) before attempting a hosted release.

## What it owns

- `Realtime`, `RealtimeSdk`, `RealtimeRequest`, `RealtimeConnection` and `RealtimeRoom`.
- Provider registration via `RealtimeProviderBundle` / `RealtimeProviderDriver`, with platform-aware resolution.
- Media/Chat domain session composition, typed errors, capability checks, room lifecycle, member operations and cleanup.
- Generic feature plugin registration, interaction revision transports, room state streams and cloud recording **client contracts**.

The runtime **does not** bundle a default vendor catalog, sample server, UI theme, ready-made room screen or long-lived credentials. Calling `Realtime.standard()` without explicitly supplied drivers is **not** equivalent to having all providers installed.

## Basic use

```dart
import 'package:flutter_realtime_sdk_runtime/flutter_realtime_sdk_runtime.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
);

final connection = await realtime.open(
  RealtimeRequest.create(
    type: RealtimeExperience.meeting,
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);
final stream = connection.states.listen((value) {
  // Observe media/chat connection state.
});
// Retain connection and stream while participating.
// On explicit leave only:
// await stream.cancel();
// await connection.dispose();
```

The facade `flutter_realtime_sdk` exports this runtime; most apps should depend on the facade instead. For UI, add `flutter_realtime_sdk_ui` explicitly. For Classroom / Live actions, add and register their preset packages explicitly using `featurePlugins`.

## Trust and ownership

The trusted backend decides the provider and signs short-lived join credentials. SDK clients do not store vendor Customer Secrets / App Certificates. User-controlled calls must check provider capabilities and backend authorization; do not treat client UI role flags as permission grants.

`RealtimeConnection.dispose()` is called once on **explicit room leave**; rebuilding or unmounting a widget must not stop a live room. Async cleanup may report multiple failures, and the host should surface those failures instead of silently assuming the cloud recorder stopped.

See [integration guide](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md), [architecture](https://github.com/lengsukq/multi-video/blob/main/doc/ARCHITECTURE.md), and [capability matrix](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md).
