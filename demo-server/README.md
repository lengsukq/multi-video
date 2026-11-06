# Demo backend (keys stay here, never in Flutter)

`npm start` is the **single application-backend entry point** for the demo. It
serves the Flutter room API and the browser dashboard used to switch newly
created rooms between AWS Chime, LiveKit, Agora, Tencent TRTC, and Alibaba ARTC
at runtime.

## Run

The demo server uses Node's native erasable-TypeScript support and requires
Node.js 22.18 or newer. No transpile/build step is required for local use.

```bash
cd demo-server
npm install
AWS_PROFILE=chime-demo npm start
# or: PORT=3000 CHIME_MEDIA_REGION=ap-southeast-1 AWS_PROFILE=chime-demo npm start
```

`npm start` loads an optional local `.env` file. Keep that file out of version
control; the repository ignore rule already excludes it.

Static type checking and tests:

```bash
npm run typecheck
npm test
# or both
npm run check
```

Optional demo authentication:

```bash
DEMO_BEARER_TOKEN=my-local-token AWS_PROFILE=chime-demo npm start
```

When `DEMO_BEARER_TOKEN` is set, room connection endpoints require
`Authorization: Bearer <token>`. This is only a reference hook for exercising
`MediaClient.tokenProvider`; it is not a production identity system.

### Classroom notes and lesson chapter markers

Teachers may create, update and delete notes (up to 500 per room, maximum
2000 characters each) and manually mark 140-character lesson chapters. These
use the authenticated Classroom action endpoint and are included **only in
teacher snapshots**. The timestamps are measured from room creation and are
not mapped to a cloud recording seek time.

Without `CLASSROOM_STATE_DIR`, classroom notes remain **in memory only**.
For single-instance demo deployments set `CLASSROOM_STATE_DIR` to a writable
private folder: `FileClassroomStore` saves notes in per-room 0600 files,
including action idempotency and classroom revision. This is not shared
multi-node storage and is not durable on ephemeral/serverless filesystems.
**Room closure deletes that classroom state**; export lesson minutes from the
teacher's Notes sidebar before closing. Implement a separate authenticated
archive with its own retention rules for long-term post-class access.

Health check:

```bash
curl http://localhost:3000/health
```

Dashboard:

```text
http://localhost:3000/
```

The dashboard supports Simplified Chinese and English. It follows the browser
language on first visit, and remembers the selected language in that browser.
API error messages follow the request's `Accept-Language` header; error codes
remain language-neutral.

Switching the dashboard provider affects **new rooms only**. Existing room
codes stay bound to the provider that originally created them.

## Provider adapter architecture

The server keeps **one** public entry (`npm start`), but HTTP responsibilities
are no longer all located in `server.ts`:

```text
server.ts                             entry/re-exports only
    |
    `-- app.ts                         Express, registry, middleware, wiring
          |-- routes/dashboard-routes.ts     Admin / Health / provider selection
          |-- routes/room-routes.ts          room lifecycle and discovery
          |-- routes/chat-routes.ts          standalone/attached Chat
          |-- routes/interaction-routes.ts   Classroom / Live interaction registration
          `-- routes/recording-routes.ts     recording API and HTTP exports
               |
               +-- services/                 application orchestration and policy
               +-- providers/                 RTC token/SDK adapters
               +-- chat/                      product Chat providers
               +-- classroom/                 classroom state and operation queue
               `-- live/                      live interaction state
