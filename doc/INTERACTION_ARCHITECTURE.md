# Interaction architecture (incremental migration)

## Ownership and dependency baseline

This is a frontend SDK, not a classroom or gifting product. Keep transport,
session lifecycle, capabilities and cross-provider adaptation in the SDK. Keep
the existing classroom and live interactions as **optional, prebuilt SDK
features**, not as rewritten Demo-only logic.

| Existing implementation | Current role | Target |
| --- | --- | --- |
| `media_core` `MediaSessionDataControl` | RTC Data send/receive and provider feature flags | Reuse as low-level transport; never claim all providers support data |
| `chat_core` `ChatSystemMessaging` | Chat-mediated revision hints | Reuse for hints only, not authenticated business commands |
| `classroom_core` `ClassroomSession`; `classroom_preset` `HttpClassroomRepository` | Hand raise, Q&A, speak grants, homework, announcements, timers | Preserve implementation as opt-in Classroom prebuilt feature |
| `live_core` `LiveInteractionSession`/`HttpLiveInteractionRepository` | Likes, gifts, catalog and counters | Preserve implementation as opt-in Live prebuilt feature |
| `sdk_runtime` `RealtimeClient` | Always recognizes `roomMode=meeting` and `liveInteractions=true` metadata, creates business sessions; depends directly on both cores | Explicitly selected features; make core independent of prebuilt business modules |
| `sdk_ui`, `classroom_ui`, `live_ui` | Composable room controls, overlays and panels | Entirely optional; no fixed navigation or UI required for headless features |
| `example/`, `demo-server/` | Showcase layouts and HTTP reference authority | Demo composes widgets; server remains optional reference for authoritative operations |

## Contract boundaries

1. **Transient event:** transport delivers a versioned, room-scoped envelope;
   the sender field in its JSON is *not* a trusted identity. Transport adapters
   validate the authenticated sender when the provider exposes one. Delivery
   is best-effort and does not establish authoritative shared state.
2. **Command:** application-specific actions requiring permission, billing or
   durability go through an injected trusted control plane. RTC Data / IM
   messages can notify clients to fetch the updated snapshot, but cannot
   authorize a teacher grant or debit currency.
3. **Snapshot:** late join and reconnection require a trusted state fetch and
   monotonically increasing revision. Countdown uses a server `endsAt`, not
   local timers as the source of truth.
4. **Plugin:** core exposes feature registration, lifecycle and capabilities
   without importing classroom, gift, HTTP or UI types. Prebuilt modules supply
   their existing repository and business behavior; consumers may register
   their own features.

## Incremental rollout

- P0: independent Dart interaction contract and codec with tests; runtime
  adapter to existing RTC transport; no breaking changes to prebuilt sessions.
- P1: feature registry, opt-in Classroom and Live adapters, shared UI as
  composable widgets, and Demo integration without duplicating business code.
- P2: security checks, two-client/late-join recovery, provider capabilities,
  complete docs and platform verification.

## P0 implementation: headless transient events

The new `flutter_realtime_interaction_core` Dart package contains the
transport-agnostic contracts, event codec, capabilities, and control-plane
types. The SDK runtime provides `DefaultInteractionSession` and
`MediaInteractionTransport` built on the existing `MediaSession.sendData`
path. All RTC interaction envelopes use the reserved
`realtime.interaction.v1` topic, independently of ordinary chat.

```dart
// An existing connected RealtimeRoom; does not require classroom, gifting or
// an SDK UI package.
final interactions = room.interactions;
if (interactions.capabilities.canSubscribe) {
  final subscription = interactions.events.listen((event) {
    if (event.topic == 'myapp.poll.vote') {
      // Application decides presentation and business interpretation.
    }
  });
  // Cancel subscription on application teardown.
}
if (interactions.capabilities.canPublish) {
  await interactions.publish('myapp.poll.vote', {'choice': 'A'});
}
```

This is **transient best-effort transport**, not reliable storage, a trusted
poll tally or a guarantee of exactly-once delivery. Recipients validate room,
transport sender, topic, target and bounded event IDs. A short in-memory
deduplication window rejects repeats, but it is not a persistent event log.
Targeted events and unreliable delivery fail if unsupported by the provider.
`room.interactions` is initialized lazily and disposed with the room.

`InteractionControlPlane` is intentionally separate: until a trusted
application backend is injected, `execute` and `snapshot` report the
unsupported operation. Applications may pass an
`interactionControlPlaneFactory: (mediaRoom) => ...` when constructing
`RealtimeSdk`, `RealtimeSdk.standard`, `Realtime`, or `Realtime.standard`.
Each room then receives its own trusted backend instance; business authority
stays server-side. A present control plane enables:

