# flutter_realtime_media_core

Provider-neutral Flutter SDK core for realtime audio/video sessions and
one-to-many live broadcasts.

This package contains **no provider SDK dependency**. It defines the session,
event, error, capability, and rendering interfaces, plus a backend HTTP client
for the language-neutral [`MEDIA_BACKEND_CONTRACT.md`](../../doc/MEDIA_BACKEND_CONTRACT.md).
Provider support is added by adapter packages that register a
`MediaSessionFactory`:

| Provider | Adapter package | Status |
| --- | --- | --- |
| LiveKit | `flutter_realtime_media_livekit` | Implemented |
| Agora | `flutter_realtime_media_agora` | Implemented |
| AWS Chime | `flutter_realtime_media_chime` (wrapping `flutter_aws_chime`) | Implemented |

## Why a separate core

An app that only uses one provider must not be forced to resolve the SDKs of
every other provider. The core stays SDK-free, and each adapter is an optional
dependency the app opts into.

## Roles

| Role | Interface | Can publish media |
| --- | --- | --- |
| Meeting participant | `InteractiveMediaSession` | yes |
| Broadcast host | `BroadcastHostSession` | yes |
| Broadcast viewer | `BroadcastViewerSession` | **no publish methods at all** |

`BroadcastViewerSession` deliberately has no mute/camera/publish member: the
type system is the client-side half of the broadcast guarantee. The other half
is the backend, which must issue viewer credentials without publish permission.

## Usage

```dart
import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

final registry = MediaRegistry([LiveKitSessionFactory()]); // adapter package
final client = MediaClient(backendUrl: 'http://192.168.31.2:3000', registry: registry);

final room = await client.createRoomAndJoinIdentity(
  identity: const MediaIdentity(
    userId: 'stable-app-user-or-device-id',
    displayName: 'Host A',
  ),
  roomMode: MediaRoomMode.broadcast,
);

room.session.events.listen(print);
await (room.session as InteractiveMediaSession).setMuted(false);

await room.dispose();
client.dispose();
```

Common optional capabilities stay provider-neutral:

```dart
if (room.session.capabilities.canEnumerateMicrophones) {
  final microphones = await room.session.listMicrophones();
  if (microphones.isNotEmpty &&
      room.session.capabilities.canSelectMicrophone) {
    await room.session.selectMicrophone(microphones.first);
  }
}

if (room.session.capabilities.canReportNetworkStats) {
  room.session.stats.listen((stats) => print(stats.rttMs));
}

await room.session.sendData(
  'hello',
  options: const MediaSendOptions(topic: 'chat'),
);

room.recoveries.listen(print);
```

## Room cleanup diagnostics

`MediaRoomSession.leave()` coalesces repeated calls and always attempts the
best-effort backend leave notification, including when media teardown fails.
The returned future still reports the media failure. Presence failures continue
to appear on `backendErrors`.

`closeRoom()` succeeds once the authoritative room is closed. If the subsequent
local media leave fails, `cleanupErrors` emits `RealtimeException(cleanupFailed)`
with `operation: closeRoom.localLeave`, `details['roomClosed'] == true`, and an
immutable `details['cleanupFailures']` list. Subscribe before closing the room;
this broadcast stream does not replay and closes when the room is disposed.
Ordinary `leave()` and `dispose()` failures remain on their returned futures.

## Pre-Join

`MediaClient.runPreJoinCheck()` runs provider-neutral checks before a room is
created or joined:

```dart
final result = await client.runPreJoinCheck(
  role: MediaRole.participant,
  requirements: const MediaPreJoinRequirements(
    microphone: MediaPreJoinRequirement.required,
    camera: MediaPreJoinRequirement.recommended,
  ),
);

if (!result.isReady) {
  for (final issue in result.blockingIssues) {
    debugPrint(issue.message);
  }
}
```

`MediaPreJoinRequirement.required` maps to a blocking check,
`recommended` maps to a warning, and `skipped` removes the check entirely.
This severity mapping is preserved even when a provider does not implement a
native probe or a probe fails with an unknown result.

The Core runner always performs provider-neutral backend/provider checks first.
Adapters can optionally implement `MediaPreJoinProbe` for native diagnostics.
LiveKit currently uses this extension to enumerate microphone and camera
devices before joining. A provider diagnostic that needs room credentials must
return `unsupported` rather than create a room or consume normal join
credentials.

Pre-Join input meters must not interpret `microphoneEnabled` as speech. A local
preview may optionally implement `MediaLocalPreviewAudioLevels` and expose
`microphoneLevels` as normalized real capture samples (`0..1`). The SDK UI
only lights the level bars for samples received while the microphone is on;
when capture is disabled or the provider does not support metering, the bars
remain idle. The LiveKit local preview uses the already-open microphone track
for this measurement and releases the visualizer when muted or disposed.
On macOS, the SDK pre-join meter uses the native CoreAudio/AVAudioEngine input
capture stream instead of relying on RTC provider visualizers (which may not
be implemented). The stream starts only when the microphone is explicitly on,
stops on mute/navigation, and reports capture/permission errors to the UI.
It measures the macOS default input device, which can differ from a
provider-selected non-default device; this is a pre-join diagnostic, not proof
that a remote participant receives audio.
When processed-camera effects are enabled, the runtime composes that
video-only preview with the provider's local audio preview. This keeps camera
effects, microphone capture, audio input/output selection and lifetime cleanup
independent without creating a backend room.

`GET /health` is optional diagnostics rather than a required media-backend
endpoint. An HTTP 404/missing health endpoint does not make a compatible backend
unusable. Transport failures and timeouts are blocking network failures, while
an implemented health endpoint returning a real backend error such as 5xx is a
blocking backend-health failure.

The default `MediaPermissionProbe` reads current microphone/camera permission
state only; it never requests permission. See
[`PRE_JOIN_SETUP.md`](PRE_JOIN_SETUP.md) for Android/iOS host configuration.

See [`SDK_CAPABILITY_MATRIX.zh-CN.md`](../../doc/SDK_CAPABILITY_MATRIX.zh-CN.md) for the current provider
matrix and the host room-management surface.

Failures are typed:

```dart
try {
  await client.joinRoom(roomCode: '482913', nickname: 'Leo');
} on MediaError catch (error) {          // media/session layer
  debugPrint('${error.code}: ${error.message}');
} on MediaBackendError catch (error) {   // backend HTTP layer
  debugPrint('${error.code}: ${error.message}');
}
```

## Contents

- `MediaSession`, `InteractiveMediaSession`, `BroadcastHostSession`,
  `BroadcastViewerSession`
- `MediaSessionState`, `MediaSnapshot`, `MediaParticipant`, `MediaVideoTrack`,
  `MediaMessage`, `MediaCapabilities`, `MediaRole`, `MediaAudioDevice`,
  `MediaDevice`, `MediaConnectionStats`, `MediaRecoveryStatus`
- `MediaEvent` hierarchy (connection, participants, tracks, local media,
  messages, failures)
- `MediaError` / `MediaErrorCode` and `MediaBackendError` /
  `MediaBackendErrorCode`
- `MediaClient`, `MediaRoomSession`, `MediaBackendClient`,
  `MediaBackendTransport`
- room discovery, typed local-device helpers, network-stat streams, advanced
  data delivery options, reconnect/recovery reporting, and backend-authoritative
  host management
- `MediaRegistry`, `MediaSessionFactory`, `MediaJoinInfo`
- `MediaTrackRenderer`, `MediaTrackView`

## Testing

```bash
flutter test
```

Tests use fake adapters and a fake transport, so they run without a device,
network, or provider credentials.
