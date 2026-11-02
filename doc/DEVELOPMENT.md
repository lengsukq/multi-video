# Development notes

## Repository checkout name on iOS

The pub package is named `flutter_aws_chime`, while this GitHub repository is
named `multi-video`. Flutter 3.47.x has a Swift Package
Manager issue for local path plugins when the plugin checkout directory name
differs from the Dart package name. Flutter merged the upstream fix on
August 14, 2026, but that change landed after the Flutter 3.47 branch cutoff
and is not present in the current 3.47 stable line.

For local iOS SwiftPM development, clone the repository into a directory named
`flutter_aws_chime`:

```bash
git clone https://github.com/lengsukq/multi-video.git flutter_aws_chime
cd flutter_aws_chime
```

This limitation affects the repository's own local `example/` path dependency.
Apps that consume a published package are resolved into a package directory
with the correct package identity and are not affected by this checkout-name
workaround.

The CI workflow intentionally checks out the repository as `flutter_aws_chime`
so the SwiftPM build validates the supported consumer layout.

Upstream issue/fix: <https://github.com/flutter/flutter/issues/186881> and
<https://github.com/flutter/flutter/pull/188647>.

## iOS dependency managers

The plugin supports both:

- Swift Package Manager through `ios/flutter_aws_chime/Package.swift`;
- CocoaPods through `ios/flutter_aws_chime.podspec`.

Both dependency managers compile the same Swift source tree under
`ios/flutter_aws_chime/Sources/flutter_aws_chime`.

The full Demo enables SwiftPM by default so the iOS IVS Media/Chat plugins work
with a standard iOS Flutter command. From the `example` directory, use:

```sh
flutter run -d iPhone
flutter build ios --release --no-codesign
```

For a first checkout that needs local `FlutterFramework` SwiftPM shims, the
repository also provides a bootstrap helper (run from the repository root):

```sh
python3 scripts/flutter_ios.py build ios --release --no-codesign
python3 scripts/flutter_ios.py run -d <ios-device-id>
```

This optional helper resolves Dart dependencies from the local cache and
prepares missing iOS SwiftPM Flutter framework shims after a fresh checkout.
It never rewrites `pubspec.yaml` or global Flutter settings. Both iOS and
macOS run directly from `example/` with SwiftPM enabled. Avoid building
both Apple platforms simultaneously because they share generated plugin files.

## Real-device media verification

See [`DEVICE_E2E.md`](DEVICE_E2E.md) for the opt-in physical-device workflow.

## macOS validation

Both Apple platforms now use the **same** `example/` Flutter application.
All eight in-repository macOS native plugin packages previously limited to
CocoaPods have been migrated to SwiftPM. CocoaPods podspecs reuse those native
source trees; no duplicate Dart UI, providers, SDK packages or app hosts exist.

```sh
cd example
flutter run -d macos
flutter run -d iPhone
```

The app-wide SwiftPM toggle remains enabled. Vendor
`tencent_cloud_chat_sdk` and `tencent_rtc_sdk` still do not ship macOS
SwiftPM manifests, so Flutter 3.47 uses its CocoaPods fallback for those two
plugins. This is not a claim that all third-party code is SPM-only. We retain
the CocoaPods Podfile and source-compatible local plugin podspecs.
Local Agora Chat and AWS WebKit plugin resources are bundled via
`Bundle.module` on SwiftPM and CocoaPods resource bundles otherwise.

The same-app macOS Debug build and `flutter run` have passed on macOS 27,
including startup and an active Dart VM Service. They do not prove full
provider end-to-end meeting, recording, background, or screen sharing tests.
Agora's binary frameworks may log duplicate Objective-C classes between
AgoraRtcKit and AgoraScreenCaptureExtension; track this separately before
declaring release readiness.

The legacy macOS .command entrypoints remain available for release and IDE
compatibility, but now call the same standard Flutter SwiftPM commands
without temporarily editing `pubspec.yaml` or Xcode Runner. From the
repository root:

```sh
./run_macos_debug.command
./build_macos_arm64.command
```

For normal debug use the `example/` commands above. They support Flutter
hot reload (`r`), hot restart (`R`) and quit (`q`) without toggling the
manifest. Full installed-DMG/signing QA still requires validation.

