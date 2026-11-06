# Flutter Realtime SDK

**English** · [简体中文](README.zh-CN.md)

One Flutter package for provider-neutral meetings, live streams, chat, optional
UI, and classroom/live interaction presets. Media and product chat providers
can be selected independently through explicit runtime registration.

**Release: `@VERSION@` (preview).** Windows/Linux builds, physical-device vendor
calls, long-running sessions, and cross-vendor coexistence are not yet fully
verified. Platform registration does not imply every provider supports that
platform. See the [capability matrix](https://github.com/lengsukq/multi-video/blob/main/doc/SDK_CAPABILITY_MATRIX.zh-CN.md).

## Installation

Requires Flutter 3.47 or later and Dart 3.12 or later. The combined native
package requires Android API 28+, iOS 15+, and macOS 12+.

Add:

```yaml
dependencies:
  flutter_realtime_sdk: ^@VERSION@
```

All SDK APIs below use the same public import:

```dart
import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';

final realtime = Realtime(
  backendUrl: 'https://your-backend.example',
  providers: [createLivekitProvider()],
  services: const RealtimeRoomServices(
    videoEffectsFactory: DefaultRealtimeVideoEffects.new,
  ),
  featurePlugins: const [
    ClassroomPreset(),
    SharedContentPreset(),
    LivePreset(),
  ],
);

final connection = await realtime.open(
  RealtimeRequest.join(
    type: RealtimeExperience.meeting,
    roomCode: '123456',
    user: const RealtimeUser(id: 'user-1', name: 'Alice'),
  ),
);
final room = connection.mediaRoom!;
// Optional UI: RealtimeRoomView(room: room).
// In the application's leave/logout flow: await connection.dispose();
```

### Built-in UI

The Demo displays these SDK pages directly: `RealtimeRoomView` (selects the
meeting/live page from the room), `RealtimeMeetingPage`, `RealtimeLivePage`,
`RealtimeChatPage`, and `RealtimePreJoinPage`. Customize room presentation
with `RealtimeRoomViewConfig`; pre-join uses `RealtimePreJoinEnter` and starts
with the microphone and camera off. The host owns navigation and explicitly
disposes its connection when leaving.

This preview removes the older `MediaRoomView`, `MediaPreJoinPage`,
`RealtimeChatView`, `RealtimeComposableRoomTemplate`,
`RealtimeComposablePreJoinTemplate`, and `ChatDefaultPage` APIs.
Replace `MediaRoomViewConfig` with `RealtimeRoomViewConfig` when upgrading.
Reusable controls and Headless APIs remain available.

### Custom room UI: Scope, modal routes, and leaving

`RealtimeRoomUiScope.of(context)` requires a `BuildContext` **below**
`RealtimeRoomUiScope`. The owning page State's `context` is above the
Scope, so it cannot look up the controller. Dialogs and bottom sheets build
under the Navigator's Overlay and do not inherit a room page's Scope
automatically. Capture the controller from a descendant `Builder` and use
the SDK helpers rather than creating another room controller per modal:

```dart
RealtimeRoomUiScope(
  room: room,
  child: Builder(
    builder: (roomContext) {
      final controller = RealtimeRoomUiScope.of(roomContext);
      return Column(
        children: [
          TextButton(
            onPressed: () => showRealtimeRoomUiBottomSheet<void>(
              roomContext,
              controller: controller,
              builder: (_) => RealtimeMediaDevicePicker(
                kind: MediaDeviceKind.microphone,
              ),
            ),
            child: const Text('Devices'),
          ),
          RealtimeLeaveButton(
            closeForEveryone: false,
            onLeft: () {
              if (roomContext.mounted) Navigator.of(roomContext).maybePop();
            },
          ),
        ],
      );
    },
  ),
);
```

`showRealtimeRoomUiDialog` follows the same controller/builder pattern.
Both helpers borrow the controller; neither disposes the room. Close modal
routes before disposing their room. Widget unmount, `Navigator.pop()`,
`controller.close()`, `controller.leave()` and
`RealtimeConnection.dispose()` are **different operations**: UI-only
teardown never means an RTC leave. The SDK's leave button awaits the actual
leave/room cleanup before invoking `onLeft`. Host end-for-everyone also
depends on role, backend capability and cloud-recording state; server-side
authorization remains authoritative.

For the exact behavior and edge cases see the
[room UI lifetime guide](https://github.com/lengsukq/multi-video/blob/main/doc/REALTIME_DESIGN_SYSTEM.md).

Meeting presentations keep participant thumbnails below the shared screen or
whiteboard. Select a person to focus their camera and show a live, read-only
content preview; select that preview or **Return to shared content** to switch
back. **Hide thumbnails / Show thumbnails** affects only your current room's
local layout. It never starts/stops capture or changes another participant's
view. Standalone layouts can use `RealtimeMeetingParticipantStrip` and
`RealtimeMeetingStage.showFilmstrip`.

### Headless virtual backgrounds and camera publication

If your app offers background effects, enable `videoEffectsFactory` as above.
Use `room.setCameraEnabled` rather than calling
`room.media.session.setVideoEnabled` directly. The SDK synchronizes camera
publication with its processed-video source and serializes it with
`setBackgroundEffect`, even if the camera was initially off.

```dart
// Camera is off; the selected effect remains prepared, but not capturing.
await room.setBackgroundEffect(const MediaBackgroundEffect.blur());

// Starts the already attached processed source before publishing the camera.
await room.setCameraEnabled(true);

// Change effects and close the camera in any sequence.
await room.setBackgroundEffect(const MediaBackgroundEffect.none());
await room.setCameraEnabled(false);
```

Only call the effect operations when `room.backgroundCapabilities` reports
support. Blur/image replacement depends on the platform, provider, and host
camera permissions. If effects initialization fails, handle the exception and
do not silently publish unprocessed video as a fallback.

Effect selection waits for the first usable processed frame on Web. Handle
`RealtimeException` from camera/effect operations. Processing can also fail
later (for example, after losing the GPU context): subscribe to `room.events`
for `RealtimeBackendFailure` and inspect `event.error`. The SDK stops failed
publication; an explicit successful effect reset is required before retrying
the camera. `room.diagnostics` retains recent failures even without a listener.
Use `code`, `domain`, `operation`, and `suggestedAction` for application behavior;
retain `cause`, `details`, and `stackTrace` in private diagnostic logs. The public
message intentionally excludes raw provider payloads and credentials.

Before a room is returned, `await realtime.open(request)` throws failures to
the host application; room widgets have not mounted yet. Retain the exception
in application state, display `RealtimeStrings.of(context).displayRealtimeError(error)`
inline, and let the user repeat the original request. A transient SnackBar alone
can be missed. After entry, the built-in pages also present asynchronous room
and media failures through their existing error callback.

Built-in Meeting/Live preparation has a 15-second limit per media/shared-content
stage; the browser media join has a 20-second deadline followed by bounded
cleanup. The network still needs to reach the selected provider's endpoints.
Media and effects bridges expose independent protocol versions. Incompatible
assets fail early with `webBridge.versionMismatch` and the
`reload-web-runtime` action. Fully restart/rebuild the host after an SDK upgrade;
old compiled Dart cannot acquire a new runtime check through hot reload.

Provide a backend implementing the provisioning/control contracts, or use
`RealtimeSource.credentials(...)` with your own short-lived credential service.
The repository's Demo Server is a reference implementation. Never include
vendor secrets or cloud access keys in a client application. Classroom/live
presets require trusted backend state and permission enforcement.

## iOS setup

### Entire-screen sharing across iPhone apps (iOS 27+)

Use the provider-neutral `setScreenShareEnabled(true/false)`. On **iOS 27+**,
LiveKit, Agora, TRTC, ARTC, AWS Chime and Amazon IVS use a shared native ScreenCaptureKit
`SCContentSharingPicker` / `SCStream` video source with provider-specific
publishing sinks. Choose the **entire display** in the system picker to keep
capturing after opening Safari or other apps. No Broadcast Upload Extension
or App Group is required on this path, but the iPhone host app must be signed.
Add these keys to the host app's `Info.plist`:

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Share the entire iPhone screen during a meeting</string>
<key>UIBackgroundModes</key>
<array>
  <string>screen-capture</string>
  <string>audio</string>
</array>
```

The `screen-capture` background mode keeps full-display capture alive when
the app is not frontmost; `audio` is for meetings that keep the microphone
active in the background. Compile success is not a substitute for a physical
two-device validation of the incoming stream, picker cancellation and stop.

Chime publishes an independent Content Share. Amazon IVS uses its single
Stage video stream to publish the screen **instead of** the camera, restoring
the camera on stop. Simultaneous camera and screen video on IVS requires a
second Stage token/participant and is not implemented here. Remote IVS
screen-vs-camera classification still needs trusted signalling and real-device
acceptance.

### iOS 15–26: LiveKit ReplayKit fallback

LiveKit defaults to `IosScreenShareMode.system` and falls back to the
**ReplayKit Broadcast Upload Extension** on older iOS releases. This requires
the same **App Group entitlement** on the main app and extension; the Flutter
plugin cannot register Apple Developer signing capabilities for the host.
This older-OS fallback is implemented only for LiveKit. The extension-free
Agora, TRTC, ARTC, Chime and IVS capture paths require iOS 27+.

Once the package is resolved by `flutter pub get`, run this installer from
your Flutter host root (or supply a different path to your hosted pub cache):

```bash
ruby "$HOME/.pub-cache/hosted/pub.dev/flutter_realtime_sdk-@VERSION@/tool/setup_ios_broadcast_extension.rb" ios
```

It adds an `BroadcastUpload.appex` Xcode target, copies the ReplayKit sample
handler and socket transport, configures `RTCAppGroupIdentifier` /
`RTCScreenSharingExtension`, and creates entitlements for both targets.
It does **not** register App IDs or provision a signing account.
Before building, register the explicit main-app and extension Bundle IDs with
your Apple Developer team, enable App Groups on **both** IDs, register/assign
the shared group, and refresh both provisioning profiles in Xcode.
Replace `com.example.*` Bundle IDs with identifiers belonging to your
organization if the sample app still uses Flutter's defaults.

On the ReplayKit fallback, the SDK verifies the embedded extension and App Group container
before opening Apple's broadcast picker. The user must explicitly tap
**Start Broadcast**. Only a real `screenShareVideo` publication is treated
as success; a dismissed picker, missing track or session teardown fails
without committing shared-content mode. Stopping or leaving requests the
broadcast to end. Validate that remote video keeps moving while the iPhone
is in another app; build success alone is not sufficient.

Apps that intentionally need **in-app-only** sharing can create
`LiveKitInteractiveSession(iosScreenShareMode: IosScreenShareMode.application)`.
That mode does not capture Safari, notifications or other applications.
This ReplayKit integration does not guarantee system audio sharing.

Use iOS 15+. This preview bundles the native providers into a single
CocoaPods plugin and currently needs a **CocoaPods-only iOS host**.
Flutter's SwiftPM resolution skips Agora RTC's local CocoaPods plugin, while
the umbrella Podspec still requires it. Until the aggregate plugin has a
fully compatible SwiftPM target, disable SwiftPM **for this host project only**:

```yaml
# Host Flutter pubspec.yaml
flutter:
  config:
    enable-swift-package-manager: false
```

This is a preview-build compatibility constraint, not a recommendation to
disable SwiftPM for every Flutter app. A future Flutter release may remove
this migration option.

IVS Broadcast 1.47.0 and IVS Chat 1.0.1 are fetched from AWS's official HTTPS
archives at `pod install` time and checked against the SHA-256 values in
`ios/vendor_frameworks.json`. Vendor binaries are **not** redistributed in
the Pub archive. The installer reuses compatible local SwiftPM archives;
a fresh installation needs access to the official AWS endpoints. A corrupt
archive fails installation instead of silently selecting another SDK version.

Set `platform :ios, '15.0'` in `ios/Podfile`. Add this hook **before** the
existing `post_install` hook (or merge its body into your existing
`pre_install`). It resolves the Agora RTC/Chat duplicate
`aosl.xcframework` by retaining the newer infrastructure Pod's vendored
framework declaration:

```ruby
pre_install do |installer|
  require_relative '.symlinks/plugins/flutter_realtime_sdk/ios/podfile'
  FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer)
end
```

The helper changes only the in-memory CocoaPods specification; it does
**not** remove official frameworks or modify the global CocoaPods cache.
The single-package build also exports only Objective-C plugin headers,
keeping private Agora C++ headers out of the generated Swift umbrella module.
If you intentionally enable a mixed SwiftPM/CocoaPods setup, the separate
`deduplicate_agora_frameworks!` post-integration helper remains available,
but this preview's mixed build is not supported.
Actual Agora RTC/Chat behavior still requires real-device testing.
ARTC's current framework is device-only; this combined package does not
support the iOS Simulator.

### Isolating conflicting iOS WebRTC vendor binaries

Bundling LiveKit's WebRTC framework, Amazon Chime Media and AliVCSDK_ARTC
may produce duplicate Objective-C `RTC*` classes. This is a real runtime
compatibility risk, not just a console warning. Do not strip or rename
official vendor binaries.

To ship an iOS host using LiveKit, Agora, TRTC and IVS **without** Chime or
ARTC native binaries, add these lines at the very beginning of the
application's `ios/Podfile` (before Flutter installs the Pods):

```ruby
ENV['FRSDK_IOS_DISABLE_CHIME'] = '1'
ENV['FRSDK_IOS_DISABLE_ARTC'] = '1'
```

Run `cd ios && pod install` after changing these settings. The bundled
Podspec then excludes those Swift plugin sources and CocoaPods dependencies,
and Swift plugin registration skips their classes. **Chime and ARTC will no
longer work on iOS in that host**; neither Android nor Web is affected.
Hosts requiring Chime or ARTC should use distinct iOS build variants and
validate other loaded WebRTC vendors separately. The default build retains
all providers for backwards compatibility and is **not** proof that their
Objective-C runtimes safely coexist. Keep flags consistent across all
configurations.

For controlled/offline builds, set `FLUTTER_REALTIME_SDK_IOS_OFFLINE=1`.
Optionally set `FLUTTER_REALTIME_SDK_IOS_ARCHIVE_CACHE` to a directory containing
the two official archives named `<sha256>.zip` using the manifest checksums.
Missing or mismatched archives fail without downloading when offline.

Add camera/microphone usage descriptions and the platform permissions required
by the chosen features. Screen sharing and other OS-specific capabilities
can require additional host configuration.

## Distribution limitations

- Every declared vendor dependency is resolved even if only one provider is
  registered; native size and build cost are not eliminated by Dart tree shaking.
- Web supports the normal JavaScript build; Wasm is not verified/supported by
  the current complete dependency set.
- Windows/Linux and physical-device/media acceptance remain pending.
- Build results do not establish real vendor interoperability or cloud cleanup.
- Third-party components retain their own licenses and service terms; the
  package's MIT license covers the project's own code.

[Source and documentation](https://github.com/lengsukq/multi-video) ·
[中文说明](README.zh-CN.md) ·
[Full Chinese integration guide](https://github.com/lengsukq/multi-video/blob/main/doc/APP_INTEGRATION_QUICKSTART.zh-CN.md)
