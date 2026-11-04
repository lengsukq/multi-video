#!/usr/bin/env python3
"""Stage an unpublished preview package without vendor binaries or local state.

Does not resolve dependencies, download, commit, push, or publish. Run the
normal pub dry-run in the staged directory before deciding to publish.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def _render_readmes(destination: Path, version: str, root: Path) -> None:
    """Stage the English default README and its complete Chinese companion."""
    templates = root / "scripts/templates"
    for filename in ("README.md", "README.zh-CN.md"):
        template_name = f"single_sdk_{filename}"
        content = (templates / template_name).read_text(encoding="utf-8")
        (destination / filename).write_text(
            content.replace("@VERSION@", version), encoding="utf-8"
        )


def _inventory_file(path: Path, destination: Path) -> bool:
    """Track release source, never resolution or native build artifacts.

    The SDK's podspec downloads pinned IVS binaries into ios/Frameworks during
    pod install, but .pubignore excludes that directory from publication.
    Building a staged package must not make its immutable source inventory
    appear modified or accidentally add third-party binaries to that inventory.
    """
    relative = path.relative_to(destination)
    return (
        path.is_file()
        and not ({".git", ".dart_tool"} & set(relative.parts))
        and relative.parts[:2] != ("ios", "Frameworks")
        and path.name
        not in {"pubspec.lock", ".flutter-plugins", ".flutter-plugins-dependencies"}
    )


def _write_inventory(destination: Path) -> int:
    files = {str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
             for path in sorted(destination.rglob("*"))
             if _inventory_file(path, destination)}
    (destination.parent / "FILES.sha256.json").write_text(json.dumps(files, indent=2) + "\n")
    return len(files)


def verify_staged(version: str, root: Path = ROOT) -> Path:
    """Verify the original staged artifact before resuming a canceled publish.

    Dependency resolution may create .dart_tool / pubspec.lock, which are not
    part of the release. All publishable source files must still match their
    assembly-time hashes. Never silently rebuild or overwrite a staged build.
    """
    if not re.fullmatch(r"0\.1\.0-dev\.[1-9][0-9]*", version):
        raise ValueError("Expected an explicit preview version: 0.1.0-dev.N")
    parent = root / "build/pub_release" / version
    destination = parent / "flutter_realtime_sdk"
    manifest_path = parent / "FILES.sha256.json"
    metadata_path = parent / "PREPARATION.json"
    if not destination.is_dir() or not manifest_path.is_file() or not metadata_path.is_file():
        raise FileNotFoundError(f"Missing staged release or inventory: {parent}")

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    if (metadata.get("package"), metadata.get("version"), metadata.get("published")) != (
        "flutter_realtime_sdk", version, False
    ):
        raise ValueError("Staged version, package, or publishing status is invalid")

    pubspec = (destination / "pubspec.yaml").read_text(encoding="utf-8")
    if not re.search(rf"(?m)^version:\s*{re.escape(version)}\s*$", pubspec):
        raise ValueError(f"Staged pubspec version does not match {version}")
    if re.search(r"(?m)^publish_to:\s*none\s*$", pubspec):
        raise ValueError("Staged package is not configured for publication")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or not manifest or metadata.get("fileCount") != len(manifest):
        raise ValueError("Release inventory is invalid")

    current = {
        str(path.relative_to(destination)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in destination.rglob("*")
        if _inventory_file(path, destination)
    }
    if current != manifest:
        changed = sorted(
            name for name in current.keys() | manifest.keys()
            if current.get(name) != manifest.get(name)
        )
        raise ValueError(
            "Staged release has changed since preparation; refusing to publish: "
            + ", ".join(changed[:10])
        )
    return destination


def refresh_readmes(version: str, root: Path = ROOT) -> Path:
    """Refresh *only* docs of an unpublished staged version, not binaries/code."""
    if not re.fullmatch(r"0\.1\.0-dev\.[1-9][0-9]*", version):
        raise ValueError("Expected an explicit preview version: 0.1.0-dev.N")
    destination = root / "build/pub_release" / version / "flutter_realtime_sdk"
    pubspec = destination / "pubspec.yaml"
    if not pubspec.is_file() or f"version: {version}" not in pubspec.read_text():
        raise FileNotFoundError("Expected the matching staged preview package")
    _render_readmes(destination, version, root)
    count = _write_inventory(destination)
    metadata = destination.parent / "PREPARATION.json"
    if metadata.exists():
        data = json.loads(metadata.read_text())
        data["fileCount"] = count
        metadata.write_text(json.dumps(data, indent=2) + "\n")
    return destination


def _dev16_changelog() -> str:
    return (
        "## 0.1.0-dev.16\n\n"
        "- Fix RealtimeRoomUiController lifecycle during room swaps and "
        "unmount: defer disposal until inherited descendants have detached "
        "their ChangeNotifier listeners.\n"
        "- Preserve controllers when an SDK-owned room scope transfers "
        "ownership of the same instance to an external host.\n"
        "- Constrain the responsive meeting/live room header and secondary "
        "rail to a scrollable portion of the viewport so oversized content "
        "cannot overflow the entire mobile stage and dock.\n"
        "- Add regression tests for controller ownership transitions, "
        "room changes, unmounts and extremely tall mobile headers.\n"
        "- Real-device vendor RTC, iOS Simulator, Windows/Linux and "
        "redistribution acceptance are not completed by this release.\n"
    )


def refresh_changelog(version: str, root: Path = ROOT) -> Path:
    """Amend only release notes in an existing verified, unpublished stage.

    Never rebuild staged code or silently accept changes to a frozen artifact.
    The initial dev.16 stage was created before its dedicated notes existed.
    """
    if version != "0.1.0-dev.16":
        raise ValueError("The dedicated changelog refresh is for dev.16 only")
    destination = verify_staged(version, root)
    (destination / "CHANGELOG.md").write_text(
        _dev16_changelog(), encoding="utf-8"
    )
    count = _write_inventory(destination)
    metadata_path = destination.parent / "PREPARATION.json"
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    metadata["fileCount"] = count
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    verify_staged(version, root)
    return destination


def prepare(version: str, root: Path = ROOT) -> Path:
    # Stable releases need a separate acceptance decision. This tool prepares
    # only an explicitly versioned preview, retaining pending evidence as such.
    if not re.fullmatch(r"0\.1\.0-dev\.[1-9][0-9]*", version):
        raise ValueError("Expected an explicit preview version: 0.1.0-dev.N")
    source = root / "build/single_sdk_candidate"
    destination = root / "build/pub_release" / version / "flutter_realtime_sdk"
    if destination.exists():
        raise FileExistsError(f"Release already staged; preserve it or choose a new version: {destination}")
    for required in ("pubspec.yaml", "ios/vendor_frameworks.json", "ios/podfile.rb",
                     "ios/vendor_frameworks.rb", "LICENSE"):
        if not (source / required).is_file():
            raise FileNotFoundError(source / required)

    def ignore(folder, names):
        relative = Path(folder).relative_to(source)
        if relative == Path("."):
            return set(names) & {".git", ".dart_tool", ".flutter-plugins", "pubspec.lock",
                                  ".flutter-plugins-dependencies", "ASSEMBLY_REPORT.json"}
        if relative == Path("tool"):
            # Ship the supported ReplayKit host installer, not internal
            # assembly smoke tests.
            return set(names) & {"single_import_smoke.dart"}
        if relative == Path("ios"):
            return set(names) & {"Frameworks"}
        return set()

    shutil.copytree(source, destination, ignore=ignore)
    pubspec = destination / "pubspec.yaml"
    content = re.sub(r"(?m)^version:.*$", f"version: {version}", pubspec.read_text())
    content = re.sub(r"(?m)^publish_to:.*\n", "", content)
    content = content.replace("Prototype of a single public Flutter Realtime SDK artifact.",
                              "Provider-neutral realtime media, chat, optional UI and interaction presets in one Flutter plugin.")
    pubspec.write_text(content)
    for platform in ("ios", "macos"):
        spec = destination / platform / "flutter_realtime_sdk.podspec"
        spec.write_text(re.sub(r"s\.version = '[^']+'", f"s.version = '{version}'", spec.read_text()))
    _render_readmes(destination, version, root)
    if version == "0.1.0-dev.1":
        notes = (
            "- First single-package preview combining runtime, providers, optional UI and presets.\n"
            "- Resolve iOS IVS from pinned official archives without bundling vendor binaries.\n"
            "- Include an explicit Podfile integration helper for Agora RTC/Chat duplicate framework embeds.\n"
        )
    elif version == "0.1.0-dev.4":
        notes = (
            "- Unify built-in Meeting, Live, Chat and Pre-Join pages with the Demo UI; the Demo now composes the SDK pages.\n"
            "- Include reusable meeting stages, side panels, recording controls and recording results.\n"
            "- BREAKING: remove MediaRoomView, MediaPreJoinPage, RealtimeChatView and legacy composable/default templates. Use RealtimeRoomView, RealtimePreJoinPage and RealtimeChatPage.\n"
            "- BREAKING: replace MediaRoomViewConfig with RealtimeRoomViewConfig and use RealtimePreJoinEnter for the pre-join callback.\n"
            "- Keep pre-join microphone/camera disabled by default and preserve preview cleanup during cancellation, retries and pending entry.\n"
            "- Retain effects-aware RealtimeRoom.setCameraEnabled and the public DefaultRealtimeVideoEffects export for Headless apps.\n"
        )
    elif version == "0.1.0-dev.5":
        notes = (
            "- Keep participant cameras and avatars visible alongside screen sharing and whiteboards in meeting mode.\n"
            "- Switch locally between a participant and shared content; shared previews remain live and read-only.\n"
            "- Add Hide/Show thumbnails and Return to shared content actions; restore the previous camera layout when sharing ends.\n"
            "- Expose RealtimeMeetingParticipantStrip and showFilmstrip controls for custom meeting layouts.\n"
            "- Reserve the dock's actual height during presentations and adapt whiteboard tools to narrow windows and larger text.\n"
            "- Retain the unified SDK pages introduced in dev.4, without restoring removed legacy UI APIs.\n"
        )
    elif version == "0.1.0-dev.6":
        notes = (
            "- Fix Flutter Web virtual backgrounds in the hosted one-package SDK: explicitly declare bundled JS, MediaPipe models, and nested WASM assets.\n"
            "- Rewrite the copied video-effects JavaScript runtime's asset URL to the hosted flutter_realtime_sdk package namespace.\n"
            "- Add release assembly and independent Flutter Web asset-manifest regression checks; host applications no longer need resource-copy workarounds.\n"
            "- Retain the unified SDK Meeting/Live/Chat/Pre-Join pages and Headless camera/effects coordination.\n"
        )
    elif version == "0.1.0-dev.7":
        notes = (
            "- Fix Web camera publication after Pre-Join in Meeting and Live: keep native RTC camera capture when no virtual background is selected.\n"
            "- Create and attach the processed video source only when blur or image replacement is selected; preserve on-demand effects and camera toggle behavior.\n"
            "- Fix shared-content whiteboard mode transitions racing classroom revisions; refresh before commit and retry explicit revision conflicts once.\n"
            "- Show camera and shared-content action errors in SDK Meeting/Live pages instead of failing silently.\n"
            "- Add meeting/live camera and shared-content regression tests; retain the dev.6 Web asset packaging fixes.\n"
        )
    elif version == "0.1.0-dev.8":
        notes = (
            "- Bind Web video directly to Flutter's newly created DOM element; preserve that element when replacing tracks and surface binding failures.\n"
            "- Fix LiveKit Web processed-video controls using the browser source registry instead of an unavailable native MethodChannel.\n"
            "- Remove the previous LiveKit camera publication before replacement, enable the independently owned processed clone, and retain one publication across camera toggles.\n"
            "- Use Agora's native Web camera when no effect is selected; recreate released camera tracks and synchronize processed clone enablement.\n"
            "- Wait for usable video dimensions and the first processed frame; reject initialization/inference failures instead of reporting successful effect changes.\n"
            "- Retain runtime processing failures, reject camera re-enable until effects are reset, and stop failed room publication with typed diagnostics.\n"
            "- Add browser and source-level regressions; real-provider multi-device acceptance remains separate.\n"
        )
    elif version == "0.1.0-dev.9":
        notes = (
            "- Classify Web join network/timeout failures, preserve diagnostic causes, and release failed or pending sessions before retry.\n"
            "- Prevent a late vendor connection or a resolved join promise from overriding an earlier failure.\n"
            "- Bound built-in Meeting/Live media and shared-content preparation; show actionable timeout errors and retain retry behavior without late setting changes.\n"
            "- Fix the Live page retry callback returning a Future from setState.\n"
            "- Forward runtime/media failures through room UI error presentation and localize network, timeout and incompatible-resource guidance.\n"
            "- Validate media/effects Web bridge protocol versions before use while retaining legacy string video attachment compatibility.\n"
            "- Add fault-injection, lifecycle, UI retry and browser regressions; actual provider/network acceptance remains separate.\n"
        )
    elif version == "0.1.0-dev.10":
        notes = (
            "- Add meeting-mode selection and composed local previews while keeping media/session ownership in the SDK.\n"
            "- Add repository-backed shared-content sessions and typed repository/command contracts for shared-content workflows.\n"
            "- Refresh the built-in Meeting, Live, Chat, classroom and whiteboard workspaces with reusable responsive UI, room controls and participant layouts.\n"
            "- Bundle Onest and Bricolage Grotesque fonts in the single-package SDK so the refreshed design system renders consistently for hosted-package consumers.\n"
            "- Add a native macOS pre-join microphone meter using CoreAudio/AVAudioEngine; capture starts only after explicit microphone enablement and stops on mute or navigation.\n"
            "- Surface macOS meter permission/capture errors; the meter reads the system default input and does not prove remote audio delivery.\n"
            "- Add regression coverage for meeting workspaces, pre-join lifecycle, shared-content sessions, local previews and room ownership.\n"
        )
    elif version == "0.1.0-dev.12":
        notes = (
            "- Fix the Flutter Web crash before classroom/whiteboard HTTP actions: "
            "replace invalid 32-bit shifts when generating random event IDs.\n"
            "- Fix the same event-ID generation bug in whiteboard drawing, "
            "RTC interaction revisions, live interactions and annotations.\n"
            "- Preserve the original HTTP status/code on shared-content transition "
            "failures instead of displaying an opaque internal error identifier.\n"
            "- Translate shared-content failures into actionable messages for "
            "expired rooms, missing permissions, revision conflicts and network failures.\n"
            "- Add real Chrome regression coverage for classroom HTTP actions and "
            "SDK shared-content error handling.\n"
            "- Exclude local Python bytecode caches from the one-package "
            "Windows distribution archive.\n"
        )
    elif version == "0.1.0-dev.13":
        notes = (
            "- Make classroom and shared-content preset registration order independent "
            "with typed optional feature dependencies.\n"
            "- Keep whiteboard/shared content usable without registering classroom features.\n"
            "- Fix CI format and generated capability declarations, Web-only platform "
            "tests, macOS native frame feed paths, Windows symlink handling, and "
            "Web bridge npm dependency installation.\n"
            "- Refresh third-party SDK onboarding and plugin examples, with a "
            "public-API compilation regression test.\n"
            "- Preserve the current single-package provider dependency model; "
            "optional vendor pruning remains a future packaging decision.\n"
        )
    elif version == "0.1.0-dev.14":
        notes = (
            "- Fix iOS CocoaPods-only host integration for the single-package SDK: "
            "resolve Agora RTC and Chat against one shared, newer aosl framework "
            "using the bundled pre_install helper.\n"
            "- Export only Objective-C plugin public headers from the combined "
            "iOS Podspec, preventing duplicate Headers and Swift Clang scans "
            "of private Agora C++ implementation headers.\n"
            "- Document iOS host-level SwiftPM opt-out until the aggregated "
            "native plugin supports SwiftPM end-to-end.\n"
            "- Add release tool regression coverage for framework selection "
            "and safe native header exports.\n"
        )
    elif version == "0.1.0-dev.15":
        notes = (
            "- Fix iOS single-package CocoaPods integration, including Agora "
            "RTC/Chat shared aosl framework selection and private C++ header "
            "leakage into Swift umbrella modules.\n"
            "- Document the host-only SwiftPM compatibility switch while the "
            "aggregated native plugin remains CocoaPods-based.\n"
            "- Eliminate mobile whiteboard pinch jitter by deriving zoom and "
            "pan from touch positions with a stable gesture anchor; rebasing "
            "on finger addition/removal does not move the canvas.\n"
            "- Keep one-finger drawing suppressed after a pinch until all "
            "touches lift; preserve regular single-finger drawing afterward.\n"
            "- Add mobile pinch reversal and finger-replacement widget "
            "regressions alongside iOS packaging checks.\n"
        )
    elif version == "0.1.0-dev.16":
        notes = None
    elif version == "0.1.0-dev.17":
        notes = (
            "- Fix LiveKit iOS in-app screen sharing with flutter_webrtc: "
            "capture a ReplayKit screen track directly and publish it as "
            "screenShareVideo instead of relying on LiveKit's BroadcastManager "
            "path, which silently returns without an iOS Broadcast Extension.\n"
            "- Treat real screen track publication as the success condition; "
            "stop captured tracks if publication fails and propagate the "
            "original error to the shared-content UI.\n"
            "- Add capture/publish transaction regression tests, including "
            "permission errors, failed publications and cleanup failures.\n"
            "- Scope: only the current iOS app can be shared. System-wide "
            "sharing needs a signed ReplayKit Broadcast Upload Extension "
            "and App Group in the host app.\n"
            "- Retain dev.16 lifecycle and mobile overflow fixes.\n"
        )
    elif version in ("0.1.0-dev.18", "0.1.0-dev.19"):
        notes = (
            "- Add full-system iOS screen sharing for LiveKit using ReplayKit "
            "Broadcast Upload Extension and App Group IPC. Default iOS screen "
            "sharing now targets the entire display, including other apps.\n"
            "- Package reusable Swift ReplayKit sample handlers and an "
            "idempotent Xcode host installer under ios/BroadcastExtensionTemplate "
            "and tool/setup_ios_broadcast_extension.rb.\n"
            "- Validate that the signed host has the App Group entitlement and "
            "an embedded .appex before opening Apple's broadcast picker. Wait "
            "for an actual LiveKit screen video publication before marking "
            "sharing active; add cancellation and missing-track timeouts.\n"
            "- Preserve explicit IosScreenShareMode.application for capturing "
            "the Flutter app alone; stop system broadcasts when ending a room.\n"
            "- Host signing requires registered Apple Developer App IDs, a "
            "shared App Group and matching provisioning profiles. Unsigned "
            "builds alone do not validate cross-app broadcast runtime.\n"
        )
    elif version in ("0.1.0-dev.20", "0.1.0-dev.21"):
        notes = (
            "- Add experimental iOS 27 ScreenCaptureKit whole-display capture "
            "without a Broadcast Upload Extension or App Group, backed by a "
            "shared native FrameHub and adapters for LiveKit, Agora, TRTC, "
            "Alibaba ARTC, AWS Chime Content Share and Amazon IVS Stage.\n"
            "- Amazon IVS uses camera-to-screen video replacement on its "
            "single Stage token; simultaneous camera and screen video "
            "requires a second token/participant and is not provided.\n"
            "- Await real ScreenCaptureKit video frames before publishing, and "
            "handle picker cancellation, start failures, changes of selected "
            "content, stale native stop events and room teardown.\n"
            "- Keep the ReplayKit Broadcast Upload Extension path for older "
            "iOS versions on LiveKit and the explicit application-only mode.\n"
            "- Requires iOS 27+ and an iOS 27 SDK; the host must set the "
            "screen-capture background mode to keep sharing other apps. "
            "Two-device real screen playback, Chime Content Tile and IVS "
            "remote screen classification remain unverified.\n"
        )
    else:
        notes = (
            "- Fix camera-off background selection followed by camera-on in external Headless apps.\n"
            "- Add RealtimeRoom.setCameraEnabled with serialized effects/source publication; preserve support for custom effects controllers.\n"
            "- Expose DefaultRealtimeVideoEffects via the single public SDK import, with Headless usage guidance.\n"
            "- Unify default meeting/live virtual-background entries and unsupported-state messaging.\n"
        )
    (destination / "CHANGELOG.md").write_text(
        _dev16_changelog() if notes is None else (
            f"## {version}\n\n"
            + notes
            + "- iOS Simulator, Windows/Linux and real-device vendor acceptance remain pending/unsupported as documented.\n"
        )
    )
    # Parent build/ is ignored by the source checkout. Make Pub's package file
    # inventory independent of that checkout, without creating a source commit.
    subprocess.run(["git", "init", "--quiet"], cwd=destination, check=True)
    file_count = _write_inventory(destination)
    (destination.parent / "PREPARATION.json").write_text(json.dumps({
        "package": "flutter_realtime_sdk", "version": version,
        "published": False, "fileCount": file_count,
        "iosVendorFrameworksIncluded": False,
        "validation": "Run analyze, independent-host iOS build, and pub publish --dry-run; retain their actual results.",
        "pending": ["physical-device vendor E2E", "Windows/Linux builds", "redistribution/license review"],
    }, indent=2) + "\n")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--refresh-readmes", action="store_true",
        help="Update only bilingual READMEs and file inventory in an existing unpublished staged version."
    )
    parser.add_argument(
        "--verify", action="store_true",
        help="Validate an existing staged release without modifying or publishing it."
    )
    parser.add_argument(
        "--refresh-changelog", action="store_true",
        help="Update only the dev.16 release notes and rehash a verified unpublished stage."
    )
    args = parser.parse_args()
    if sum((args.verify, args.refresh_readmes, args.refresh_changelog)) > 1:
        parser.error("--verify, --refresh-readmes and --refresh-changelog are mutually exclusive")
    print(
        verify_staged(args.version) if args.verify
        else refresh_changelog(args.version) if args.refresh_changelog
        else refresh_readmes(args.version) if args.refresh_readmes
        else prepare(args.version)
    )
