# flutter_realtime_media_agora

Agora adapter for flutter_realtime_media_core.

Supported client platforms in this adapter are Android, iOS, and macOS.
macOS uses Agora's native desktop bridge for join/leave, microphone, camera,
video rendering, subscriptions, and RTC data messages. Front/back camera
switching remains mobile-only because Agora exposes that API on Android/iOS.

The application backend owns the Agora App Certificate and returns a short-lived
AccessToken2 join payload. Flutter receives only the App ID, channel name,
numeric UID, and token.

Numeric UIDs are restricted to the positive signed 32-bit range
`1..2147483647` to match the AccessToken2/native SDK contract across Android,
iOS, Dart, and Node.

Supported roles:

- participant: publish/subscribe audio and video, RTC data stream messages.
- host: publish/subscribe audio and video, RTC data stream messages.
- viewer: subscribe only. RTC data sending is intentionally disabled because
  Agora live-audience data streams can promote a viewer to broadcaster.

Screen sharing and explicit desktop audio-device selection are intentionally
deferred in the current SDK roadmap.

## Android build note

`agora_rtc_engine 6.6.4` and its `iris_method_channel` bridge still declare
Android `compileSdk 31` internally, while their current AndroidX dependencies
require API 34 or newer. The repository example keeps the application
`minSdk`/`targetSdk` unchanged and scopes a Gradle `compileSdk 37`
override to those two third-party subprojects in
`example/android/build.gradle`.

Applications that encounter the same AAR metadata error need an equivalent
scoped override until the upstream packages raise their own compile SDK.

See [`../../doc/ACCEPTANCE.md`](../../doc/ACCEPTANCE.md) for the optional real-service
device test flow.
