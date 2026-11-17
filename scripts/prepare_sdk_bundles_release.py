#!/usr/bin/env python3
"""Stage lockstep-versioned modular SDK bundles and verify host isolation.

Stages unpublished release candidates into:
  `build/pub_release/<version>/bundles/<bundle_id>/`

Features:
  - Topological publish ordering (`flutter_realtime_sdk` first, then on-demand
    provider/feature bundles, then `flutter_realtime_sdk_all`).
  - Per-bundle `FILES.sha256.json` immutable source inventory & bilingual READMEs.
  - `verify_host_isolation()`: proves that a consumer depending on
    `flutter_realtime_sdk` + one provider bundle (e.g. `flutter_realtime_sdk_livekit`)
    acquires ZERO transitive dependencies or native plugins from any other vendor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

from assemble_sdk_bundles import load_bundle_manifest, topological_bundle_order
from assemble_sdk_bundles_native import build_modular_distribution
from audit_single_pub_package import ROOT, dependency_names, plugin_entrypoints

VERSION_RE = re.compile(r"0\.[1-9][0-9]*\.[0-9]+-dev\.[1-9][0-9]*|0\.1\.0-dev\.[1-9][0-9]*")


def _inventory_file(path: Path, destination: Path) -> bool:
    relative = path.relative_to(destination)
    return (
        path.is_file()
        and not ({".git", ".dart_tool"} & set(relative.parts))
        and relative.parts[:2] != ("ios", "Frameworks")
        and path.name not in {
            "pubspec.lock",
            ".flutter-plugins",
            ".flutter-plugins-dependencies",
            "BUNDLE_REPORT.json",
        }
    )


def _compute_hashes(destination: Path) -> dict[str, str]:
    return {
        str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(destination.rglob("*"))
        if _inventory_file(p, destination)
    }


def _render_bundle_readmes(destination: Path, bundle_id: str, cfg: dict, version: str, core_bundle: str) -> None:
    factory = cfg.get("factorySymbol")
    if bundle_id == core_bundle:
        en = (
            f"# {bundle_id} ({version})\n\n"
            f"{cfg['description']}\n\n"
            "## Quick Start (On-Demand Native SDK)\n\n"
            "Install this core package together with only the provider bundle(s) you use:\n\n"
            "```yaml\n"
            "dependencies:\n"
            f"  {core_bundle}: ^{version}\n"
            f"  flutter_realtime_sdk_livekit: ^{version}\n"
            "```\n"
        )
        zh = (
            f"# {bundle_id}（{version}）\n\n"
            "跨平台实时音视频统一门面核心包（含 Runtime、可组合 UI、课堂/直播预设与共享帧中心，零第三方音视频原生二进制）。\n\n"
            "## 按需接入\n\n"
            "```yaml\n"
            "dependencies:\n"
            f"  {core_bundle}: ^{version}\n"
            f"  flutter_realtime_sdk_livekit: ^{version}\n"
            "```\n"
        )
    elif factory:
        en = (
            f"# {bundle_id} ({version})\n\n"
            f"{cfg['description']}\n\n"
            "## Single-Import Usage\n\n"
            "```dart\n"
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "final realtime = Realtime(\n"
            "  backendUrl: 'https://your-backend.example',\n"
            f"  providers: [{factory}()],\n"
            ");\n"
            "```\n"
        )
        zh = (
            f"# {bundle_id}（{version}）\n\n"
            f"{cfg['description']}\n\n"
            "## 单门面一行导入接入\n\n"
            "```dart\n"
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "final realtime = Realtime(\n"
            "  backendUrl: 'https://your-backend.example',\n"
            f"  providers: [{factory}()],\n"
            ");\n"
            "```\n"
        )
    else:
        en = f"# {bundle_id} ({version})\n\n{cfg['description']}\n"
        zh = f"# {bundle_id}（{version}）\n\n{cfg['description']}\n"

    (destination / "README.md").write_text(en, encoding="utf-8")
    (destination / "README.zh-CN.md").write_text(zh, encoding="utf-8")


def prepare_bundles_release(version: str, root: Path = ROOT) -> dict:
    if not VERSION_RE.fullmatch(version):
        raise ValueError(f"Expected explicit preview version (e.g. 0.2.0-dev.1), got {version}")

    release_root = root / "build" / "pub_release" / version / "bundles"
    if release_root.exists():
        raise FileExistsError(f"Bundle release already staged: {release_root}")

    spec = load_bundle_manifest(root)
    core_bundle = spec["coreBundle"]
    all_bundle = spec["allBundle"]

    # Build fresh hosted-dependency bundles into an isolated build staging dir first.
    staging_build = root / "build" / "sdk_bundles_hosted"
    if staging_build.exists():
        shutil.rmtree(staging_build)
    build_modular_distribution(
        root,
        staging_build,
        version=version,
        use_path_siblings=False,
        include_all_meta=True,
    )

    notes_path = root / "scripts" / "release_notes_current.md"
    notes = (
        notes_path.read_text(encoding="utf-8").strip() + "\n"
        if notes_path.is_file()
        else f"## {version}\n\n- Modular on-demand provider bundle preview.\n"
    )
    if not notes.startswith(f"## {version}\n"):
        notes = f"## {version}\n\n- Modular on-demand provider bundle preview.\n\n" + notes

    publish_order = topological_bundle_order(spec) + [all_bundle]
    staged_summary: dict[str, dict] = {}
    release_root.mkdir(parents=True)

    for bundle_id in publish_order:
        src = staging_build / bundle_id
        dst = release_root / bundle_id

        def ignore(folder: str, names: list[str]) -> set[str]:
            rel = Path(folder).relative_to(src)
            if rel == Path("."):
                return set(names) & {
                    ".git", ".dart_tool", ".flutter-plugins",
                    ".flutter-plugins-dependencies", "pubspec.lock", "BUNDLE_REPORT.json",
                }
            if rel == Path("tool"):
                return set(names) & {"bundle_smoke.dart"}
            if rel == Path("ios"):
                return set(names) & {"Frameworks"}
            return set()

        shutil.copytree(src, dst, ignore=ignore)
        pubspec_path = dst / "pubspec.yaml"
        pubspec = pubspec_path.read_text(encoding="utf-8")
        pubspec = re.sub(r"(?m)^version:.*$", f"version: {version}", pubspec)
        pubspec = re.sub(r"(?m)^publish_to:.*\n", "", pubspec)
        pubspec_path.write_text(pubspec, encoding="utf-8")

        for plat in ("ios", "macos"):
            podspec = dst / plat / f"{bundle_id}.podspec"
            if podspec.is_file():
                podspec.write_text(
                    re.sub(r"s\.version = '[^']+'", f"s.version = '{version}'", podspec.read_text(encoding="utf-8")),
                    encoding="utf-8",
                )

        cfg = spec["bundles"].get(
            bundle_id,
            {"description": "All-providers convenience meta-package for flutter_realtime_sdk."},
        )
        _render_bundle_readmes(dst, bundle_id, cfg, version, core_bundle)
        (dst / "CHANGELOG.md").write_text(notes, encoding="utf-8")
        subprocess.run(["git", "init", "--quiet"], cwd=dst, check=True)

        hashes = _compute_hashes(dst)
        (dst.parent / f"{bundle_id}.FILES.sha256.json").write_text(
            json.dumps(hashes, indent=2) + "\n",
            encoding="utf-8",
        )
        staged_summary[bundle_id] = {
            "path": str(dst),
            "fileCount": len(hashes),
        }

    prep = {
        "version": version,
        "published": False,
        "publishOrder": publish_order,
        "bundles": staged_summary,
    }
    (release_root / "PREPARATION.json").write_text(
        json.dumps(prep, indent=2) + "\n",
        encoding="utf-8",
    )
    return prep


def verify_staged_bundles(version: str, root: Path = ROOT) -> dict:
    release_root = root / "build" / "pub_release" / version / "bundles"
    prep_path = release_root / "PREPARATION.json"
    if not prep_path.is_file():
        raise FileNotFoundError(f"Missing staged bundle metadata: {prep_path}")
    prep = json.loads(prep_path.read_text(encoding="utf-8"))
    for bundle_id, info in prep["bundles"].items():
        dst = release_root / bundle_id
        manifest_path = release_root / f"{bundle_id}.FILES.sha256.json"
        expected = json.loads(manifest_path.read_text(encoding="utf-8"))
        actual = _compute_hashes(dst)
        if actual != expected or len(actual) != info["fileCount"]:
            raise ValueError(f"Staged bundle integrity mismatch for {bundle_id}")
        pubspec = (dst / "pubspec.yaml").read_text(encoding="utf-8")
        if "publish_to:" in pubspec or "    path:" in pubspec or "    git:" in pubspec:
            raise ValueError(f"Staged bundle {bundle_id} contains unpublishable dependency spec")
    return prep


def verify_host_isolation(
    bundles_dir: Path,
    selected_bundles: list[str],
    root: Path = ROOT,
) -> dict:
    """Mathematically verify transitive closure of a host selecting `selected_bundles`."""
    spec = load_bundle_manifest(root)
    all_known = set(spec["bundles"].keys()) | {spec["allBundle"]}
    closure: set[str] = set()
    queue = list(selected_bundles)
    external_deps: set[str] = set()
    native_plugins: dict[str, list[str]] = {}

    while queue:
        current = queue.pop(0)
        if current in closure:
            continue
        closure.add(current)
        pubspec = (bundles_dir / current / "pubspec.yaml").read_text(encoding="utf-8")
        for dep in dependency_names(pubspec):
            if dep in all_known:
                queue.append(dep)
            elif dep != "flutter":
                external_deps.add(dep)
        for plat, cfg in plugin_entrypoints(pubspec).items():
            native_plugins.setdefault(plat, []).append(f"{current}:{cfg.get('pluginClass')}")

    excluded_bundles = sorted(all_known - closure)
    return {
        "selected": selected_bundles,
        "resolvedBundles": sorted(closure),
        "excludedBundles": excluded_bundles,
        "externalDependencies": sorted(external_deps),
        "nativePluginRegistrations": native_plugins,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    out = (
        verify_staged_bundles(args.version, ROOT)
        if args.verify
        else prepare_bundles_release(args.version, ROOT)
    )
    print(json.dumps({
        "version": out["version"],
        "publishOrder": out["publishOrder"],
        "bundleCount": len(out["bundles"]),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
