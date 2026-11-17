#!/usr/bin/env python3
"""Assemble modular on-demand SDK bundles preserving the single-facade DX.

Reads `scripts/sdk_release_bundles.json` and folds the 44 internal workspace
modules into `build/sdk_bundles/<bundle_id>/`:
  - `flutter_realtime_sdk` (Core + Runtime + Composable UI + Presets + Frame Hub,
    zero third-party RTC/IM vendor native binaries)
  - `flutter_realtime_sdk_<provider>` (8 on-demand RTC / IM vendor bundles,
    each re-exporting `flutter_realtime_sdk` so single-vendor apps need only
    one Dart import and install only one vendor's native SDK)
  - `flutter_realtime_sdk_effects` & `flutter_realtime_sdk_annotation`
    (optional heavy native capabilities)
  - `flutter_realtime_sdk_all` (pure meta-package re-exporting every bundle)

Existing `packages/` sources and `build/single_sdk_candidate` are untouched.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

from assemble_single_sdk_candidate import merge_constraint
from audit_single_pub_package import ROOT, dependency_sections

MANIFEST_PATH = ROOT / "scripts" / "sdk_release_bundles.json"
DEFAULT_OUT = ROOT / "build" / "sdk_bundles"

CROSS_CORE_LIB_ROUTE = {
    "flutter_realtime_media_web/flutter_realtime_media_web.dart": (
        "package:flutter_realtime_sdk/media_web_spi.dart"
    ),
    "flutter_realtime_chat_core/flutter_realtime_chat_core_web.dart": (
        "package:flutter_realtime_sdk/chat_web_spi.dart"
    ),
}


def load_bundle_manifest(root: Path = ROOT) -> dict:
    spec = json.loads((root / "scripts" / "sdk_release_bundles.json").read_text(encoding="utf-8"))
    inventory = json.loads((root / "scripts" / "sdk_packages.json").read_text(encoding="utf-8"))
    seen: list[str] = []
    for bundle_id, cfg in spec["bundles"].items():
        for mod in cfg["ownedModules"]:
            if mod not in inventory:
                raise ValueError(f"Unknown internal module {mod} in {bundle_id}")
            if mod in seen:
                raise ValueError(f"Duplicate module ownership for {mod}")
            seen.append(mod)
    missing = set(inventory) - set(seen)
    if missing:
        raise ValueError(f"Unassigned internal modules: {sorted(missing)}")
    return spec


def module_owner_map(spec: dict) -> dict[str, str]:
    return {
        mod: bundle_id
        for bundle_id, cfg in spec["bundles"].items()
        for mod in cfg["ownedModules"]
    }


def topological_bundle_order(spec: dict) -> list[str]:
    bundles = spec["bundles"]
    visited: set[str] = set()
    active: set[str] = set()
    order: list[str] = []

    def visit(name: str) -> None:
        if name in active:
            raise ValueError(f"Bundle dependency cycle involving {name}")
        if name in visited:
            return
        active.add(name)
        for dep in bundles[name].get("siblingDependencies", []):
            if dep not in bundles:
                raise ValueError(f"{name} depends on unknown bundle {dep}")
            visit(dep)
        active.remove(name)
        visited.add(name)
        order.append(name)

    for bundle_id in bundles:
        visit(bundle_id)
    return order


def collect_external_dependencies(
    root: Path,
    owned_modules: list[str],
    all_internal: set[str],
) -> dict[str, str]:
    hosted: dict[str, str] = {"flutter": "    sdk: flutter"}
    for name in owned_modules:
        text = (root / "packages" / name / "pubspec.yaml").read_text(encoding="utf-8")
        lines = dependency_sections(text)["dependencies"]
        for line in lines:
            match = re.match(r"^  (\w+):\s*(.*)$", line)
            if not match:
                continue
            dep, constraint = match.group(1), match.group(2).strip()
            if dep in all_internal or dep == "flutter":
                continue
            if constraint:
                if dep in hosted and hosted[dep] != constraint:
                    hosted[dep] = merge_constraint(dep, hosted[dep], constraint)
                else:
                    hosted[dep] = constraint
            elif dep == "flutter_localizations":
                hosted.setdefault(dep, "    sdk: flutter")
    return hosted


def _rewrite_dart_source(
    code: str,
    *,
    current_bundle: str,
    core_bundle: str,
    owners: dict[str, str],
    strip_exports: set[str],
) -> str:
    for stripped in strip_exports:
        code = re.sub(
            rf"(?m)^\s*export\s+['\"]package:{re.escape(stripped)}['\"][^;]*;\s*\n?",
            "",
            code,
        )

    pkg_pattern = re.compile(
        r"package:(" + "|".join(re.escape(m) for m in sorted(owners, key=len, reverse=True)) + r")/([^'\"]+)"
    )

    def replace_pkg(match: re.Match[str]) -> str:
        mod, subpath = match.group(1), match.group(2)
        target_bundle = owners[mod]
        if target_bundle == current_bundle:
            return f"package:{current_bundle}/src/_bundled/{mod}/{subpath}"
        if target_bundle == core_bundle:
            key = f"{mod}/{subpath}"
            if key in CROSS_CORE_LIB_ROUTE:
                return CROSS_CORE_LIB_ROUTE[key]
            return f"package:{core_bundle}/provider_spi.dart"
        raise ValueError(
            f"Illegal cross-provider import from {current_bundle} to "
            f"{target_bundle} ({mod}/{subpath})"
        )

    code = pkg_pattern.sub(replace_pkg, code)

    asset_pattern = re.compile(
        r"(assets/)?packages/("
        + "|".join(re.escape(m) for m in sorted(owners, key=len, reverse=True))
        + r")/assets/"
    )

    def replace_asset(match: re.Match[str]) -> str:
        prefix = match.group(1) or ""
        mod = match.group(2)
        target_bundle = owners[mod]
        return f"{prefix}packages/{target_bundle}/assets/bundled/{mod}/"

    return asset_pattern.sub(replace_asset, code)


def _copy_bundle_dart_tree(
    root: Path,
    destination: Path,
    *,
    bundle_id: str,
    bundle_cfg: dict,
    core_bundle: str,
    owners: dict[str, str],
) -> int:
    bundled_root = destination / "lib" / "src" / "_bundled"
    bundled_root.mkdir(parents=True, exist_ok=True)
    for filename in ("LICENSE", "CHANGELOG.md"):
        shutil.copy2(root / "packages" / "flutter_realtime_sdk" / filename, destination / filename)

    strip_exports = set(bundle_cfg.get("stripExports", []))
    count = 0
    for mod in bundle_cfg["ownedModules"]:
        lib_dir = root / "packages" / mod / "lib"
        for original in lib_dir.rglob("*.dart"):
            target = bundled_root / mod / original.relative_to(lib_dir)
            target.parent.mkdir(parents=True, exist_ok=True)
            rewritten = _rewrite_dart_source(
                original.read_text(encoding="utf-8"),
                current_bundle=bundle_id,
                core_bundle=core_bundle,
                owners=owners,
                strip_exports=strip_exports,
            )
            target.write_text(rewritten, encoding="utf-8")
            count += 1
    return count


def _copy_bundle_assets(
    root: Path,
    destination: Path,
    *,
    bundle_id: str,
    owned_modules: list[str],
) -> tuple[list[str], int]:
    entries: list[str] = []
    asset_modules = 0
    for mod in owned_modules:
        original = root / "packages" / mod / "assets"
        if not original.is_dir():
            continue
        target = destination / "assets" / "bundled" / mod
        shutil.copytree(original, target)
        populated = sorted({
            file.parent.relative_to(destination).as_posix() + "/"
            for file in target.rglob("*")
            if file.is_file()
        })
        if populated:
            asset_modules += 1
            entries.extend(f"    - {path}" for path in populated)

    effects_js = (
        destination
        / "assets/bundled/flutter_realtime_video_effects/web/video-effects-bridge.js"
    )
    if effects_js.is_file():
        old_prefix = "assets/packages/flutter_realtime_video_effects/assets/web/"
        new_prefix = (
            f"assets/packages/{bundle_id}/assets/bundled/"
            "flutter_realtime_video_effects/web/"
        )
        code = effects_js.read_text(encoding="utf-8")
        if old_prefix not in code:
            raise ValueError("Unexpected Web effects bridge runtime path")
        effects_js.write_text(code.replace(old_prefix, new_prefix), encoding="utf-8")
    return entries, asset_modules


def _copy_bundle_fonts(
    root: Path,
    destination: Path,
    *,
    bundle_id: str,
    owned_modules: list[str],
) -> tuple[str, int]:
    if "flutter_realtime_design_ui" not in owned_modules:
        return "", 0
    source = root / "packages" / "flutter_realtime_design_ui" / "fonts"
    if not source.is_dir():
        return "", 0
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
        for filename, weight in sorted(families[family], key=lambda item: item[1]):
            lines.append(f"        - asset: fonts/{filename}")
            lines.append(f"          weight: {weight}")

    pattern = re.compile(
        r"packages/("
        + "|".join(re.escape(m) for m in owned_modules)
        + r")/(Onest|BricolageGrotesque)"
    )
    rewritten_files = 0
    for dart in destination.rglob("*.dart"):
        code = dart.read_text(encoding="utf-8")
        updated = pattern.sub(lambda m: f"packages/{bundle_id}/{m.group(2)}", code)
        if updated != code:
            dart.write_text(updated, encoding="utf-8")
            rewritten_files += 1
    return "\n".join(lines) + "\n", rewritten_files


def _write_entrypoints(
    destination: Path,
    *,
    bundle_id: str,
    bundle_cfg: dict,
    core_bundle: str,
) -> list[str]:
    lib_dir = destination / "lib"
    lines = [f"// GENERATED MODULAR SDK BUNDLE ({bundle_id}).\nlibrary;\n\n"]
    if bundle_cfg.get("reExportCore"):
        lines.append(f"export 'package:{core_bundle}/{core_bundle}.dart';\n")
    for mod in bundle_cfg.get("publicExports", []):
        lines.append(f"export 'src/_bundled/{mod}/{mod}.dart';\n")
    for mod, symbols in bundle_cfg.get("publicShowExports", {}).items():
        joined = ", ".join(symbols)
        lines.append(f"export 'src/_bundled/{mod}/{mod}.dart' show {joined};\n")
    (lib_dir / f"{bundle_id}.dart").write_text("".join(lines), encoding="utf-8")

    generated_files = [f"lib/{bundle_id}.dart"]
    for spi_name, targets in bundle_cfg.get("spiLibraries", {}).items():
        spi_lines = [
            "// INTERNAL PROVIDER SPI FOR OFFICIAL FLUTTER_REALTIME_SDK BUNDLES.\n"
            "library;\n\n"
        ]
        for rel in targets:
            spi_lines.append(f"export 'src/_bundled/{rel}';\n")
        (lib_dir / spi_name).write_text("".join(spi_lines), encoding="utf-8")
        generated_files.append(f"lib/{spi_name}")
    return generated_files


def _write_bundle_pubspec(
    destination: Path,
    *,
    bundle_id: str,
    bundle_cfg: dict,
    external_deps: dict[str, str],
    assets: list[str],
    font_declarations: str,
    version: str,
    use_path_siblings: bool,
) -> None:
    deps: dict[str, str] = dict(external_deps)
    for sibling in bundle_cfg.get("siblingDependencies", []):
        if use_path_siblings:
            deps[sibling] = f"    path: ../{sibling}"
        else:
            deps[sibling] = f"^{version}"

    dep_lines = "\n".join(
        f"  {k}:\n{v}" if v.startswith("    ") else f"  {k}: {v}"
        for k, v in sorted(deps.items())
    )
    pubspec = (
        f"name: {bundle_id}\n"
        f"description: {bundle_cfg['description']}\n"
        f"version: {version}\n"
        "publish_to: none\n"
        "repository: https://github.com/lengsukq/multi-video\n"
        "environment:\n"
        "  sdk: ^3.12.0\n"
        "  flutter: '>=3.47.0'\n"
        f"dependencies:\n{dep_lines}\n"
    )
    trtc_wasm = "assets/bundled/flutter_realtime_provider_trtc/trtc-assets/audioProcessor-wasm.js"
    if (destination / trtc_wasm).is_file():
        pubspec += f"false_secrets:\n  - /{trtc_wasm}\n"

    pubspec += "flutter:\n  uses-material-design: true\n"
    if assets:
        pubspec += "  assets:\n" + "\n".join(assets) + "\n"
    if font_declarations:
        pubspec += font_declarations
    (destination / "pubspec.yaml").write_text(pubspec, encoding="utf-8")


def _write_bundle_smoke(destination: Path, bundle_id: str, bundle_cfg: dict) -> None:
    tool_dir = destination / "tool"
    tool_dir.mkdir(exist_ok=True)
    kind = bundle_cfg["kind"]
    factory = bundle_cfg.get("factorySymbol")
    if kind == "core":
        smoke = (
            "import 'package:flutter/material.dart';\n"
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "Widget checkCoreSurface(RealtimeRoom room) => RealtimeRoomView(\n"
            "  room: room,\n"
            "  config: const RealtimeRoomViewConfig(),\n"
            ");\n"
            "const List<RealtimeFeaturePlugin<Object>> checkPresets = [\n"
            "  ClassroomPreset(),\n"
            "  LivePreset(),\n"
            "  SharedContentPreset(),\n"
            "];\n"
        )
    elif kind in ("provider", "chat_provider") and factory:
        smoke = (
            f"// Single-import developer experience verification for {bundle_id}.\n"
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "Realtime checkSingleImportFacade() => Realtime(\n"
            "  backendUrl: 'https://example.invalid',\n"
            f"  providers: [{factory}()],\n"
            "  featurePlugins: const [ClassroomPreset(), LivePreset()],\n"
            ");\n"
        )
    elif bundle_id.endswith("_effects"):
        smoke = (
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "const RealtimeRoomServices checkEffectsService = RealtimeRoomServices(\n"
            "  videoEffectsFactory: DefaultRealtimeVideoEffects.new,\n"
            ");\n"
        )
    else:
        smoke = (
            f"import 'package:{bundle_id}/{bundle_id}.dart';\n\n"
            "const RealtimeFeaturePlugin<Object> checkAnnotationPreset =\n"
            "    SystemAnnotationPreset();\n"
        )
    (tool_dir / "bundle_smoke.dart").write_text(smoke, encoding="utf-8")


def _assemble_all_meta_bundle(
    root: Path,
    out_dir: Path,
    spec: dict,
    *,
    version: str,
    use_path_siblings: bool,
) -> dict:
    all_id = spec["allBundle"]
    destination = out_dir / all_id
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "lib").mkdir(parents=True)
    for filename in ("LICENSE", "CHANGELOG.md"):
        shutil.copy2(root / "packages" / "flutter_realtime_sdk" / filename, destination / filename)

    bundle_ids = list(spec["bundles"].keys())
    exports = "".join(f"export 'package:{b}/{b}.dart';\n" for b in bundle_ids)
    (destination / "lib" / f"{all_id}.dart").write_text(
        "// GENERATED ALL-PROVIDERS CONVENIENCE META-PACKAGE.\nlibrary;\n\n" + exports,
        encoding="utf-8",
    )
    dep_lines = ["  flutter:\n    sdk: flutter"]
    for b in bundle_ids:
        if use_path_siblings:
            dep_lines.append(f"  {b}:\n    path: ../{b}")
        else:
            dep_lines.append(f"  {b}: ^{version}")
    pubspec = (
        f"name: {all_id}\n"
        "description: Convenience meta-package aggregating flutter_realtime_sdk and all optional provider/effect bundles.\n"
        f"version: {version}\n"
        "publish_to: none\n"
        "repository: https://github.com/lengsukq/multi-video\n"
        "environment:\n"
        "  sdk: ^3.12.0\n"
        "  flutter: '>=3.47.0'\n"
        "dependencies:\n" + "\n".join(dep_lines) + "\n"
        "flutter:\n  uses-material-design: true\n"
    )
    (destination / "pubspec.yaml").write_text(pubspec, encoding="utf-8")
    return {
        "bundle": all_id,
        "kind": "meta",
        "target": str(destination),
        "dartLibraries": 1,
        "externalDependencies": [],
        "siblingDependencies": bundle_ids,
    }


def assemble_bundles(
    root: Path = ROOT,
    out_dir: Path = DEFAULT_OUT,
    *,
    selected_bundles: list[str] | None = None,
    version: str = "0.2.0-dev.1",
    use_path_siblings: bool = True,
    include_all_meta: bool = True,
) -> dict:
    spec = load_bundle_manifest(root)
    owners = module_owner_map(spec)
    all_internal = set(owners.keys())
    core_bundle = spec["coreBundle"]

    out_dir = out_dir.resolve()
    allowed_prefix = (root / "build").resolve()
    if allowed_prefix not in out_dir.parents and out_dir != allowed_prefix:
        raise ValueError("Bundle output must stay inside ignored build/ directory")
    out_dir.mkdir(parents=True, exist_ok=True)

    order = topological_bundle_order(spec)
    if selected_bundles:
        wanted = set(selected_bundles)
        # Always ensure sibling dependencies of requested bundles are built too
        # when path-linking locally.
        if use_path_siblings:
            for b in list(wanted):
                if b in spec["bundles"]:
                    wanted.update(spec["bundles"][b].get("siblingDependencies", []))
        order = [b for b in order if b in wanted]

    reports: dict[str, dict] = {}
    for bundle_id in order:
        cfg = spec["bundles"][bundle_id]
        dest = out_dir / bundle_id
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)

        dart_count = _copy_bundle_dart_tree(
            root,
            dest,
            bundle_id=bundle_id,
            bundle_cfg=cfg,
            core_bundle=core_bundle,
            owners=owners,
        )
        assets, asset_modules = _copy_bundle_assets(
            root,
            dest,
            bundle_id=bundle_id,
            owned_modules=cfg["ownedModules"],
        )
        fonts, rewritten_fonts = _copy_bundle_fonts(
            root,
            dest,
            bundle_id=bundle_id,
            owned_modules=cfg["ownedModules"],
        )
        entrypoints = _write_entrypoints(
            dest,
            bundle_id=bundle_id,
            bundle_cfg=cfg,
            core_bundle=core_bundle,
        )
        external = collect_external_dependencies(root, cfg["ownedModules"], all_internal)
        _write_bundle_pubspec(
            dest,
            bundle_id=bundle_id,
            bundle_cfg=cfg,
            external_deps=external,
            assets=assets,
            font_declarations=fonts,
            version=version,
            use_path_siblings=use_path_siblings,
        )
        _write_bundle_smoke(dest, bundle_id, cfg)
        (dest / "README.md").write_text(
            f"# {bundle_id}\n\n{cfg['description']}\n",
            encoding="utf-8",
        )
        reports[bundle_id] = {
            "bundle": bundle_id,
            "kind": cfg["kind"],
            "target": str(dest),
            "ownedModules": cfg["ownedModules"],
            "dartLibraries": dart_count,
            "assetModules": asset_modules,
            "bundledFonts": bool(fonts),
            "fontFilesRewritten": rewritten_fonts,
            "entrypoints": entrypoints,
            "externalDependencies": sorted(k for k in external if k != "flutter"),
            "siblingDependencies": cfg.get("siblingDependencies", []),
        }

    if include_all_meta and selected_bundles is None:
        all_report = _assemble_all_meta_bundle(
            root,
            out_dir,
            spec,
            version=version,
            use_path_siblings=use_path_siblings,
        )
        reports[all_report["bundle"]] = all_report

    summary = {
        "outputRoot": str(out_dir),
        "version": version,
        "usePathSiblings": use_path_siblings,
        "bundleCount": len(reports),
        "bundles": reports,
    }
    (out_dir / "BUNDLES_REPORT.json").write_text(
        json.dumps(summary, indent=2) + "\n",
        encoding="utf-8",
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", action="append", dest="bundles", help="Specific bundle ID(s) to assemble")
    parser.add_argument("--version", default="0.2.0-dev.1")
    parser.add_argument("--hosted-siblings", action="store_true", help="Emit hosted ^version sibling dependencies instead of local ../ path dependencies")
    parser.add_argument("--no-all-meta", action="store_true", help="Skip generating flutter_realtime_sdk_all")
    args = parser.parse_args()

    summary = assemble_bundles(
        ROOT,
        DEFAULT_OUT,
        selected_bundles=args.bundles,
        version=args.version,
        use_path_siblings=not args.hosted_siblings,
        include_all_meta=not args.no_all_meta,
    )
    print(json.dumps({
        "outputRoot": summary["outputRoot"],
        "bundleCount": summary["bundleCount"],
        "bundles": {
            k: {
                "dartLibraries": v["dartLibraries"],
                "externalDependencies": v["externalDependencies"],
            }
            for k, v in summary["bundles"].items()
        },
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
