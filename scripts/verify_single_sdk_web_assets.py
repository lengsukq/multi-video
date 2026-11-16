#!/usr/bin/env python3
"""Validate hosted SDK Flutter Web asset packaging before pub.dev publication.

Optionally check a real host's 'flutter build web' output and AssetManifest.
No network, credentials, source mutations or publishing.
"""
import argparse
import base64
import json
import subprocess
from pathlib import Path

EFFECTS_PREFIX = "assets/bundled/flutter_realtime_video_effects/web/"
PUBLIC_PREFIX = "assets/packages/flutter_realtime_sdk/"
OLD_JS_PREFIX = "assets/packages/flutter_realtime_video_effects/assets/web/"
REQUIRED = (
    "vision.js",
    "video-effects-bridge.js",
    "models/selfie_segmenter_landscape.tflite",
    "models/blaze_face_short_range.tflite",
    "wasm/vision_wasm_internal.wasm",
    "wasm/vision_wasm_nosimd_internal.wasm",
    "wasm/vision_wasm_internal.js",
    "wasm/vision_wasm_nosimd_internal.js",
)
AWS_REQUIRED = (
    "assets/bundled/flutter_realtime_provider_aws/browser-global-compat.js",
    "assets/bundled/flutter_realtime_provider_aws/chime-sdk.js",
    "assets/bundled/flutter_realtime_provider_aws/amazon-ivs-web-broadcast.js",
    "assets/bundled/flutter_realtime_media_web/media-provider-bridge.js",
    "assets/bundled/flutter_realtime_media_aws_desktop/windows_runtime.js",
    "assets/bundled/flutter_realtime_media_aws_desktop/windows_host.js",
)


def verify(package: Path, web_build: Path | None = None) -> None:
    package = package.resolve()
    spec = (package / "pubspec.yaml").read_text(encoding="utf-8")
    for file in (package / "assets/bundled").rglob("*"):
        if not file.is_file():
            continue
        entry = f"    - {file.parent.relative_to(package).as_posix()}/"
        if entry not in spec:
            raise AssertionError(
                f"Flutter directory assets are not recursive: {entry} "
                f"must be declared for {file.relative_to(package)}"
            )
    for name in REQUIRED:
        asset = package / EFFECTS_PREFIX / name
        if not asset.is_file() or asset.stat().st_size == 0:
            raise AssertionError(f"Missing/empty hosted SDK asset: {asset}")
    for name in AWS_REQUIRED:
        asset = package / name
        if not asset.is_file() or asset.stat().st_size == 0:
            raise AssertionError(f"Missing/empty AWS hosted SDK asset: {asset}")
    aws_loader = (
        package
        / "lib/src/_bundled/flutter_realtime_provider_aws/src/assets.dart"
    ).read_text()
    aws_prefix = "assets/packages/flutter_realtime_sdk/assets/bundled/"
    expected_aws = [
        aws_prefix + name.removeprefix("assets/bundled/")
        for name in AWS_REQUIRED[:4]
    ]
    if any(path not in aws_loader for path in expected_aws):
        raise AssertionError("AWS browser loader still points to standalone package assets.")
    if aws_loader.index("browser-global-compat.js") > aws_loader.index("chime-sdk.js"):
        raise AssertionError("AWS browser compatibility shim must load before Chime.")
    windows_loader = (
        package
        / "lib/src/_bundled/flutter_realtime_media_aws_desktop/lib/aws_windows_webview2_runtime.dart"
    )
    if not windows_loader.exists():
        # The published source is flattened from lib/, not a nested lib/.
        windows_loader = (
            package
            / "lib/src/_bundled/flutter_realtime_media_aws_desktop/aws_windows_webview2_runtime.dart"
        )
    windows_code = windows_loader.read_text()
    for name in AWS_REQUIRED[1:]:
        expected = "packages/flutter_realtime_sdk/" + name
        if expected not in windows_code and (
            "media-provider-bridge.js" in name
            or name.endswith(("windows_runtime.js", "windows_host.js"))
        ):
            raise AssertionError(f"Windows AWS runtime missing hosted asset: {expected}")
    native_js = (
        package / "macos/Resources/flutter_realtime_media_aws_desktop/aws_desktop_runtime.js"
    )
    if not native_js.is_file() or native_js.stat().st_size == 0:
        raise AssertionError("macOS AWS WebKit runtime was not embedded in the native plugin.")
    bridge = (package / EFFECTS_PREFIX / "video-effects-bridge.js").read_text()
    expected_prefix = PUBLIC_PREFIX + EFFECTS_PREFIX
    if OLD_JS_PREFIX in bridge or expected_prefix not in bridge:
        raise AssertionError("Video-effects JS still points to old standalone package assets.")
    dart_loader = (
        package
        / "lib/src/_bundled/flutter_realtime_video_effects/src/video_effects_assets_web.dart"
    ).read_text()
    if expected_prefix not in dart_loader:
        raise AssertionError("Dart loader and bundled JS must use the same hosted asset prefix.")
    for relative in (
        EFFECTS_PREFIX + "video-effects-bridge.js",
        "assets/bundled/flutter_realtime_media_web/media-provider-bridge.js",
        "assets/bundled/flutter_realtime_provider_aws/browser-global-compat.js",
    ):
        checked = subprocess.run(
            ["node", "--check", str(package / relative)],
            capture_output=True, text=True,
        )
        if checked.returncode:
            raise AssertionError(f"Invalid bundled JavaScript: {relative}\n{checked.stderr}")

    if web_build is not None:
        web_build = web_build.resolve()
        manifest = web_build / "assets/AssetManifest.bin.json"
        if not manifest.is_file():
            raise AssertionError(f"Flutter Web AssetManifest missing: {manifest}")
        encoded = json.loads(manifest.read_text(encoding="utf-8"))
        # Modern Flutter writes a base64-encoded binary map in
        # AssetManifest.bin.json, not JSON object keys.
        manifest_bytes = (
            base64.b64decode(encoded) if isinstance(encoded, str) else None
        )
        keys = encoded if isinstance(encoded, dict) else None
        for name in (EFFECTS_PREFIX + name for name in REQUIRED):
            key = (PUBLIC_PREFIX + name).removeprefix("assets/")
            if (
                (keys is not None and key not in keys)
                or (
                    manifest_bytes is not None
                    and key.encode("utf-8") not in manifest_bytes
                )
            ):
                raise AssertionError(f"AssetManifest missing packaged asset: {key}")
            output = web_build / PUBLIC_PREFIX / name
            if not output.is_file() or output.stat().st_size == 0:
                raise AssertionError(f"Missing built Web asset: {output}")
        for name in AWS_REQUIRED:
            key = (PUBLIC_PREFIX + name).removeprefix("assets/")
            if (
                (keys is not None and key not in keys)
                or (manifest_bytes is not None and key.encode("utf-8") not in manifest_bytes)
            ):
                raise AssertionError(f"AssetManifest missing AWS asset: {key}")
            output = web_build / PUBLIC_PREFIX / name
            if not output.is_file() or output.stat().st_size == 0:
                raise AssertionError(f"Missing built Web AWS asset: {output}")
        print(f"PASS: independent Web build contains {len(REQUIRED)} effects and {len(AWS_REQUIRED)} AWS assets")
    print(f"PASS: hosted SDK Web/Windows/macOS asset manifest and AWS bootstrapping")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--web-build", type=Path)
    args = parser.parse_args()
    verify(args.package, args.web_build)


if __name__ == "__main__":
    main()
