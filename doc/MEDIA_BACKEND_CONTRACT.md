# Media Backend Contract v1

This document defines the provider-neutral HTTP contract used by
`MediaClient` / `MediaBackendClient` in
[`flutter_realtime_media_core`](../packages/flutter_realtime_media_core).
It is language-neutral: a backend may be implemented in Node.js, Java, Python,
Go, .NET, or any other stack.

It is a **superset of [`MEDIA_BACKEND_CONTRACT.md`](MEDIA_BACKEND_CONTRACT.md)** (the Chime
contract v1): the same room endpoints, while provider choice is owned by the
backend. Chime-only backends keep working unchanged — see
[Chime compatibility](#chime-compatibility).

The Flutter side never receives provider API keys or secrets. Creating rooms,
signing provider tokens, and holding long-lived credentials are backend
responsibilities.

## Versioning

The current contract version is `1`.

The SDK sends this request header on contract calls:

```http
X-Media-Backend-Contract: 1
```

Compatible servers should return the same header and may include:

```json
{ "contractVersion": 1 }
```

If a supplied version is unsupported, return HTTP `400` with the standard error
body below.

## Authentication

Authentication belongs to the application. When configured with a
`tokenProvider`, the SDK sends:

```http
Authorization: Bearer <application-token>
```

This is an application token, never a provider credential. Backends with a
different scheme can use `headersProvider` instead.

## Backend provider selection

| Field | Where | Meaning |
| --- | --- | --- |
| `roomMode` | create request | `meeting` or `broadcast`. New clients should send this instead of choosing a role. |
| `role` | request body | Legacy compatibility override. Modern clients omit it and let the backend assign the role from room policy. |
| `provider` | response body | Public provider/vendor selected by the backend. AWS rooms use `aws`. Optional only for legacy Chime responses; when absent the SDK assumes `chime`. |
| `engine` | response body | Optional concrete adapter engine. AWS uses `chime` for `meeting` and `ivs` for `broadcast`. Clients that understand this field resolve the engine adapter while presenting the public vendor. |
| `chatProvider` | response body | Optional product-chat provider bound to the room. It is independent from the media `provider`. |
| `role` | response body | The role granted by the backend: `participant`, `host`, or `viewer`. |

Flutter never requests `livekit`, `aws`, or another provider. The backend may
choose based on deployment configuration, tenant, room policy, requested role,
capacity, cost, region, feature flags, or another server-side rule. Existing
room codes must keep resolving to the provider that owns that room.

The reference backend treats AWS as a vendor-level provider. `roomMode=meeting`
routes to the Chime engine and `roomMode=broadcast` routes to the IVS Real-Time
engine. Responses expose `provider: "aws"` plus `engine: "chime" | "ivs"`.
Legacy `chime` / `ivs` selections remain accepted as compatibility aliases.

If the server-selected provider is not configured, return
`provider-not-configured` (HTTP `503`).

`chatProvider` is authoritative when present. When it is absent, clients may
optionally expose a local RTC Chat fallback if the selected media adapter
declares both `canSendData` and `canReceiveData`. This fallback is not a backend
provider binding and does not change this contract or grant additional media
permissions.

## Endpoints

### `POST /rooms`

Create a room and an attendee/participant for the caller.

```json
{
  "userId": "account-123",
  "displayName": "Host A",
  "roomCode": "482913",
  "roomMode": "broadcast",
  "deviceId": "b8ae2e3f-3e30-4f66-8f69-fd63cc0cc8a5"
}
```

`roomCode` is optional (the server may generate one). Success returns a
[join response](#join-response). Recommended errors: `bad-room-code` (`400`),
`room-exists` (`409`).

`userId` is the stable logical application identity and `displayName` is
mutable presentation text. For backward compatibility, v1 servers may continue
to accept `nickname` when the newer pair is absent.

`deviceId` is optional and opaque. Demo applications may persist a random
install-scoped id and send it on create/join so the backend can treat repeated
joins from the same app installation as one logical device presence. It is not
a hardware identifier and must not contain provider credentials. Neither
`userId` nor `deviceId` is authorization proof: both are client-declared
values and must never grant `host` or moderation privileges by themselves.

The reference backend assigns roles from `roomMode`:

- `meeting`: creator and joiners are `participant`;
- `broadcast`: creator is `host`; other devices are `viewer`;
- broadcast creation returns a random `roomOwnerCredential`; a later join is
  restored to `host` only when it presents that server-issued proof.

Clients must not be able to self-promote by sending `role: "host"` on join.
Copying the creator's `userId`, display name, or `deviceId` must still
produce a `viewer`.

### `POST /rooms/{roomCode}/join`

Create an attendee/participant in an existing room.

```json
{
  "userId": "account-456",
  "displayName": "Guest",
  "deviceId": "b8ae2e3f-3e30-4f66-8f69-fd63cc0cc8a5"
}
```

Missing room returns `room-not-found` (`404`).

For rooms created with `roomMode`, the backend ignores any valid client role
hint on join and returns the role granted by the room policy. This prevents a
viewer from changing a request field to become a host.

The broadcast owner may additionally send:

```json
{
  "roomOwnerCredential": "<opaque-owner-proof>"
}
```

The reference backend generates 32 random bytes when the broadcast room is
created, stores only a SHA-256 digest in `RoomEntry`, and returns the opaque
proof only to the creator. `MediaRoomSession.roomOwnerCredential` exposes it
to the creating client so an application can keep it in secure session
storage. It is intentionally excluded from room discovery, participant lists,
and dashboard summaries.

### Discover rooms

`GET /rooms/discover` returns lightweight room metadata for join UIs:

```json
{
  "contractVersion": 1,
  "rooms": [
    {
      "provider": "livekit",
      "roomCode": "482913",
      "roomMode": "meeting",
      "createdAt": "2026-09-24T10:00:00.000Z",
      "attendeeCount": 2
    }
  ]
}
```

Discovery intentionally excludes attendee identities and provider credentials.
It follows the same application-token protection as the other room endpoints.
Clients can refresh this list and pass the selected `roomCode` to the normal
join endpoint.

The reference demo backend keeps only the latest participant record for a
stable `userId` in a room and also collapses repeated joins from the same
`deviceId` when supplied. `participantId` remains the provider/session
identity and may change on reconnect; `displayName` may change without
creating a second logical user.

### Host room management (optional)

The reference backend exposes a provider-neutral management surface for rooms
whose assigned role model includes a `host`. Unsupported operations return
`unsupported-feature` rather than pretending a local state change affected the
provider session.

#### `POST /rooms/{roomCode}/participants`

Lists sanitized logical participants:

```json
{
  "requesterParticipantId": "host-1",
  "participantCredential": "<opaque-session-proof>"
}
```

```json
{
  "contractVersion": 1,
  "roomCode": "482913",
  "participants": [
    {
      "participantId": "viewer-1",
      "displayName": "Viewer",
      "role": "viewer",
      "joinedAt": "2026-09-24T10:00:00.000Z"
    }
  ]
}
```

Do not return stable application user ids, device ids, provider credentials, or
join tokens from this endpoint.

#### `POST /rooms/{roomCode}/participants/remove`

Requests server-enforced removal of a current participant:

```json
{
  "requesterParticipantId": "host-1",
  "participantCredential": "<opaque-session-proof>",
  "targetParticipantId": "viewer-1"
}
```

The reference backend currently implements native participant removal for
LiveKit. A provider without a server-side removal primitive returns
`unsupported-feature`.

#### `POST /rooms/{roomCode}/close`

Host-authorized room closure:

```json
{
  "requesterParticipantId": "host-1",
  "participantCredential": "<opaque-session-proof>"
}
```

This differs from a normal participant `leave`: it prevents future joins and
invokes the provider room-close behavior where applicable.

For LiveKit, the reference backend calls RoomService `DeleteRoom`, which
forcibly disconnects current participants instead of only deleting the local
room-directory entry.

The reference backend checks both `requesterParticipantId` and the opaque
`participantCredential` issued to that exact participant at join time before
granting host management operations. The credential is random session proof,
not a provider token or stable device id; the reference server stores only its
SHA-256 digest. Production implementations should additionally bind requests to
the authenticated application identity/session (for example the Bearer
credential).

### `POST /rooms/{roomCode}/credentials/refresh` (optional)

Refresh short-lived credentials for an already admitted participant. Adapters
that support renewal call this endpoint; existing adapters and compatible
backends that do not use expiring credentials are unaffected.

```json
{
  "participantId": "u-123",
  "participantCredential": "<opaque-session-proof>",
  "role": "host"
}
```

Success returns the standard [join response](#join-response). The backend must
keep `provider`, `roomCode`, `participantId`, and `role` identical to the
original session, and must authorize the caller as that exact participant.
`role` in the request is compatibility information only: the backend must
derive the effective role from its stored room participant and must never use a
caller-supplied role to increase privileges. A refresh response that changes
any of those fields is rejected by Core. Return `forbidden` (`403`) when the
participant proof is missing/invalid or a requested role does not match the
stored role.

### `POST /rooms/{roomCode}/heartbeat`

Best-effort presence signal, called once after joining and then every
heartbeat interval. Current clients include the logical participant id so the
backend can maintain participant-level presence:

```json
{ "participantId": "host-a" }
```

For backwards compatibility, servers may still accept an empty body as a
room-level heartbeat. A backend that tracks participant presence should return
`participant-not-found` (`404`) when a supplied participant id is no longer
registered in the room. Example success:

```json
{ "contractVersion": 1, "ok": true, "roomCode": "482913" }
```

Heartbeat failures surface on `MediaRoomSession.backendErrors` and never
terminate healthy media.

### `GET /health` (optional diagnostic)

`GET /health` is **not required** to implement the room/join contract. It is a
diagnostic endpoint used by `MediaDoctor`, Pre-Join, and the reference demo UI.
A Java, Python, Node.js, Go, or other backend that implements the normal room
endpoints remains compatible even when `/health` is absent.

Recommended success shape:

```json
{
  "contractVersion": 1,
  "activeProvider": "livekit"
}
```

Semantics used by Core:

- HTTP 200 with a valid response: backend reachable and health check passed.
- HTTP 404 / diagnostic not implemented: backend path is reachable, but health
  diagnostics are unavailable. Pre-Join treats this as non-blocking.
- Connection error, DNS failure, or timeout: backend is not reachable; Pre-Join
  treats the network check as blocking.
- An implemented endpoint that returns an explicit backend failure such as
  401/403/5xx remains a backend-health failure and can block Pre-Join. The HTTP
  response still proves that the network path itself is reachable.

Do not make create/join behavior depend on the client first calling
`GET /health`. It must remain safe for clients and compatible backends to skip
this diagnostic entirely.

### `POST /rooms/{roomCode}/leave`

Best-effort leave notification.

```json
{ "participantId": "host-a" }
```

Servers should accept `attendeeId` as an alias so Chime-era implementations and
the generic client can share one endpoint. Implementations must make this
endpoint safe to call more than once.

### `DELETE /rooms/{roomCode}`

Optional administrative operation exposed by `MediaBackendClient.closeRoom`.
Applications are not required to expose it to ordinary clients. For providers
that bill by attendance there is nothing to release; for providers that bill by
provisioned room (for example AWS Chime) this is the "stop future joins" call.

If any provider-side cleanup fails, the reference backend does **not** remove
the local room-directory entry. It marks the room cleanup-pending, excludes it
from public discovery, rejects new join/token/refresh requests, and keeps enough
state to retry only the resources that have not already been deleted. The room
record is removed only after all required Media and Chat cleanup succeeds.

## Join response

Common fields:

```json
{
  "contractVersion": 1,
  "provider": "livekit",
  "role": "host",
  "roomCode": "482913",
  "participantId": "host-a",
  "participantCredential": "<opaque-session-proof>",
  "requiredCapabilities": ["publish-audio", "publish-video", "chat"]
}
```

`roomCode` is required (the SDK falls back to the requested code on join calls),
`participantId` is required by adapters. The reference backend also returns a
random `participantCredential` after an actual create+join or join. Core keeps
that proof on `MediaRoomSession` and automatically returns it for credential
refresh and host-management requests. Rejoining rotates the proof. It must not
be logged, exposed through room discovery/participant lists, or used as a
stable application identity. Additional fields are allowed and ignored.

`requiredCapabilities` is optional and provider-neutral. When present, the
high-level SDK verifies the requirements after resolving the actual media and
Product Chat/RTC Chat sessions. Supported v1 names are:
`publish-audio`, `publish-video`, `subscribe-video`, `screen-share`,
`chat`, `list-participants`, `remove-participants`, and `close-room`.
Unknown requirements or requirements the resolved client cannot satisfy fail
explicitly as unsupported features; they never trigger a provider switch or a
silent capability downgrade. Omitting the field preserves existing v1
behavior.

### LiveKit provider block

```json
{
  "contractVersion": 1,
  "provider": "livekit",
  "role": "host",
  "roomCode": "482913",
  "participantId": "host-a",
  "livekit": {
    "url": "ws://192.168.31.8:7880",
    "token": "<short-lived-access-token>",
    "identity": "host-a"
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `livekit.url` | yes | Signaling URL: `ws://<lan-ip>:7880` for a local dev server, `wss://<project>.livekit.cloud` for LiveKit Cloud. |
| `livekit.token` | yes | Short-lived JWT access token minted by the backend. |
| `livekit.identity` | no | Participant identity; must match `participantId` when supplied. |

Token requirements:

- `roomJoin: true` and `room` scoped to the provider room mapped from the
  application room code (so a leaked token cannot join another room);
- `canPublish: true` for `host`/`participant`, **`canPublish: false` for
  `viewer`**;
- `canSubscribe: true` for every role;
- `canPublishData` for chat: `true` for host/participant, configurable for
  viewers;
- `ttl` short (minutes), not the SDK default of six hours.

### Agora provider block

```json
{
  "contractVersion": 1,
  "provider": "agora",
  "role": "host",
  "roomCode": "482913",
  "participantId": "123456789",
  "displayName": "Host A",
  "agora": {
    "appId": "<agora-app-id>",
    "channelName": "media-482913",
    "token": "<short-lived-access-token-2>",
    "uid": 123456789
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `agora.appId` | yes | Public Agora App ID. The App Certificate is **never** returned to Flutter. |
| `agora.channelName` | yes | Provider channel mapped from the application room code. |
| `agora.token` | yes | Short-lived Agora AccessToken2 minted by the backend. |
| `agora.uid` | yes | Positive signed 32-bit Agora UID (`1..2147483647`). Its decimal string must equal `participantId`. |

The reference backend grants join/audio/video/data privileges to `participant`
and `host`. A `viewer` receives join permission but no publish-audio,
publish-video, or publish-data privilege, and the Flutter adapter joins as an
Agora audience client with all local publishing disabled.

Agora's fine-grained publish privileges are enforced by the service only when
the Agora project has the corresponding **co-host authentication** capability
enabled. Without it, the SDK still enforces the viewer role locally, but the
backend must not claim that a modified client is server-side prevented from
publishing. Production integrations that depend on this security boundary must
enable the Agora feature and verify it with a real-project E2E test.

The current Agora adapter intentionally reports `canSendData=false` for
`viewer`. Agora RTC data streams in live-broadcast mode are host-oriented;
viewer chat would require a separate safe messaging design (for example RTM)
before it can match the Core viewer contract without weakening publish roles.

### Tencent TRTC provider block

```json
{
  "contractVersion": 1,
  "provider": "trtc",
  "role": "host",
  "roomCode": "482913",
  "participantId": "u-123",
  "displayName": "Host A",
  "trtc": {
    "sdkAppId": 1400000000,
    "strRoomId": "media-482913",
    "userId": "u-123",
    "userSig": "<short-lived-user-sig>",
    "privateMapKey": "<room-scoped-permission-ticket>",
    "expiresAtMs": 1780000000000
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `trtc.sdkAppId` | yes | Public TRTC SDKAppID. |
| `trtc.strRoomId` | yes | Provider room mapped from the application room code. The adapter uses string room IDs consistently. |
| `trtc.userId` | yes | TRTC identity; it must exactly equal `participantId`. |
| `trtc.userSig` | yes | Short-lived UserSig signed by the backend. |
| `trtc.privateMapKey` | yes | Room-scoped permissions signed by the backend. Enable TRTC advanced permission control for the SDKAppID so the service enforces this grant. |
| `trtc.expiresAtMs` | recommended | UserSig and PrivateMapKey expiry as Unix milliseconds. Core adapters renew before this time and re-enter with the same room and identity. |

The TRTC adapter uses the `videoCall` scene for `participant`, and the `live`
scene for `host` and `viewer`. The reference backend derives those roles from
`roomMode`, so clients joining an existing room do not choose the scene or
promote themselves.
Publisher grants include room create/join and main-stream audio/video
send/receive permissions. Viewer grants include room create/join and audio/video
receive only; they must not include audio, video, or substream publish bits.
The Flutter viewer surface also has no publish controls and reports
`canSendData=false`. Participant/host custom messages are supported. Screen
sharing, viewer messages, and audio-device enumeration are not supported by
this adapter version.

The TRTC adapter implements the optional Core credential-refresh capability.
It renews credentials before `expiresAtMs` and rejoins the same room as the same
TRTC user. The backend must verify the caller's application identity and role
before signing replacement values. Long-lived `TRTC_SDK_SECRET_KEY` values
never belong in Flutter.

### Alibaba Cloud ARTC provider block

```json
{
  "contractVersion": 1,
  "provider": "artc",
  "role": "host",
  "roomCode": "482913",
  "participantId": "u-person1",
  "displayName": "Host A",
  "artc": {
    "appId": "<public-artc-app-id>",
    "channelId": "media-482913",
    "userId": "u-person1",
    "authInfo": "<short-lived-base64-auth-info>",
    "expiresAtMs": 1790000000000
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `artc.appId` | yes | Public ARTC AppID. The AppKey is never returned to Flutter. |
| `artc.channelId` | yes | ARTC channel mapped from the application room code. |
| `artc.userId` | yes | ARTC user identity; it must equal `participantId`. |
| `artc.authInfo` | yes | Short-lived, Base64-encoded single-parameter token generated by the backend. |
| `artc.expiresAtMs` | yes | Token expiry as Unix milliseconds; Core refreshes before expiry and rejoins with the same identity. |

The backend maps `meeting` rooms to `participant`/communication mode and
`broadcast` rooms to `host` or `viewer`/interactive live mode. It must keep the
provider, room, participant, and role bound during credential refresh. ARTC
tokens authenticate the app, channel, user, and expiry; they do not encode a
server-enforced viewer publishing grant. The Core viewer surface has no publish
methods and joins in viewer mode, but this does not prevent a modified client
from changing its SDK role. ARTC custom data messages require a publisher to
have an active audio or video stream; viewers can receive messages but cannot
send them through this adapter.

### Amazon IVS Real-Time provider block

~~~json
{
  "contractVersion": 1,
  "provider": "ivs",
  "role": "viewer",
  "roomCode": "482913",
  "participantId": "viewer-a",
  "chatProvider": "ivs-chat",
  "ivs": {
    "stageArn": "arn:aws:ivs:us-west-2:123456789012:stage/abc",
    "token": "<short-lived-participant-token>",
    "tokenParticipantId": "<aws-participant-id>",
    "capabilities": ["SUBSCRIBE"],
    "expiresAtMs": 1790573600000,
    "region": "us-west-2"
  }
}
~~~

The backend must enforce Stage capabilities. participant / host receive
PUBLISH + SUBSCRIBE; viewer receives SUBSCRIBE only. The AWS
tokenParticipantId is provider state and may change on refresh. The top-level
participantId is the stable logical application identity and must not change.

The IVS adapter refreshes an active Stage with exchangeToken instead of
leaving/rejoining. Credential refresh resolves the role from the stored
participant before calling CreateParticipantToken, so a viewer cannot request a
host token. The reference backend maps host participant removal to IVS
DisconnectParticipant.

### Chime compatibility

A Chime-only backend may omit `provider`, `role`, and `participantId` and
return the original shape:

```json
{
  "contractVersion": 1,
  "roomCode": "482913",
  "meeting": {
    "MeetingId": "...",
    "ExternalMeetingId": "...",
    "MediaRegion": "ap-southeast-1",
    "MediaPlacement": {
      "AudioHostUrl": "...",
      "AudioFallbackUrl": "...",
      "SignalingUrl": "...",
      "TurnControlUrl": "..."
    }
  },
  "attendee": {
    "AttendeeId": "...",
    "ExternalUserId": "...",
    "JoinToken": "..."
  }
}
```

The SDK resolves a missing `provider` to `chime`. See
[`MEDIA_BACKEND_CONTRACT.md`](MEDIA_BACKEND_CONTRACT.md) for the full Chime field list; the
Chime adapter validates `attendee.AttendeeId` against `participantId` when the
common field is supplied. The current Chime adapter intentionally advertises
only `participant`; `host`/`viewer` are rejected until backend-enforced Chime
broadcast permissions are implemented.

## Local provider modes

The existing `demo-server` implements the reference multi-provider backend.
It remains the only application-backend process:

```bash
cd demo-server
npm start
```

The server listens on `http://127.0.0.1:3000` by default. Open its existing
dashboard at `/` to switch the provider used for **new rooms** between LiveKit,
Agora, and AWS Chime without restarting Flutter. Existing rooms remain bound to their
original provider. Join/heartbeat/leave/delete resolve only by room code.

For local LiveKit testing, run `bash scripts/livekit-dev.sh start`, then source
`eval "$(bash scripts/livekit-dev.sh env)"` before `npm start`. No second backend or
gateway process is required.

For Agora, set `AGORA_APP_ID` and `AGORA_APP_CERTIFICATE` on `demo-server`.
`AGORA_TOKEN_TTL_SECONDS` defaults to 600 seconds. The server uses AccessToken2
and never exposes the App Certificate. No Agora credential belongs in Flutter
or in `--dart-define` values.

The current Chime adapter guarantees meeting/`participant` rooms only. If the
server UI is switched to Chime and a client creates a `broadcast` room, the
reference server returns a typed error instead of silently falling back to
another provider.

## Error shape

```json
{
  "contractVersion": 1,
  "error": {
    "code": "room-not-found",
    "message": "The requested room was not found.",
    "details": {}
  }
}
```

`details` is optional. Clients also understand the older demo shape where
`error` is a plain string.

| Code | Suggested HTTP status | Flutter `MediaBackendErrorCode` |
| --- | ---: | --- |
| `unauthorized` | 401 | `unauthorized` |
| `forbidden` | 403 | `forbidden` |
| `room-not-found` | 404 | `roomNotFound` |
| `participant-not-found` | 404 | `participantNotFound` |
| `room-exists` | 409 | `roomConflict` |
| `bad-room-code` | 400 | `invalidRoomCode` |
| `unsupported-provider` | 400 | `unsupportedProvider` |
| `provider-not-configured` | 503 | `providerNotConfigured` |
| any other `4xx` | 400 | `invalidArgument` |
| any `5xx` | 500 | `serverError` |

Transport and timeout failures map to `network` and `timeout` respectively.

## Role and permission guarantees

Client-side roles are a convenience; **the backend is the security boundary**.
For the modern contract, the backend assigns the role from room mode and stable
identity instead of trusting a joiner's requested role.

- `viewer` credentials must be issued without media publish permission. The
  LiveKit adapter additionally exposes no publish method on
  `BroadcastViewerSession`, but that alone does not protect the room.
- `host` credentials must be allowed to publish audio and video.
- The server should scope each token to the requested room, keep the TTL short,
  and log/reject attempts to join a room the role was not issued for.

## Provider notes

| Provider | Room lifetime | Billing notes |
| --- | --- | --- |
| LiveKit (self-hosted) | Auto-created on first join; empty rooms cost nothing | No per-minute charge; you pay for the host |
| LiveKit Cloud | Same | Metered in participant-minutes; the free Build tier has hard monthly caps |
| AWS Chime | Explicitly created and must be deleted after use | Attendee-minutes bill while someone is in the meeting; delete the meeting to stop future joins |
| Amazon IVS Real-Time | Stage is explicitly created/deleted by the backend | Short-lived Stage participant tokens remain server-issued |

## Backend responsibilities

A production backend owns authentication, authorization, rate limiting, room
policy, persistence, provider credential configuration, and (for Chime) AWS IAM
setup. The existing `demo-server` is a development/reference implementation
only; it is not a production deployment template.


---

## 独立 Chat 后端 API

### Versioning

Chat requests send header X-Realtime-Chat-Contract: 1. Authentication uses the
same application-level Authorization or custom headers as the media backend.
Provider API credentials remain server-side.

### Issue chat credentials

POST /rooms/{roomCode}/chat/token

Request:

~~~json
{
  "participantId": "viewer-a",
  "participantCredential": "<opaque-session-proof>"
}
~~~

participantId must already belong to the media room and participantCredential
must be the opaque proof issued to that exact participant by the media join
response. Knowing another participant's id is therefore insufficient to mint
their chat token. The client does not send userId, displayName, or role to
obtain chat permission. The backend validates the participant proof, resolves
the stored media participant, and grants capabilities from that server-side
identity/role.

The media backend must also establish that role without trusting public,
client-declared identity fields. In particular, `userId`, `displayName`,
and `deviceId` must not restore a broadcast `host`. The reference backend
issues a separate random `roomOwnerCredential` when the broadcast is created
and only a join presenting that proof can become `host`. This matters because
chat messages may expose the sender's logical `userId`; learning that value
must not allow another participant to obtain `DELETE_MESSAGE` or
`DISCONNECT_USER`.

Response:

~~~json
{
  "contractVersion": 1,
  "chatProvider": "ivs-chat",
  "roomCode": "482913",
  "participantId": "viewer-a",
  "userId": "account-123",
  "displayName": "Viewer A",
  "role": "viewer",
  "chat": {
    "roomArn": "arn:aws:ivschat:us-west-2:123456789012:room/abc",
    "token": "<short-lived-chat-token>",
    "capabilities": ["SEND_MESSAGE"],
    "tokenExpirationTimeMs": 1790570600000,
    "sessionExpirationTimeMs": 1790573600000,
    "region": "us-west-2"
  }
}
~~~

The `chat` object is provider-specific. Current reference adapters use these
shapes in addition to Amazon IVS Chat:

~~~json
{
  "chatProvider": "tencent-chat",
  "chat": {
    "sdkAppId": 1400000001,
    "groupId": "rm_482913",
    "providerUserId": "u_ab12...",
    "userSig": "<short-lived-usersig>",
    "capabilities": ["SEND_MESSAGE"],
    "userSigExpirationTimeMs": 1790570600000
  }
}
~~~

~~~json
{
  "chatProvider": "agora-chat",
  "chat": {
    "appKey": "org#app",
    "chatRoomId": "123456789",
    "providerUserId": "u_cd34...",
    "token": "<short-lived-chat-user-token>",
    "capabilities": ["SEND_MESSAGE"],
    "tokenExpirationTimeMs": 1790570600000
  }
}
~~~

For Amazon IVS Chat, participant/viewer receives SEND_MESSAGE. Host receives
SEND_MESSAGE, DELETE_MESSAGE, and DISCONNECT_USER. Token duration is clamped to
the AWS-supported 1-180 minute range. During reconnect, the native Chat SDK
requests a fresh token through Dart instead of reusing a consumed token.

Tencent Cloud Chat and Agora Chat currently receive SEND_MESSAGE only. Their
managed services provide broader moderation APIs, but the current Flutter
`ChatSession` adapter intentionally does not grant client-side delete/kick
authority. Tencent reconnect refreshes UserSig and Agora reconnect renews the
Chat user token through the same credential callback. Provider secrets and
REST app/admin tokens never leave the backend.

The participantCredential is not an AWS credential. The reference backend
generates 32 random bytes per admitted participant, returns the opaque value
only to that participant, and stores only a SHA-256 digest. A new join for that
participant rotates the proof.

If a room has no chat provider, the reference backend returns
unsupported-feature. Clients may then decide whether their current media
session supports the optional RTC Chat fallback. Unknown rooms or participants
return typed errors. A failure while connecting a configured product Chat must
not be interpreted as permission to silently switch to fallback.

### Room lifecycle

The backend creates the product-chat room together with the media room when a
Chat Provider is enabled and deletes both when the application room closes.
Changing the default Media or Chat Provider affects only newly created rooms;
existing rooms retain both bindings.


---

## AWS Chime 专属后端协议

### Versioning

The current contract version is `1`.

The SDK sends this request header on contract calls:

```http
X-Chime-Backend-Contract: 1
```

Compatible servers should return the same header and may also include:

```json
{ "contractVersion": 1 }
```

Servers may accept requests without the version header for backward
compatibility. If a supplied version is unsupported, return HTTP `400` with
the standard error body below.

### Authentication

Authentication belongs to the application. When `ChimeClient` is configured
with a `tokenProvider`, it sends:

```http
Authorization: Bearer <application-token>
```

This is an application token, not an AWS credential and not the AWS Chime
`JoinToken`. Backends may use any authentication scheme by using
`headersProvider` instead.

### Join response

Create-and-join and join-room responses must contain `roomCode`, `meeting`, and
`attendee`. The `meeting` and `attendee` objects follow the AWS Chime SDK
response shape consumed by `JoinInfo.fromJson`:

```json
{
  "contractVersion": 1,
  "roomCode": "482913",
  "meeting": {
    "MeetingId": "...",
    "ExternalMeetingId": "...",
    "MediaRegion": "ap-southeast-1",
    "MediaPlacement": {
      "AudioHostUrl": "...",
      "AudioFallbackUrl": "...",
      "SignalingUrl": "...",
      "TurnControlUrl": "..."
    }
  },
  "attendee": {
    "AttendeeId": "...",
    "ExternalUserId": "...",
    "JoinToken": "..."
  }
}
```

Additional fields are allowed and ignored by the SDK.

### Endpoints

#### `POST /rooms`

Create a room and create an attendee for the caller.

Request:

```json
{
  "nickname": "Leo",
  "roomCode": "482913"
}
```

`roomCode` is optional. A server may generate one. `nickname` is required by
the SDK convenience API. Success returns the join response above.

Recommended errors include `bad-room-code` (`400`) and `room-exists` (`409`).

#### `POST /rooms/{roomCode}/join`

Create an attendee in an existing room.

Request:

```json
{ "userId": "Leo" }
```

Success returns the join response. A missing room should return
`room-not-found` with HTTP `404`.

#### `POST /rooms/{roomCode}/heartbeat`

Best-effort presence signal used by `ChimeRoomSession`. The SDK calls this once
after joining and then at the configured heartbeat interval.

Request body may be empty JSON:

```json
{}
```

Example success:

```json
{ "contractVersion": 1, "ok": true, "roomCode": "482913" }
```

Heartbeat failure is reported on `ChimeRoomSession.backendErrors`; it does not
automatically terminate an otherwise healthy Chime media session.

#### `POST /rooms/{roomCode}/leave`

Best-effort leave notification.

```json
{ "attendeeId": "..." }
```

The SDK may retry cleanup through normal lifecycle paths, so implementations
should make this endpoint safe to call more than once.

#### `DELETE /rooms/{roomCode}`

Optional administrative operation exposed by `ChimeBackendClient.closeRoom`.
Applications are not required to expose this endpoint to ordinary clients.

### Error shape

Contract endpoints should use this form:

```json
{
  "contractVersion": 1,
  "error": {
    "code": "room-not-found",
    "message": "The requested room was not found.",
    "details": {}
  }
}
```

`details` is optional. `ChimeBackendClient` also understands the older demo
shape where `error` is a string, so existing demo integrations can migrate
gradually.

Common codes recognized by the Flutter SDK:

| Code | Suggested HTTP status | Flutter error |
| --- | ---: | --- |
| `unauthorized` | 401 | `unauthorized` |
| `forbidden` | 403 | `forbidden` |
| `room-not-found` | 404 | `roomNotFound` |
| `room-exists` | 409 | `roomConflict` |
| `bad-room-code` | 400 | `invalidRoomCode` |

Unknown `5xx` responses map to `serverError`; transport and timeout failures
map to `network` and `timeout` respectively.

### Backend responsibilities

A production backend is responsible for authentication, authorization,
rate-limiting, room policy, persistence if needed, and AWS IAM configuration.
Those concerns are intentionally outside this Flutter package.

The repository `demo-server` is only a reference implementation for running
the example and validating this contract. It is not a production deployment or
infrastructure template.
