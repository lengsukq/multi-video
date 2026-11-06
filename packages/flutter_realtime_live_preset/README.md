# flutter_realtime_live_preset

Optional, **headless** live-room interaction plugin for Flutter Realtime SDK. It supplies state and commands for likes, demo gifts, gift-event history and audience notifications; it does **not** implement payment processing, virtual-currency accounting or real-money transactions.

> **Unpublished monorepo package.** Uses `publish_to: none` and local dependencies until the [release process](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) is completed.

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  featurePlugins: const [LivePreset()],
);
final connection = await realtime.open(RealtimeRequest.join(
  type: RealtimeExperience.live,
  roomCode: '123456',
  user: const RealtimeUser(id: 'alice', name: 'Alice'),
));
final live = connection.mediaRoom?.liveInteractions;
if (live != null) await live.sendLike();
// Retain connection while in the room; dispose on explicit leave.
```

`LivePreset()` attaches only if authoritative backend metadata advertises `liveInteractions` and usable credentials exist. A custom backend can provide `repositoryFactory`; `enableForDirectRooms` is an explicit opt-in for such custom repositories. The room extension `liveInteractions` comes from this optional package.

Live event revision messages are delivery hints; authoritative state comes from the backend. Consumers should subscribe to `LiveInteractionSession.events` and refresh snapshots so both host and viewers can see gifts. A demonstration server applies a rate limit to prevent uncontrolled bursts; those limits are *not* payment or spending quotas.

Optional visuals such as `RealtimeLiveGiftBanner` live in `flutter_realtime_sdk_ui`; adding this preset alone never adds a full-page live UI. See [interaction architecture](https://github.com/lengsukq/multi-video/blob/main/doc/ARCHITECTURE.md) and [acceptance](https://github.com/lengsukq/multi-video/blob/main/doc/ACCEPTANCE.md).
