#!/usr/bin/env python3
"""Assemble an isolated *Dart-only* preview of the single-package SDK.

The output is deliberately NOT release-ready: native plugin registration,
Gradle/CocoaPods/Windows and vendor-specific assets must be reconciled before
publishing. Existing packages/ and the Demo are never edited.

Useful for finding source-level conflicts when folding 44 modules into one
public library without losing module boundaries in the development monorepo.
"""

import argparse
import json
import re
import shutil
from pathlib import Path

from audit_single_pub_package import ROOT, dependency_sections


def merge_constraint(dependency: str, previous: str, incoming: str) -> str:
    """Merge compatible caret constraints; reject unsafe guesses."""
    if previous == incoming:
        return previous
    old = re.fullmatch(r"\^(\d+)\.(\d+)\.(\d+)", previous)
    new = re.fullmatch(r"\^(\d+)\.(\d+)\.(\d+)", incoming)
    if old and new:
        a, b = tuple(map(int, old.groups())), tuple(map(int, new.groups()))
        def upper(v):
            if v[0]:
                return (v[0] + 1, 0, 0)
            if v[1]:
                return (0, v[1] + 1, 0)
            return (0, 0, v[2] + 1)
        low = max(a, b)
        if low < min(upper(a), upper(b)):
            return "^" + ".".join(map(str, low))
    raise ValueError(f"Incompatible or unsupported constraints for {dependency}: {previous} vs {incoming}")


def hosted_dependencies(root: Path, names: list[str]) -> dict[str, str]:
    hosted = {"flutter": "    sdk: flutter"}
    origins = {"flutter": "Flutter SDK"}
    for name in names:
        text = (root / "packages" / name / "pubspec.yaml").read_text()
        lines = dependency_sections(text)["dependencies"]
        current = None
        for line in lines:
            if (match := re.match(r"^  (\w+):\s*(.*)$", line)):
                current = match.group(1)
                value = match.group(2).strip()
                if current in names:
                    continue
                if value:
                    if current in hosted and hosted[current] != value:
                        hosted[current] = merge_constraint(current, hosted[current], value)
                    else:
                        hosted[current] = value
                    origins[current] = name
                elif current == "flutter_localizations":
                    hosted.setdefault(current, "    sdk: flutter")
                    origins.setdefault(current, name)
            # For other non-hosted nested dependency descriptors, record only
            # Flutter SDK declarations; git/path references never go in pubspec.
    return hosted


def copy_dart_tree(root: Path, destination: Path, names: list[str]) -> int:
    src = destination / "lib" / "src" / "_bundled"
    src.mkdir(parents=True, exist_ok=True)
    owned = re.compile(
        r"(?<![\w])package:(" + "|".join(re.escape(n) for n in names) + r")/"
    )
    # Include basic package provenance in the isolated preview. These files
    # do not make the generated package safe or ready for publication.
    for filename in ("LICENSE", "CHANGELOG.md"):
        source = root / "packages" / "flutter_realtime_sdk" / filename
        if not source.is_file():
            raise FileNotFoundError(f"Missing release metadata: {source}")
        shutil.copy2(source, destination / filename)
    assets = re.compile(
        r"(?:assets/)?packages/(" + "|".join(re.escape(n) for n in names) + r")/assets/"
    )
    count = 0
    for name in names:
        for original in (root / "packages" / name / "lib").rglob("*.dart"):
            target = src / name / original.relative_to(root / "packages" / name / "lib")
            target.parent.mkdir(parents=True, exist_ok=True)
            code = original.read_text(encoding="utf-8")
            code = owned.sub(
                lambda m: f"package:flutter_realtime_sdk/src/_bundled/{m.group(1)}/",
                code,
            )
            code = assets.sub(
                lambda m: (
                    ("assets/" if m.group(0).startswith("assets/") else "")
                    + f"packages/flutter_realtime_sdk/assets/bundled/{m.group(1)}/"
                ),
                code,
            )
            target.write_text(code, encoding="utf-8")
            count += 1
    return count


