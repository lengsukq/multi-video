#!/usr/bin/env python3
"""Read-only feasibility audit for shipping ONE pub.dev Flutter SDK package.

44 independently developed packages are an implementation detail. Pub.dev may
only receive a standalone distribution with no internal path/git dependencies.
This script intentionally neither merges native plugins nor edits pubspecs.
"""

import argparse
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "scripts" / "sdk_packages.json"
PLATFORMS = ("android", "ios", "macos", "windows", "linux", "web")
DEPENDENCY_BLOCKS = ("dependencies", "dev_dependencies", "dependency_overrides")


def dependency_sections(manifest: str) -> dict[str, list[str]]:
    """Read top-level dependency YAML blocks without requiring PyYAML."""
    sections: dict[str, list[str]] = {name: [] for name in DEPENDENCY_BLOCKS}
    active = None
    for line in manifest.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            active = line.split(":", 1)[0] if line.endswith(":") else None
        elif active in sections:
            sections[active].append(line)
    return sections


def dependency_names(manifest: str) -> set[str]:
    block = dependency_sections(manifest)["dependencies"]
    return {
        match.group(1)
        for line in block
        if (match := re.match(r"^  ([A-Za-z_][A-Za-z_0-9]*):", line))
    }


def path_dependencies(manifest: str) -> list[str]:
    """Match only YAML dependency values, not examples or unrelated keys."""
    result = []
    for group, lines in dependency_sections(manifest).items():
        owner = None
        for line in lines:
            if (match := re.match(r"^  ([A-Za-z_][A-Za-z_0-9]*):", line)):
                owner = match.group(1)
            elif owner and re.match(r"^    (path|git):", line):
                result.append(f"{group}/{owner}")
    return result


def platforms(manifest: str) -> list[str]:
    """Read plugin platforms only, not arbitrary platform descriptions."""
    lines = manifest.splitlines()
    inside_plugin = False
    inside_platforms = False
    found = []
    for line in lines:
        if line == "  plugin:":
            inside_plugin = True
            continue
        if inside_plugin and line.startswith("  ") and not line.startswith("    "):
            inside_plugin = False
            inside_platforms = False
        if inside_plugin and line == "    platforms:":
            inside_platforms = True
        elif inside_platforms and (match := re.match(r"^      (android|ios|macos|windows|linux|web):", line)):
            found.append(match.group(1))
    return found


def plugin_entrypoints(manifest: str) -> dict[str, dict[str, str]]:
    """Keep native registrar class/package names available for the next merge."""
    result: dict[str, dict[str, str]] = {}
    plugin = False
    platform = None
    for line in manifest.splitlines():
        if line == "  plugin:":
            plugin = True
            continue
        if plugin and line.startswith("  ") and not line.startswith("    "):
            break
        if plugin and (match := re.match(r"^      (android|ios|macos|windows|linux|web):", line)):
            platform = match.group(1)
            result[platform] = {}
        elif plugin and platform and (
            match := re.match(
                r"^        (package|pluginClass|dartPluginClass|fileName|default_package):\s*(.+)$",
                line,
            )
        ):
            result[platform][match.group(1)] = match.group(2).strip(" '\"")
    return result


