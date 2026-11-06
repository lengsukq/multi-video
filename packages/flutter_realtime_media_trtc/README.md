# flutter_realtime_media_trtc

Optional Tencent TRTC adapter for [`flutter_realtime_media_core`](../flutter_realtime_media_core).
The package contains all Tencent SDK imports, credential parsing, session
mapping, and video rendering. Core has no Tencent dependency and chooses no
default provider. Add this package only when an application needs TRTC.

## Add and register the adapter

```yaml
dependencies:
  flutter_realtime_media_core:
    path: ../flutter_realtime_media_core
  flutter_realtime_media_trtc:
    path: ../flutter_realtime_media_trtc
```

```dart
final client = MediaClient(
  backendUrl: backendUrl,
  registry: MediaRegistry([
    const TrtcSessionFactory(),
    // Register other optional adapters used by this app here.
  ]),
);

final room = await client.joinRoom(
  roomCode: roomCode,
  nickname: displayName,
  role: MediaRole.viewer,
);
```

The application does not select a provider in `joinRoom`. Its backend returns
the provider and TRTC credentials, and Core resolves the matching registered
adapter. An app that does not register TRTC can continue using its existing
providers without loading the Tencent package.

## Join payload

The backend returns the common room fields plus a `trtc` block:

```json
{
  "contractVersion": 1,
  "provider": "trtc",
  "role": "viewer",
  "roomCode": "482913",
  "participantId": "u-person1",
  "displayName": "Person 1",
  "trtc": {
    "sdkAppId": 1400000000,
    "strRoomId": "media-482913",
    "userId": "u-person1",
    "userSig": "short-lived-user-sig",
    "privateMapKey": "room-scoped-private-map-key",
    "expiresAtMs": 1790000000000
  }
}
```

`participantId` must equal TRTC `userId`. Keep the SDK secret and all signing
operations on the backend. See the root
[`MEDIA_BACKEND_CONTRACT.md`](../../doc/MEDIA_BACKEND_CONTRACT.md) for refresh
request and response details.

## Roles and features

| Core role | TRTC scene | Capabilities |
| --- | --- | --- |
| `participant` | `videoCall` | Publish/subscribe audio and video; send custom messages |
| `host` | `live` | Publish/subscribe audio and video; send custom messages |
| `viewer` | `live` | Subscribe only; no custom message sending |

The reference backend fixes a room's scene when it is created and rejects a
join request that would use the other scene. Viewer sessions implement
`BroadcastViewerSession`, not `InteractiveMediaSession`; their PrivateMapKey
also omits media-publish permissions. The adapter does not support screen share
or audio-device enumeration.

Render local or remote camera tracks through the Core renderer contract:

```dart
MediaTrackView(
  renderer: const TrtcTrackRenderer(),
  track: participant.videoTrack,
)
```

## Credential renewal

If an application backend implements the optional Core route
`POST /rooms/{roomCode}/credentials/refresh`, `MediaClient` connects it to the
TRTC session. The adapter renews before `expiresAtMs`, validates that provider,
room, user, participant, role, and TRTC room identity stay fixed, and re-enters
using the new short-lived credentials. Without the optional route the session
continues to work until the issued credentials expire.

## Reference backend and device checks

The repository's `demo-server` accepts `TRTC_SDK_APP_ID`,
`TRTC_SDK_SECRET_KEY`, and optional `TRTC_TOKEN_TTL_SECONDS` (default 600).
Enable Tencent Advanced Permission Control for server-issued PrivateMapKey
rights to be enforced. Follow [`../../doc/ACCEPTANCE.md`](../../doc/ACCEPTANCE.md) to verify
host/viewer behavior and renewal on physical devices.