### Validate desktop provider runtime assets

After building the Demo on macOS, check that all provider JS entrypoints are
included in the native Flutter asset bundle:

```sh
python3 scripts/check_macos_provider_assets.py --configuration Debug
python3 scripts/check_macos_provider_assets.py --configuration Release
python3 -m unittest discover -s scripts/tests
```

The arm64 DMG packager runs the Release asset check automatically **before**
creating or installing the app. Native AWS WebKit loads Chime/IVS JavaScript
from `flutter_realtime_provider_aws`, the shared media bridge from
`flutter_realtime_media_web`, and IVS Chat from
`flutter_realtime_provider_ivs_chat`. The core `flutter_realtime_sdk` package
does not bundle these optional provider scripts. Do not hardcode the old
`flutter_realtime_sdk/assets/provider_web_runtime` path in native plugins.

## Apple Silicon release installer and Applications installation

Use an **Apple Silicon Mac** with Flutter, Xcode, CocoaPods, and the Demo's Dart
dependencies installed. On first checkout, resolve packages from `example/`:

```sh
cd example
flutter pub get
cd ..
```

From the **repository root**, run:

```sh
./build_macos_arm64.command
./build_macos_arm64.command --skip-build
```

Or double-click `build_macos_arm64.command` in Finder. It automatically builds
the Demo, creates the DMG, installs/replaces the same application in
`/Applications`, and opens it. If necessary, enable execution once with
`chmod +x build_macos_arm64.command`. The shell entry point invokes the internal
Python packaging utility; you do not need to run a `.py` file yourself.

The DMG tool invokes `scripts/build_flutter_macos.py --release --no-pub`
as a compatibility entrypoint, which now simply delegates to standard
`flutter build macos --release --no-pub` using the same SwiftPM setup as
direct development. It no longer changes Flutter's manifest or removes
macOS native SPM Xcode references. The SwiftPM Release command has built
`multi-video.app` successfully. The DMG packager independently verifies arm64
and creates the archive under `dist/macos/`; the full installed-DMG
workflow still requires user-device acceptance testing.
The DMG contains the `.app` and an `Applications` shortcut for drag-and-drop.
The default `.command` invocation copies the `.app` into `/Applications` and
replaces existing installations of the same application. Replacement is refused for a
different bundle identifier or symlink and stages the new app before swapping
it into place. Close the previous Demo app before replacing it.

The command launches the installed app; `--skip-build` packages the latest
existing Release artifact without rebuilding. If `/Applications` is not writable
for your account, either use the DMG's drag-and-drop install in Finder (macOS
will request authorization if necessary) or pass
`./build_macos_arm64.command --applications-dir ~/Applications` after creating
that directory.
Do not run the Flutter build itself with `sudo`.

### macOS build lock troubleshooting

The one-click packager holds an advisory lock at
`example/.dart_tool/macos-arm64-package.lock` for its full build/package/install
run. Starting another `.command` while the first is active exits with the
current packager PID instead of letting two builds contend for Xcode's
`XCBuildData/build.db`. The lock is automatically released on normal exit,
failure, or process termination; **do not delete the lock file** (it is
deliberately persistent to avoid races). `--skip-build` also takes this lock
to avoid two installers replacing the same `.app` simultaneously.

Before compiling, the script checks for external builders currently holding
`example/build/macos/Build/Intermediates.noindex/XCBuildData/build.db` via
`lsof` and reports the process names/PIDs. It never kills processes or clears
build files automatically. To diagnose an unexpected `database is locked`
error, stop or wait for the other Flutter/Xcode build first. Once **all**
builds have exited, you may remove only the generated `XCBuildData` directory
and retry; it is unsafe to remove it while Xcode still holds it open. The
`iris_method_channel` / `RealtimeNativeFrameSinks` module resolution errors
are unrelated Swift Package Manager/CocoaPods integration problems and will
not be fixed by deleting `build.db`.

This is a **development DMG**, not a signed/notarized public distribution.
macOS Gatekeeper may require additional approval on other machines. Build
validation proves the main executable supports arm64; it does not replace
device-level tests of bundled media plugins, microphone/camera permissions,
or backend connectivity.
