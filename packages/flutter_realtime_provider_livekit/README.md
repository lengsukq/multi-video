# flutter_realtime_provider_livekit

Optional LiveKit media Provider for [Flutter Realtime SDK](https://github.com/lengsukq/multi-video). The package bundles platform-selected adapters and the pinned local Web runtime; Flutter applications do not need to inject a LiveKit script URL or maintain a CDN reference.

> **Not published to pub.dev yet.** This package uses `publish_to: none` and monorepo path dependencies; see the [release guide](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md).

## Installation in the development monorepo

Add the lightweight facade and this package to your host app:

```yaml
dependencies:
  flutter_realtime_sdk:
    path: ../multi-video/packages/flutter_realtime_sdk
  flutter_realtime_provider_livekit:
    path: ../multi-video/packages/flutter_realtime_provider_livekit
```

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
    user: const RealtimeUser(id: 'alice', name: 'Alice'),
  ),
);
// Keep connection alive during the room, then await connection.dispose().
```

`createLivekitProvider({maxMessages: 500})` accepts a positive local chat-history limit. Do not pass a long-lived LiveKit API Secret from the client. The backend generates short-lived room tokens and owns any cloud recording jobs, storage and download endpoints.

Meeting vs broadcast publishing permissions, screen sharing, network statistics and Web/mobile capabilities differ by platform. Check the [capability matrix](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md) and [integration guide](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) rather than assuming all UI actions are supported.

The Demo at [example/](https://github.com/lengsukq/multi-video/tree/main/example) registers this bundle explicitly; it is not a transitive dependency of `flutter_realtime_sdk`.