- `interactions.currentSnapshot` plus non-replaying `snapshots` updates;
- `interactions.refresh()` to fetch authoritative state; initial and periodic
  refresh also recover missed hints;
- validated product IM revision hints when supported, otherwise RTC Data
  hints when supported; neither hint supplies authenticated user identity nor
  authorizes a command;
- monotonic snapshot revisions and single-flight refreshes.

The host can also register independently managed features:

```dart
// Registration on RealtimeSdk(...) / RealtimeSdk.standard(...) /
// Realtime(...) / Realtime.standard(...):
featurePlugins: [MyCustomFeaturePlugin()],

// After opening the room and awaiting room.initialize():
final feature = room.features.get(
  const RealtimeFeatureKey<MyCustomFeature>('myapp.custom'),
);
```

Feature plugins implement `RealtimeFeaturePlugin` and receive
`RealtimeFeatureContext` with media, chat and the lazy Interaction session.
They are only attached when registered, errors remain isolated, and cleanup
runs in reverse registration order without depending on Flutter UI.

## Opt-in prebuilt features (Classroom and Live)

The existing business functionality is **not moved to the Demo or reimplemented**.
Classroom and Live are separate **optional SDK packages**, rather than
dependencies of the generic SDK runtime:

- `flutter_realtime_classroom_preset` provides `ClassroomPreset`, typed
  `RealtimeRoomClassroomExtension`, the existing classroom business session,
  whiteboard, content share and annotation adapters.
- `flutter_realtime_live_preset` provides `LivePreset`, typed
  `RealtimeRoomLiveExtension`, existing like/gift sessions and their repository.

Applications explicitly import the desired package(s):

```dart
import 'package:flutter_realtime_classroom_preset/flutter_realtime_classroom_preset.dart';
import 'package:flutter_realtime_live_preset/flutter_realtime_live_preset.dart';

final realtime = Realtime(
  providers: createMyProviders(),
  backendUrl: myBackendUrl,
  featurePlugins: const [
    ClassroomPreset(),
    LivePreset(),
  ],
);
final connection = await realtime.open(request);
final room = connection.mediaRoom!;
await room.readyFeatures(); // preset availability is safe to inspect
final classroom = room.classroom;       // null without an eligible preset
final live = room.liveInteractions;     // null without an eligible preset
```

The simplified Demo explicitly depends on and registers both plugins. Integrators omitting
`featurePlugins` never instantiate these sessions, even if room metadata says
the backend supports classroom or gifts. The existing `room.classroom` and
`room.liveInteractions` accessors are **extension getters from the corresponding
optional package**, rather than members of `RealtimeRoom` itself. This keeps
generic Runtime free of business type imports while allowing existing UI
components to use the same names. The original HTTP
repositories and the existing IM/RTC revision adapters are reused, and each
preset also accepts an optional host-provided `repositoryFactory`. The
Classroom preset is eligible for backend meeting rooms; Live requires the
`liveInteractions` room metadata flag. Applications using direct provider
credentials can explicitly set `enableForDirectRooms: true` and inject a
trusted `repositoryFactory` for either feature. Disabled/ineligible presets do not
allocate repositories. The feature registry handles teardown even if a
plugin fails or finishes attaching after the room has been disposed.

### Core dependency boundary and remaining acceptance

`flutter_realtime_sdk_runtime/pubspec.yaml` now keeps business-specific
`classroom_core`, `live_core`, `whiteboard_core` and
`screen_annotation` out of its production dependencies. Its development
tests may still import the optional presets and those cores as dev
dependencies. `flutter_realtime_sdk` also does not declare a runtime
dependency on the presets. Optional `flutter_realtime_sdk_ui` currently
depends on both presets because it supplies both domain component sets;
further UI-only splitting remains a separate planned refinement.

**Still to verify:** real dual-client delivery and state recovery across each
provider/platform, complete Demo widget E2E and cross-platform build checks.
The current unrelated Media UI worktree contains unresolved references to
`RealtimeUiTokens` / `RealtimeStrings` and must be reconciled before those
widget/build tests can be accepted. Product Chat is *not* a general
authenticated interaction event transport here: it carries revision hints,
while transient events stay RTC-Data-only until an identity-aware IM adapter
is available.

### Existing worktree

At plan start, the worktree already contains unrelated uncommitted Demo,
Pre-Join, Chat and UI edits, plus classroom notification overlay work. Keep
those changes intact; do not reset, overwrite or mix into refactor commits.