```

`server.ts` simply exposes the app and related exports. `app.ts` assembles
registries, shared middleware and typed routers. Cross-cutting room identity
and role rules, registry/lookup, room operation locks and summaries, partial
close recovery, administrator authentication and persisted provider selection
now live under `services/`: `room-input.ts`, `room-registry-service.ts`,
`room-operations.ts`, `room-closure.ts`, `admin-auth.ts`,
`provider-selection.ts`, and the interaction/recording application operations. The dashboard router receives the selected provider
through injected state. `app.ts` retains composition and periodic sweeping;
it is not a production stateless service. Existing HTTP paths, response shapes,
credentials, error codes and room-to-provider binding remain unchanged.

Provider adapters still own SDK calls, credential signing, role policy, join
payloads, cleanup and provider-specific summaries. The demo backend is a
trusted **control plane**, not a media relay or production-ready identity/
storage service. Server-side secrets must never be returned to the Flutter app.

Shared contracts live in `types.ts`. `ProviderRegistry` accepts only objects
that satisfy `ProviderAdapter`, so missing create/join/close/summary behavior
or incompatible join responses fail during `npm run typecheck`.

The `RoomDirectory` stores the application room-code-to-provider binding, so a
runtime provider switch only changes newly-created rooms. Chime meeting ids are
resolved through the same provider-neutral room lookup used by `/rooms` routes.

### Add another RTC provider

To add another provider, create one module under `providers/` implementing the
adapter contract and register it during `app.ts` composition:

```ts
const provider: ProviderAdapter = {
  id: 'vendor',
  displayName: 'Vendor RTC',
  isConfigured: () => true,
  supportsRole: () => true,
  async createRoom({ roomCode, role }) { /* ... */ },
  async joinRoom({ entry, rawName, role }) { /* ... */ },
  async closeRoom({ entry, reason }) { /* ... */ },
  summarizeRoom(entry, { host }) { /* ... */ },
}
```

Optional hooks include `metadata`, `aliases`, `removeAttendee`,
`refreshCredentials`, and `resolveExternalRoom`. The main create/join/close
routes do not require provider-specific `if`/`switch` branches. The dashboard
renders provider buttons and room labels from `/api/overview.providerList`, so
new adapters do not need a dedicated dashboard button.

The `/health`, `/api/provider`, `/api/chat-provider`,
`/api/overview`, and `/rooms` endpoints are public contract surfaces,
not implementation details of a particular router. Route extraction must not
weaken owner authorization, short-lived credential rules or same-origin admin
protection. See [P1 architecture and integration](../doc/ARCHITECTURE.md)
for the updated SDK/Demo/Backend ownership diagram and pending E2E gates.

## Room flow used by the example app

The current `example/` app consumes `Realtime.standard()` and
`Realtime.open(RealtimeRequest)` through the public SDK facade, backed by
the provider-neutral room contract documented in
[`../doc/MEDIA_BACKEND_CONTRACT.md`](../doc/MEDIA_BACKEND_CONTRACT.md):

1. App: `POST /rooms {"nickname":"host","roomCode":"482913","role":"participant"}` — no provider field.
2. Server selects the current dashboard provider and returns `provider` plus provider-specific short-lived join data.
3. Guest: `POST /rooms/482913/join {"userId":"guest","role":"participant"}` — room code resolves the original provider.
4. Runtime resolves the matching provider bundle and starts the media session.
5. SDK sends heartbeat/leave through the same room contract.

Chime-specific legacy `/meetings` and `/join` endpoints have been removed.
Chime clients use the same provider-neutral `POST /rooms` and
`POST /rooms/:code/join` contract as every other media provider. The optional
`X-Chime-Backend-Contract` header remains accepted on these unified routes for
existing Chime SDK clients.

The example app also sends an optional install-scoped `deviceId`. It is a
random UUID generated by the app and persisted locally; it is not a hardware
identifier. Within one room the demo server treats the latest participant for
the same `deviceId` as the same logical device, so leaving/rejoining with a
different display name does not accumulate stale copies of that device in the
dashboard. Provider `participantId` values remain connection-specific.

Room roles are backend-assigned. When creating a room the Flutter demo chooses
only a product-level room type:

- **Meeting** → creator and all joiners are `participant`.
- **Live** → creator is `host`; other devices are `viewer`.

Join requests do not choose their own role. A Live creator that reconnects with
the same persisted device identity remains the host. Providers that cannot
support both host and viewer roles (currently the Chime adapter) reject Live
room creation.

The demo also exposes `GET /rooms/discover` for the Flutter join screen. It
returns only room code, provider, room mode, creation time, and current attendee
count. Participant names, device ids, and provider credentials are not exposed
through discovery. The Flutter example refreshes this list while the Join tab is
visible and can join a selected room with one tap.

Current SDK heartbeats include `participantId`. The demo tracks a per-participant
last-seen timestamp and removes stale logical participants from discovery/admin
counts while keeping empty-body room heartbeats compatible with older clients.

The reference server also exposes optional logical-owner management routes for
Meeting and Live rooms: `POST /rooms/:code/participants`,
`POST /rooms/:code/participants/remove`, and
`POST /rooms/:code/close`. Meeting creators keep the provider-native
`participant` media role but receive a separate `roomOwnerCredential`; this
credential authorizes logical room management without inventing a provider host
role. Participant listing returns the stable logical `userId`, display name,
participant id, and role needed by the SDK to merge Media and Chat membership,
but never returns device ids, provider secrets, or long-lived credentials.
Server-enforced participant removal is currently available for providers whose
adapter exposes a real moderation API (for example LiveKit and IVS Real-Time).
Unsupported providers return `unsupported-feature` instead of pretending a
local list deletion kicked a remote RTC client.

Management in the Flutter SDK is **client-first, backend-when-required**.
Provider adapters may advertise a management operation as `client`,
`backend`, `hybrid`, or `unsupported`. If the provider SDK can safely
enforce the action with the user's short-lived credentials, Flutter calls it
directly. This demo server only handles token issuance, logical room
authorization, and operations that genuinely require a trusted provider admin
API.

Standalone Chat has matching host routes for member listing, member removal,
and room close. Attached Chat exposes the same operations under
`/rooms/:code/chat/*`. Amazon IVS Chat host tokens can enforce disconnect
directly in the client; Tencent Chat and Agora Chat in this demo use ordinary
member credentials, so member removal falls back to their server-side REST
admin APIs. A production backend that grants real provider owner/admin
credentials can advertise client execution through the same capability model.

Because this Demo intentionally has no account system, participant credentials
plus the logical `roomOwnerCredential` are demonstration-level authorization,
not a production account security boundary. A real backend should bind these
operations to its authenticated user/session and independently authorize every
privileged action.

## Public Vercel deployment

The server can be deployed from this directory as an Express Vercel Function.
The dashboard HTML lives in `public/index.html` and is bundled with the
function. Set the Vercel project root to `demo-server`.

Before a public deployment, configure a strong `MEDIA_ADMIN_PASSWORD`. The
dashboard requires this password, then uses an HttpOnly, Secure, SameSite
admin cookie. Management endpoints are same-origin only. The media API enables
CORS by default and allows the contract and Authorization headers, so a Flutter
app hosted on another origin can call it. Browser admin cookies are deliberately
not enabled for cross-origin requests.

`MEDIA_CONNECTIONS_ENABLED=false` makes room creation, joining, credential
refresh, leave, heartbeat, and legacy connection endpoints return HTTP 503.
On Vercel, environment changes apply to a new deployment, so pausing or
resuming through this setting requires redeploying. Deploy publicly with this
setting `false`, then set it to `true` only when ready to accept connections.

This demo server keeps room bindings and activity logs in process memory. Vercel
Functions can run on different instances, so keep public connections paused
until `RoomDirectory` is backed by shared persistent storage. The admin
dashboard remains available while connections are paused. The Chat Provider can
be changed from the dashboard on Vercel; that selection is held only in the
current function instance and is neither shared across instances nor retained
after a cold start. A cold start uses `CHAT_DEFAULT_PROVIDER` (or disables Chat
when it is unset). Use shared persistent storage for a deployment-wide runtime
selection.

## Env

| var | default | note |
|---|---|---|
| `AWS_PROFILE` | — | must be `chime-demo` (least-privilege IAM) |
| `AWS_REGION` | `us-east-1` | Chime control plane |
| `CHIME_MEDIA_REGION` | `ap-southeast-1` | media region near CN |
| `PORT` | `3000` | — |
| `DEMO_BEARER_TOKEN` | unset | optional bearer token for room API demos |
| `MEDIA_ADMIN_PASSWORD` | unset | required on Vercel; protects the management dashboard and admin endpoints |
| `MEDIA_CONNECTIONS_ENABLED` | `true` locally, `false` on Vercel | set `false` to reject room connection requests; Vercel requires a redeploy after changes |
| `MEDIA_DEFAULT_PROVIDER` | `chime` | default provider for new rooms; on Vercel set this in the project environment |
| `CHAT_DEFAULT_PROVIDER` | `none` | `none`, `ivs-chat`, `tencent-chat`, or `agora-chat`; dashboard changes are instance-local on Vercel |
| `IVS_CHAT_REGION` | active AWS region | optional IVS Chat region override; otherwise uses `AWS_REGION`, `AWS_DEFAULT_REGION`, or the active AWS profile's configured region |
| `TENCENT_CHAT_SDK_APP_ID` | unset | Tencent Chat SDKAppID returned to the client |
| `TENCENT_CHAT_SECRET_KEY` | unset | server-only UserSig signing secret |
| `TENCENT_CHAT_ADMIN_USER` | `administrator` | Tencent Chat app admin identifier used by REST APIs |
| `TENCENT_CHAT_REST_HOST` | `https://console.tim.qq.com` | REST host; override for the SDKAppID data region (Singapore/Seoul/Tokyo/etc.) |
| `TENCENT_CHAT_TOKEN_TTL_SECONDS` | `3600` | UserSig lifetime, clamped to 60 seconds–7 days |
| `AGORA_CHAT_APP_KEY` | unset | Agora Chat App Key (`org#app`) returned to Android/iOS clients; REST URLs use the App ID path |
| `AGORA_CHAT_REST_HOST` | unset | REST domain assigned by Agora Chat for the project |
| `AGORA_CHAT_APP_ID` | `AGORA_APP_ID` | Chat token App ID; falls back to the RTC Agora App ID |
| `AGORA_CHAT_APP_CERTIFICATE` | `AGORA_APP_CERTIFICATE` | server-only Chat token certificate; falls back to the RTC certificate |
| `AGORA_CHAT_OWNER_USER` | `realtime_owner` | service account used as reference ChatRoom owner; demo server creates it if absent |
| `AGORA_CHAT_TOKEN_TTL_SECONDS` | `3600` | Chat user token lifetime, clamped to 60–86400 seconds |
| `LIVEKIT_URL` | unset | LiveKit Cloud/server WebSocket URL |
| `LIVEKIT_API_KEY` | unset | server-side LiveKit API key |
| `LIVEKIT_API_SECRET` | unset | server-side signing secret; keep it in the ignored `.env` |
| `LIVEKIT_TOKEN_TTL_SECONDS` | `600` | short-lived LiveKit token lifetime |
| `AGORA_APP_ID` | unset | public Agora App ID returned in Agora join payloads |
| `AGORA_APP_CERTIFICATE` | unset | server-only Agora signing secret; never return it to Flutter |
| `AGORA_TOKEN_TTL_SECONDS` | `600` | AccessToken2 lifetime in seconds, clamped to 60–86400 |
| `TRTC_SDK_APP_ID` | unset | public TRTC SDKAppID returned in join payloads |
| `TRTC_SDK_SECRET_KEY` | unset | server-only UserSig/PrivateMapKey signing secret; never return it to Flutter |
| `TRTC_TOKEN_TTL_SECONDS` | `600` | UserSig and PrivateMapKey lifetime; accepted range is 60 seconds–90 days |
| `ARTC_APP_ID` | unset | public ARTC AppID returned in join payloads |
| `ARTC_APP_KEY` | unset | server-only ARTC token-signing key; never return it to Flutter |
| `ARTC_TOKEN_TTL_SECONDS` | `600` | ARTC token lifetime; accepted range is 60–86400 seconds |
| `ARTC_RECORDING_STORAGE` | `vod` | ARTC: `vod` via Live RTC APIs (default), `oss` for legacy RTC recording |
| `ARTC_RECORDING_VOD_REGION` | `cn-shanghai` | `cn-shanghai` or `ap-southeast-1`; VOD not available for US East RTC recording |
| `ARTC_RECORDING_VOD_STORAGE_LOCATION` | unset | Alibaba VOD media storage address |
| `ARTC_RECORDING_VOD_TRANSCODE_GROUP_ID` | unset | VOD transcoding group that produces unencrypted MP4 |
| `ARTC_RECORDING_VOD_HOSTS` | unset | Exact HTTPS VOD video delivery hosts allowed by server HTTP proxy |
| `TRTC_RECORDING_STORAGE` | `vod` | `vod` (default), `s3` to write directly to AWS S3 |
| `TRTC_RECORDING_S3_BUCKET` / `TRTC_RECORDING_S3_REGION` | unset | Private S3 bucket/region for TRTC direct S3 upload |
| `TRTC_RECORDING_S3_ACCESS_KEY` / `TRTC_RECORDING_S3_SECRET_KEY` | unset | Server-only TRTC S3 upload and authorized download credentials |

For local LiveKit Server testing:

```bash
bash ../scripts/livekit-dev.sh start
eval "$(bash ../scripts/livekit-dev.sh env)"
AWS_PROFILE=chime-demo npm start
```

For Agora testing, put the App ID and App Certificate in the ignored `.env`
or the server process environment:

```bash
AGORA_APP_ID=... AGORA_APP_CERTIFICATE=... npm start
```

The server signs Agora AccessToken2 credentials. `participant` and `host`
receive publish privileges; `viewer` is issued no audio/video/data publish
privileges and joins the Flutter SDK as an audience client. Agora only
server-enforces those fine-grained publish privileges when co-host
authentication is enabled for the Agora project, so production use must verify
that project capability before relying on it as a security boundary.

For TRTC, put `TRTC_SDK_APP_ID` and `TRTC_SDK_SECRET_KEY` in the ignored
`.env` or server environment. Enable **Advanced Permission Control** for that
SDKAppID in the Tencent RTC console; without it, TRTC will not enforce the
PrivateMapKey grant. `participant` rooms use the video-call scene, while
`host`/`viewer` rooms use the live scene. Scene choice is fixed when the room
is created, so the backend rejects cross-scene joins. Viewer PrivateMapKeys
allow room entry and receiving main-stream audio/video, but omit audio/video
publish and screen-share rights. The optional
`POST /rooms/{roomCode}/credentials/refresh` route only renews credentials for
an existing attendee with the same identity and role. The Flutter adapter
renews before ticket expiry and rejoins with the same user id.

For ARTC, set `ARTC_APP_ID` and `ARTC_APP_KEY` in the ignored `.env` file or
server environment. The server signs short-lived, single-parameter ARTC auth
information; the AppKey is never returned to Flutter. `participant` rooms use
communication mode, while `host`/`viewer` rooms use interactive live mode.
The backend locks a room to its creation mode and authorizes credential refresh
only for the same attendee and role. ARTC's signed token does not encode
viewer-versus-streamer permissions: role is selected by the client SDK. The
viewer adapter surface is subscribe-only, but this is not a server-enforced
security boundary against a modified client.

## Scope

This server is a reference implementation for running the example and
validating backend contract v1. It intentionally uses in-memory room state;
restarting the process clears that directory. A public Vercel deployment must
remain paused until shared room persistence and production monitoring are added.


## Classroom and Live interaction reference APIs

Meeting rooms expose authenticated classroom snapshots/actions for hand/Q&A,
notices, homework, material links, timers, Quiz/Poll, attendance and screen
annotation state. Broadcast rooms expose `/rooms/:code/live/snapshot` and
`/rooms/:code/live/gift`. The reference server advertises `liveInteractions:
true` in Broadcast join responses; the SDK attaches and disposes the optional
session and UI. Gifts are demonstration events, not payments.

`CHAT_DEFAULT_PROVIDER` and dashboard selection apply independently to all
media vendors, including AWS Live. A selected Chat binding remains fixed for
that room. No selection creates no product Chat.

The new tool/gift state is room-lifecycle memory only. Material sharing accepts
existing HTTP(S) links; uploading/storing files and recording courses are not
implemented. The legacy optional classroom state store does not persist these
new tools. See [Classroom SDK](../doc/CLASSROOM_SDK.md),
[Live SDK](../doc/CLASSROOM_SDK.md) and
[acceptance](../doc/ACCEPTANCE.md).

### Whiteboard control plane

Teaching snapshots declare `tools.content` with a content revision/mode, teacher
manage permission, screen canvas and a paged whiteboard. The existing authenticated
classroom action endpoint accepts `tool.content.mode` and `tool.whiteboard.*`.
Content transitions require the content revision; page/drawing actions require the
board revision. Drawing also checks current page/canvas IDs, finite shared
whiteboard scene points (bounded to ±1000), and
limits. Teacher identity and duplicate event payloads are validated before mutation.
Only current-page marks are transmitted; other pages remain in room-lifecycle memory.
No new persistence/storage is added. See [Whiteboard SDK](../doc/CLASSROOM_SDK.md).
