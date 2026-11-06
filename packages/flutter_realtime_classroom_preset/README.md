# flutter_realtime_classroom_preset

Optional, **headless** classroom feature plugin for Flutter Realtime SDK: hand raising, permission requests, Q&A, classroom notifications, homework, polls and authoritative session snapshots. The host may use its own UI; the package does not provide a mandatory page layout.

> **Unpublished monorepo package.** Uses `publish_to: none` and local dependencies until the [release process](https://github.com/lengsukq/multi-video/blob/main/doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md) is completed.

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';
import 'package:flutter_realtime_provider_livekit/flutter_realtime_provider_livekit.dart';
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  featurePlugins: const [ClassroomPreset()],
);
final connection = await realtime.open(RealtimeRequest.join(
  type: RealtimeExperience.meeting,
  roomCode: '123456',
  user: const RealtimeUser(id: 'alice', name: 'Alice'),
));
final classroom = connection.mediaRoom?.classroom;
if (classroom != null) await classroom.raiseHand();
// Retain connection while in the room; dispose on explicit leave.
```

The typed `classroom` room extension is provided by **this package**, not by the base SDK. A preset becomes available only if the room's backend metadata announces meeting mode and appropriate credentials/repository exist.

The classroom service is **server authoritative**: revision messages (RTC Data / Chat system hints) only request a refresh. Events can be coalesced within a poll; they are not an immutable replay log. `ClassroomPreset(repositoryFactory: ...)` allows a host-owned trusted implementation. Never decide teacher powers from display-only Flutter state.

For visuals import `flutter_realtime_sdk_ui` separately, or build your own UI using `ClassroomSession`. See [Classroom SDK](https://github.com/lengsukq/multi-video/blob/main/doc/CLASSROOM_SDK.md), [headless/preset guide](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md) and [acceptance](https://github.com/lengsukq/multi-video/blob/main/doc/ACCEPTANCE.md).
