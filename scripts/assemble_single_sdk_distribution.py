#!/usr/bin/env python3
"""Build the reproducible ONE-package Flutter SDK distribution candidate.

All output stays under ignored build/single_sdk_candidate. The generated
distribution remains publish_to:none until all native release gates pass.
"""

import json
import subprocess
from pathlib import Path

from assemble_single_sdk_candidate import assemble
from assemble_single_sdk_android import run as android
from assemble_single_sdk_ios import run as ios
from assemble_single_sdk_macos import run as macos
from assemble_single_sdk_desktop import run as desktop
from audit_single_pub_package import ROOT


def build() -> dict:
    dest = ROOT / "build" / "single_sdk_candidate"
    report = assemble(ROOT, dest)
    native = {"android": android(), "ios": ios(), "macos": macos(), "desktop": desktop()}
    entry = (dest / "pubspec.yaml").read_text()
    assert "publish_to: none" in entry
    assert "    path:" not in entry and "    git:" not in entry
    for platform in ("android", "ios", "macos", "windows", "linux", "web"):
        assert f"      {platform}:" in entry, f"Missing {platform} plugin configuration"
    # Isolate the generated publication checkout from the parent repository's
    # /build ignore rules. This nested repository is disposable and never
    # touches the development repository's Git index/commits.
    subprocess.run(["git", "init", "--quiet"], cwd=dest, check=True)
    # Pub collects files using .gitignore in ancestor directories unless a
    # package-root .pubignore overrides them. The repository ignores /build/.
    (dest / ".pubignore").write_text(
        ".dart_tool/\n"
        ".flutter-plugins\n"
        ".flutter-plugins-dependencies\n"
        "pubspec.lock\n"
        "/tool/single_import_smoke.dart\n"
        "ASSEMBLY_REPORT.json\n"
        "/ios/Frameworks/\n"
    )
    report.update({
        "native": native,
        "nativePluginRegistrationGenerated": True,
        "nativePluginRegistrationComplete": False,
        "publishable": False,
        "releaseBlockers": [
            "Android Hyphenate AAR duplicate libaosl.so is stripped in the generated plugin, but real vendor E2E must confirm ABI compatibility.",
            "iOS uses SHA-256 pinned IVS archives; configure the shipped Podfile hook and validate each release's device-target build.",
            "Independent device/E2E verification and all six platform compilation are incomplete.",
            "Vendor binary redistribution and WebRTC fork licensing have not been cleared.",
            "Run pub.dev dry-run against this exact generated artifact; it does not validate native runtime or redistribution rights.",
        ],
    })
    (dest / "ASSEMBLY_REPORT.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    result = build()
    print(json.dumps({
        "path": result["target"],
        "dartLibraries": result["dartLibraries"],
        "assetModules": result["assetModules"],
        "platforms": [result["native"][name]["platform"] for name in ("android","ios","macos")],
        "desktopPlatforms": result["native"]["desktop"]["platforms"],
        "publishable": result["publishable"],
        "blockers": result["releaseBlockers"],
    }, indent=2))