def copy_bundled_assets(root: Path, destination: Path, names: list[str]) -> tuple[list[str], int]:
    """Copy vendor assets, declaring every populated directory explicitly.

    Flutter's `flutter.assets` directory entries are NOT recursive. Listing
    just `assets/bundled/flutter_realtime_video_effects/` excludes all its
    web/models and web/wasm files from an external host's build.
    """
    entries: list[str] = []
    asset_modules = 0
    for name in names:
        original = root / "packages" / name / "assets"
        if not original.is_dir():
            continue
        target = destination / "assets" / "bundled" / name
        shutil.copytree(original, target)
        # Explicitly register the directories containing files (including the
        # nested WASM/model folders) instead of trusting a non-recursive entry.
        populated = sorted({
            file.parent.relative_to(destination).as_posix() + "/"
            for file in target.rglob("*") if file.is_file()
        })
        if populated:
            asset_modules += 1
            entries.extend(f"    - {path}" for path in populated)

    # Dart source URLs were rewritten by copy_dart_tree, but asset JavaScript
    # is copied byte-for-byte. Rewrite only the effects bridge's runtime asset
    # prefix; never touch vendor minified assets or original source packages.
    effects_js = (
        destination / "assets/bundled/flutter_realtime_video_effects/"
        "web/video-effects-bridge.js"
    )
    if effects_js.is_file():
        old_prefix = "assets/packages/flutter_realtime_video_effects/assets/web/"
        new_prefix = (
            "assets/packages/flutter_realtime_sdk/assets/bundled/"
            "flutter_realtime_video_effects/web/"
        )
        code = effects_js.read_text(encoding="utf-8")
        if old_prefix not in code:
            raise ValueError("Unexpected Web effects bridge runtime path; update the bundler")
        effects_js.write_text(code.replace(old_prefix, new_prefix), encoding="utf-8")
    return entries, asset_modules


def copy_bundled_fonts(root: Path, destination: Path) -> str:
    """Copy the design system's bundled fonts and declare them.

    Flutter resolves a package font as `packages/<package>/<family>`. Once the
    design package is folded into `flutter_realtime_sdk`, those literals must
    be rewritten (see rewrite_bundled_font_families) or every Text falls back
    to the platform font at runtime.
    """
    source = root / "packages" / "flutter_realtime_design_ui" / "fonts"
    if not source.is_dir():
        return ""
    target = destination / "fonts"
    shutil.copytree(source, target)
    families: dict[str, list[tuple[str, int]]] = {}
    for font in sorted(target.glob("*.ttf")):
        family, _, weight_name = font.stem.partition("-")
        weight = {
            "Regular": 400,
            "Medium": 500,
            "SemiBold": 600,
            "Bold": 700,
        }.get(weight_name, 400)
        families.setdefault(family, []).append((font.name, weight))
    lines = ["  fonts:"]
    for family in sorted(families):
        lines.append(f"    - family: {family}")
        lines.append("      fonts:")
        for filename, weight in sorted(
            families[family], key=lambda item: item[1]
        ):
            lines.append(f"        - asset: fonts/{filename}")
            lines.append(f"          weight: {weight}")
    return "\n".join(lines) + "\n"


def rewrite_bundled_font_families(destination: Path, names: list[str]) -> int:
    """Point `packages/<ui package>/<Family>` literals at the single package."""
    pattern = re.compile(
        r"packages/("
        + "|".join(re.escape(n) for n in names)
        + r")/(Onest|BricolageGrotesque)"
    )
    changed = 0
    for dart in destination.rglob("*.dart"):
        code = dart.read_text(encoding="utf-8")
        if "packages/" not in code:
            continue
        rewritten = pattern.sub(
            lambda m: f"packages/flutter_realtime_sdk/{m.group(2)}", code
        )
        if rewritten != code:
            dart.write_text(rewritten, encoding="utf-8")
            changed += 1
    return changed


