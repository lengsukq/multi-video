# flutter_realtime_sdk_ui

Optional provider-neutral Flutter pages and independently composable widgets.
The repository Demo displays these same SDK pages. This monorepo package is
not published separately; the combined `flutter_realtime_sdk` preview bundles
its public UI exports into the single SDK import.

## Standard pages

```dart
import 'package:flutter_realtime_sdk_ui/flutter_realtime_sdk_ui.dart';

MaterialApp(
  theme: RealtimeUiTheme.light(),
  supportedLocales: RealtimeStrings.supportedLocales,
  localizationsDelegates: RealtimeStrings.localizationsDelegates,
  home: RealtimeRoomView(
    room: room,
    config: RealtimeRoomViewConfig(initialMediaSettings: settings),
    onLeave: navigateHome,
  ),
);
```

- `RealtimeRoomView` selects `RealtimeMeetingPage` or `RealtimeLivePage` using
  authoritative backend mode. `config.roomMode` is only a fallback hint.
- `RealtimeChatPage(chatRoom: chatRoom)` supplies the standalone chat page.
- `RealtimePreJoinPage` owns its preview controller. Supply `runCheck`,
  `openPreview`, `roomLabel`, `displayName` and `onEnter`; `RealtimePreJoinEnter`
  runs after preview release. Failed connection attempts remain on the page.

The SDK maintains one standard set of complete pages. Removed historical
pages and compatibility templates have no aliases or deprecated exports.
Apps own room creation, routes and connection disposal. Unmounting room or
chat UI releases UI resources without disconnecting the underlying session.
The explicit leave action leaves/closes the room before invoking navigation.

## Meeting presentations

Screen sharing and whiteboards keep a participant strip below the shared
content, including the local camera or avatar. Select a participant to focus
their camera; the shared content becomes a live, read-only thumbnail. Select
it or use **Return to shared content** to restore the presentation.

**Hide thumbnails / Show thumbnails** affects only this room's local layout.
It preserves the focused content and never starts/stops capture or changes
another participant's view. New presentations start focused on shared content;
ending a presentation restores the previous camera layout. Standalone hosts
can control `RealtimeMeetingStage.showFilmstrip` themselves.

## Customization

`RealtimeRoomViewConfig` configures chat/provider visibility, RTC Data debug,
leave confirmation, initial media settings, image presets and fallback mode.
`RealtimeRoomView` also accepts `header`, `participantBuilder`,
`loadImagePresets`, `onCustomReaction`, `stageOverlayBuilder`, and optional
Classroom/Live/annotation visibility. Backend permissions remain authoritative.
Images and custom transient events are application content; the Demo injects
its locally bundled background pictures and wave event through these hooks.

Use `RealtimeRoomUiScope` to arrange independent widgets in your own layout:

```dart
RealtimeRoomUiScope(
  room: room,
  child: Scaffold(
    body: Column(
      children: [
        const Expanded(child: RealtimeVideoGrid()),
        Row(children: [
          const RealtimeMicrophoneButton(),
          const RealtimeCameraButton(),
          RealtimeLeaveButton(onLeft: navigateHome),
        ]),
      ],
    ),
  ),
);
```

The scope shares pending actions, media/chat subscriptions and capability
checks. Its controller owns UI resources only. An injected controller remains
owned by its caller. `RealtimeManagedParticipantList` uses Runtime's logical
RTC + IM member directory; `RealtimeParticipantList` is RTC-only presence.

### Navigator overlays and Scope lifetime (unreleased source API)

`RealtimeRoomUiScope.of(context)` requires a context **below** the scope.
Calling it from the same page State that creates the scope, or from an ordinary
`showDialog`/`showModalBottomSheet` builder, can throw the Scope assertion.
Capture the controller inside a descendant `Builder` and pass it to the
SDK overlay helper:

```dart
RealtimeRoomUiScope(
  room: room,
  child: Builder(
    builder: (roomContext) {
      final controller = RealtimeRoomUiScope.of(roomContext);
      return TextButton(
        onPressed: () => showRealtimeRoomUiBottomSheet<void>(
          roomContext,
          controller: controller,
          builder: (sheetContext) => RealtimeMediaDevicePicker(
            kind: MediaDeviceKind.microphone,
          ),
        ),
        child: const Text('Microphones'),
      );
    },
  ),
);
```

`showRealtimeRoomUiDialog` uses the same `controller` and `builder`
pattern for dialogs. Both helpers **borrow** the controller without disposing
it. Close transient sheets/dialogs before destroying their room. Do not create
a new independent room UI controller for every overlay.

**Release boundary:** These helpers and the recent Scope/leave fixes are in
the SDK working source **only**, not in the previously published dev.10
single-package artifact. The maintainer publishes the next SDK version
manually; external apps can upgrade and test only after publication.
See the [room UI lifecycle guide](../../doc/ROOM_UI_LIFECYCLE.zh-CN.md).

### Leave and resource ownership

- A `RealtimeRoomUiScope` without an injected controller owns the *UI
  controller*, not the underlying media room. Unmounting a page only releases
  its UI state.
- An injected controller belongs to the caller: close it on final teardown,
  not when temporarily hiding a drawer or switching between layouts.
- `RealtimeLeaveButton` awaits `controller.leave(...)` before invoking
  `onLeft`. Cancellation does not leave. `closeForEveryone: false` requests
  local leave only; `null` follows SDK's role/capability default. The trusted
  backend remains the authority for end-room operations.
- `RealtimeConnection.dispose()` is connection-level cleanup. Popping a
  route/unmounting room widgets does **not** disconnect the underlying session.
  Do not navigate on an unawaited leave result.

## Optional capabilities

Classroom, Live and shared content require explicit feature-plugin
registration and trusted backend state. Runtime starts/disposes registered
sessions. UI widgets never confer privileges or infer permissions from an RTC
message. The standard pages reuse `RealtimeClassroomPanel`, shared-content
stages, media actions and chat components; custom layouts can place these
widgets independently.

`RealtimeRecordingButton`, `RealtimeRecordingBadge`,
`showRealtimeRecordingLayoutPicker` and `RealtimeRecordingResultDialog` use
an injected cloud executor and backend-reported layouts. Meeting and Live
share the same recording flow. Result polling ends on unmount; download is
available only after authoritative completion.

Background controls use `showRealtimeBackgroundEffectsSheet` and
`RealtimeRoomUiController.setBackgroundEffect`. Real processing requires an
explicit effects service, for example
`RealtimeRoomServices(videoEffectsFactory: DefaultRealtimeVideoEffects.new)`.
The Demo registers it. Unsupported publisher/provider/platform combinations
explain unavailability; viewers do not receive camera background controls.
Headless camera controls should call `room.setCameraEnabled` so publication
stays coordinated with background processing.

## Small component packages

- `flutter_realtime_chat_ui`: Chat Core + Flutter widgets; no RTC or Media UI.
- `flutter_realtime_media_ui`: media tiles, Pre-Join controls and presentation.
- `flutter_realtime_room_ui`: room-bound media components and UI controller.
- `flutter_realtime_sdk_ui`: complete pages and optional feature composition.

Do not import another package's `src/` implementation. Widget tests and local
previews are separate from real-provider, physical-device, remote-pixel and
release-build acceptance. See [UI architecture and acceptance](../../doc/UI_COMPOSABILITY_ACCEPTANCE.zh-CN.md).