def audit(root: Path = ROOT) -> dict:
    names: list[str] = json.loads((root / "scripts/sdk_packages.json").read_text())
    inventory = set(names)
    plugin_map: dict[str, list[str]] = {platform: [] for platform in PLATFORMS}
    registrations: dict[str, dict[str, dict[str, str]]] = {
        platform: {} for platform in PLATFORMS
    }
    native_dirs: dict[str, list[str]] = {platform: [] for platform in PLATFORMS}
    external: set[str] = set()
    path_specs: dict[str, list[str]] = {}
    source_counts = Counter()
    assets = []
    package_uris = Counter()
    owned_sources = []
    native_project_dependencies = {}
    apple_pod_dependencies = {}

    for name in names:
        directory = root / "packages" / name
        content = (directory / "pubspec.yaml").read_text()
        refs = dependency_names(content)
        external.update(refs - inventory - {"flutter", "flutter_test", "flutter_localizations"})
        paths = path_dependencies(content)
        if paths:
            path_specs[name] = paths
        for platform, config in plugin_entrypoints(content).items():
            plugin_map[platform].append(name)
            registrations[platform][name] = config
        for platform in PLATFORMS:
            if (directory / platform).is_dir():
                native_dirs[platform].append(name)
        gradle = directory / "android" / "build.gradle"
        if gradle.is_file():
            refs = re.findall(r"(?:implementation|api|compileOnly)\s+project\(['\"]:([^'\"]+)['\"]\)", gradle.read_text())
            if refs:
                native_project_dependencies[name] = sorted(set(refs))
        pods = {}
        for platform in ("ios", "macos"):
            for podspec in (directory / platform).glob("*.podspec"):
                refs = re.findall(r"s\.dependency\s+['\"]([^'\"]+)['\"]", podspec.read_text())
                if refs:
                    pods[platform] = sorted(set(refs))
        if pods:
            apple_pod_dependencies[name] = pods
        if (directory / "assets").is_dir():
            assets.append(name)
        for dart in (directory / "lib").rglob("*.dart"):
            owned_sources.append(dart)
            source_counts[name] += 1
            text = dart.read_text(encoding="utf-8")
            for match in re.finditer(r"package:([A-Za-z_][A-Za-z_0-9]*)/", text):
                if match.group(1) in inventory:
                    package_uris[match.group(1)] += 1

    vendored = root / "packages" / "flutter_webrtc"
    if not vendored.is_dir():
        raise ValueError("The SDK's WebRTC fork is not available for auditing")
    return {
        "target": "ONE hosted pub.dev package named flutter_realtime_sdk",
        "internalModules": len(names),
        "dartSourceFiles": len(owned_sources),
        "internalPackageImports": sum(package_uris.values()),
        "usedInternalImports": dict(sorted(package_uris.items())),
        "pathOrGitDependencyPackages": len(path_specs),
        "pathOrGitDependenciesByPackage": dict(sorted(path_specs.items())),
        "pluginRegistrations": {p: sorted(v) for p, v in plugin_map.items() if v},
        "nativePluginEntrypoints": {
            p: dict(sorted(v.items())) for p, v in registrations.items() if v
        },
        "nativeSourceDirectories": {p: sorted(v) for p, v in native_dirs.items() if v},
        "nativeGradleProjectDependencies": native_project_dependencies,
        "applePodDependencies": apple_pod_dependencies,
        "bundledAssetPackages": sorted(assets),
        "externalDependencies": sorted(external),
        "hasVendoredWebRtcFork": True,
        "publishableNow": False,
        "blockingWork": [
            "Repackage each internal Dart library and rewrite all package: owned-library imports/exports.",
            "Aggregate all per-platform plugin registration entrypoints and preserve native method/event channels.",
            "Merge and validate Gradle, CocoaPods, Swift, Windows/CMake, Web JS, and vendor SDK dependency manifests.",
            "Relocate all assets and rewrite package-scoped lookup paths (including Web URLs and models).",
            "Decide which third-party hosted plugins remain dependencies; audit WebRTC fork and redistribution licenses.",
            "Remove ALL internal path/git dependencies including dev_dependencies and verify clean publish --dry-run.",
            "Run external-host builds and real devices across vendors; only then switch publish_to: none.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit machine-readable report")
    parser.add_argument(
        "--strict", action="store_true",
        help="Exit nonzero if the single distribution is not yet publishable",
    )
    args = parser.parse_args()
    report = audit()
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"Target: {report['target']}")
        print(
            f"{report['internalModules']} internal modules / "
            f"{report['dartSourceFiles']} Dart source files / "
            f"{report['internalPackageImports']} internal package: URI references"
        )
        print(f"Internal path/git dependency holders: {report['pathOrGitDependencyPackages']}")
        for platform, names in report["pluginRegistrations"].items():
            print(f"  {platform}: {len(names)} plugin registration(s): {', '.join(names)}")
        print(f"Android Gradle local-project references: {sum(map(len, report['nativeGradleProjectDependencies'].values()))}")
        print(f"Apple podspecs with dependency declarations: {len(report['applePodDependencies'])}")
        print(f"Asset-owning modules: {len(report['bundledAssetPackages'])}")
        print(f"Third-party dependencies to preserve: {len(report['externalDependencies'])}")
        print("Single publishable artifact: BLOCKED (see doc/PUB_DEV_RELEASE_GUIDE.zh-CN.md)")
    return 1 if args.strict and not report["publishableNow"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