def assemble(root: Path, destination: Path) -> dict:
    names = json.loads((root / "scripts/sdk_packages.json").read_text())
    destination = destination.resolve()
    # Never accidentally overwrite source packages or a user's own app.
    build_root = (root / "build").resolve()
    if destination != build_root / "single_sdk_candidate":
        raise ValueError("Only the ignored build/single_sdk_candidate directory is supported")
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    count = copy_dart_tree(root, destination, names)
    assets, asset_modules = copy_bundled_assets(root, destination, names)
    font_declarations = copy_bundled_fonts(root, destination)
    font_files_rewritten = rewrite_bundled_font_families(destination, names)
    # Deliberately curate the single user-facing import surface. The internal
    # package names are not exported to the user, only their public libraries.
    public = [
        "flutter_realtime_sdk_runtime",
        "flutter_realtime_provider_livekit",
        "flutter_realtime_provider_agora",
        "flutter_realtime_provider_trtc",
        "flutter_realtime_provider_artc",
        "flutter_realtime_provider_aws",
        "flutter_realtime_provider_agora_chat",
        "flutter_realtime_provider_ivs_chat",
        "flutter_realtime_provider_tencent_chat",
        "flutter_realtime_sdk_ui",
        "flutter_realtime_classroom_preset",
        "flutter_realtime_live_preset",
        "flutter_realtime_shared_content_preset",
    ]
    entry = "// GENERATED SINGLE-SDK DART PREVIEW. NOT RELEASE READY.\n"
    entry += "".join(
        f"export 'src/_bundled/{name}/{name}.dart';\n" for name in public
    )
    # The single hosted package must expose the optional effects factory.
    # Otherwise an external Headless app cannot opt in using the one public
    # import, even though its native processed-video implementation is bundled.
    entry += (
        "export 'src/_bundled/flutter_realtime_video_effects/"
        "flutter_realtime_video_effects.dart' show DefaultRealtimeVideoEffects;\n"
    )
    (destination / "lib" / "flutter_realtime_sdk.dart").write_text(entry)
    # Compile this from the *one public import* to catch collisions and missing
    # exports that ordinary isolated library analysis does not detect.
    smoke = destination / "tool" / "single_import_smoke.dart"
    smoke.parent.mkdir(exist_ok=True)
    smoke.write_text(
        "import 'package:flutter/material.dart';\n"
        "import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';\n\n"
        "Realtime createSdk() => Realtime(\n"
        "  backendUrl: 'https://example.invalid',\n"
        "  providers: [createLivekitProvider(), createAgoraProvider(), "
        "createTrtcProvider(), createArtcProvider(), createAwsProvider()],\n"
        "  services: const RealtimeRoomServices(\n"
        "    videoEffectsFactory: DefaultRealtimeVideoEffects.new,\n"
        "  ),\n"
        "  featurePlugins: const [ClassroomPreset(), LivePreset()],\n"
        ");\n"
        "Widget composeRoom(RealtimeRoom room) => RealtimeRoomView(\n"
        "  room: room, config: const RealtimeRoomViewConfig(),\n"
        ");\n"
        "Widget composeChat(RealtimeChatRoom room) => RealtimeChatPage(chatRoom: room);\n"
        "Widget composePreJoin(Realtime sdk, RealtimePreJoinEnter enter) => RealtimePreJoinPage(\n"
        "  roomLabel: 'room', displayName: 'Guest', onEnter: enter,\n"
        "  runCheck: () => sdk.preJoin(role: MediaRole.participant),\n"
        "  openPreview: (provider, role) => sdk.createLocalPreview(providerId: provider, role: role),\n"
        ");\n"
    )

    external = hosted_dependencies(root, names)
    dependencies = "\n".join(
        f"  {key}:\n{value}" if value.startswith("    ") else f"  {key}: {value}"
        for key, value in sorted(external.items())
    )
    pubspec = (
        "name: flutter_realtime_sdk\n"
        "description: Prototype of a single public Flutter Realtime SDK artifact.\n"
        "version: 0.1.0\n"
        "publish_to: none\n"
        "repository: https://github.com/lengsukq/multi-video\n"
        "environment:\n  sdk: ^3.12.0\n  flutter: '>=3.47.0'\n"
        f"dependencies:\n{dependencies}\n"
        # Vendor-generated minified audio-processing JavaScript contains a
        # coincidental access-key-shaped byte sequence, not credentials.
        # Scope pub's false-positive exemption to exactly that bundled file.
        "false_secrets:\n"
        "  - /assets/bundled/flutter_realtime_provider_trtc/trtc-assets/audioProcessor-wasm.js\n"
        "flutter:\n  uses-material-design: true\n"
    )
    if assets:
        pubspec += "  assets:\n" + "\n".join(assets) + "\n"
    if font_declarations:
        pubspec += font_declarations
    (destination / "pubspec.yaml").write_text(pubspec)
    (destination / "README.md").write_text(
        "# Flutter Realtime SDK — generated release candidate\n\n"
        "**NOT READY FOR PUB.DEV.** This candidate is produced from the "
        "44-module development workspace and intentionally retains "
        "`publish_to: none`.\n\n"
        "## Public API\n\n"
        "```dart\n"
        "import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';\n\n"
        "final sdk = Realtime(\n"
        "  backendUrl: 'https://your-backend.example',\n"
        "  providers: [createLivekitProvider()],\n"
        "  featurePlugins: const [ClassroomPreset(), LivePreset()],\n"
        ");\n"
        "```\n\n"
        "Flutter applications consume one SDK package. The developer may "
        "build a headless integration or use exported UI widgets. Vendor "
        "plugins still need explicit provider registration.\n\n"
        "## Limitations\n\n"
        "Generated native entry points are engineering prototypes. The "
        "iOS uses pinned official IVS archives and requires the provided Podfile hook; "
        "Windows/Linux and live vendor/device E2E remain unverified. "
        "See doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md in the source repository.\n"
    )
    result = {
        "target": str(destination),
        "dartLibraries": count,
        "assetModules": asset_modules,
        "bundledFonts": bool(font_declarations),
        "fontFilesRewritten": font_files_rewritten,
        "publicExports": public,
        "nativePluginRegistrationComplete": False,
        "publishable": False,
    }
    (destination / "ASSEMBLY_REPORT.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    args = parser.parse_args()
    del args
    report = assemble(ROOT, ROOT / "build" / "single_sdk_candidate")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
