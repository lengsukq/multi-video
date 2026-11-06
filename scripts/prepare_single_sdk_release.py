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


def prepare(version: str, root: Path = ROOT) -> Path:
    # Stable releases need a separate acceptance decision. This tool prepares
    # only an explicitly versioned preview, retaining pending evidence as such.
    if not re.fullmatch(r"0\.1\.0-dev\.[1-9][0-9]*", version):
        raise ValueError("Expected an explicit preview version: 0.1.0-dev.N")
    # One maintained release-notes file replaces all hardcoded historical
    # version branches. A mismatched heading blocks staging *before* copying
    # any sources, preventing stale notes from reaching a new publication.
    notes_path = root / "scripts/release_notes_current.md"
    notes = notes_path.read_text(encoding="utf-8").strip() + "\n"
    if not notes.startswith(f"## {version}\n"):
        raise ValueError(
            f"Update {notes_path} to begin with ## {version} before staging"
        )
    if not any(line.startswith("- ") for line in notes.splitlines()):
        raise ValueError(f"Release notes for {version} must list actual changes")
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
    (destination / "CHANGELOG.md").write_text(notes, encoding="utf-8")
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
    args = parser.parse_args()
    if args.verify and args.refresh_readmes:
        parser.error("--verify and --refresh-readmes are mutually exclusive")
    print(
        verify_staged(args.version) if args.verify
        else refresh_readmes(args.version) if args.refresh_readmes
        else prepare(args.version)
    )
