# flutter_realtime_media_ui

Provider-neutral media presentation components. This package depends on Media
Core, the shared design system and Flutter; it does not depend on Runtime,
Product Chat or a provider implementation.

Use `flutter_realtime_sdk_ui` for the standard complete pages shown in the
Demo: `RealtimeRoomView`, `RealtimeChatPage` and `RealtimePreJoinPage`.
The media package contains no alternate full-page templates.

## Components

- `MediaParticipantTile`, `MediaParticipantBuilder`: media tiles and custom
  renderer composition, including contained screen/camera geometry.
- `RealtimePreJoinController`, `RealtimePreJoinScope`: preview ownership,
  permission checks, device choices, media settings and retry state.
- `RealtimePreJoinPreview`, `RealtimePreJoinCheckList`,
  `RealtimePreJoinReadinessCard`, `RealtimePreJoinMediaControls`,
  `RealtimePreJoinDevicePicker`, `RealtimePreJoinBackgroundSelector`,
  `RealtimePreJoinJoinButton`: independently placeable preparation controls.
- `BackgroundEffectSelector`, `MediaBackgroundImagePreset`: image/blur
  presentation without provider branches.
- `RealtimeStrings`, `RealtimeUiTheme`, `RealtimeStyle`: localization and the
  shared design system.

A host composing these controls owns and initializes its
`RealtimePreJoinController`, then closes/disposes it when the UI is removed.
The complete SDK Pre-Join page does this automatically. Preview releases
before `onEnter`; failure restores recoverable settings for retry. Camera and
microphone start disabled. Enumeration and background selection do not imply
permission to start capture.

Initial media settings are applied before publishing and respect current
room and classroom permissions. Unsupported background processing must never
silently fall back to publishing unprotected camera frames.

See [SDK integration](../../doc/APP_INTEGRATION_QUICKSTART.zh-CN.md),
[Pre-Join host setup](../flutter_realtime_media_core/PRE_JOIN_SETUP.md), and
[UI acceptance](../../doc/REALTIME_DESIGN_SYSTEM.md).
