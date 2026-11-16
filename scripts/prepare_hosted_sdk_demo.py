#!/usr/bin/env python3
"""Prepare an isolated copy of example/ that consumes the hosted one-package SDK.

This is a source-to-source smoke host, not a second SDK publication. It leaves
the development Demo, local credentials, and all tracked artifacts untouched.
"""

import argparse
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "example"
DESTINATION = ROOT / "build" / "hosted_sdk_demo"
STAMP = "HOSTED_SDK_DEMO.txt"
SDK_IMPORT = "import 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';"
VERSION = re.compile(r"0\.1\.0-dev\.[1-9]\d*")


def ignore(directory: str, names: list[str]) -> set[str]:
    ignored = {
        ".dart_tool", ".gradle", ".symlinks", "Pods", "build", "ephemeral",
        ".DS_Store", "local.properties", "Podfile.lock", ".flutter-plugins",
        ".flutter-plugins-dependencies", ".env", ".env.local",
    }
    ignored.update(name for name in names if name.endswith((".jks", ".keystore", ".p12", ".mobileprovision")))
    return set(names) & ignored


def prepare(version: str) -> Path:
    if VERSION.fullmatch(version) is None:
        raise ValueError("Expected an exact preview version: 0.1.0-dev.N")
    if DESTINATION.exists():
        if not (DESTINATION / STAMP).exists():
            raise RuntimeError("Refusing to replace an unmarked Demo folder")
        shutil.rmtree(DESTINATION)
    DESTINATION.mkdir(parents=True)
    for name in ("lib", "assets", "android", "ios", "macos", "windows", "linux", "web"):
        src = SOURCE / name
        if src.is_dir():
            shutil.copytree(src, DESTINATION / name, ignore=ignore)
    shutil.copy2(ROOT / "analysis_options.sdk.yaml", DESTINATION / "analysis_options.sdk.yaml")
    (DESTINATION / "analysis_options.yaml").write_text(
        "include: analysis_options.sdk.yaml\n", encoding="utf-8"
    )

    changed = 0
    for path in (DESTINATION / "lib").rglob("*.dart"):
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        new_lines: list[str] = []
        sdk_seen = False
        for line in lines:
            if re.match(r"^import 'package:flutter_realtime_[a-z0-9_]+/[^']+';$", line.rstrip("\n")):
                if not sdk_seen:
                    new_lines.append(SDK_IMPORT + "\n")
                    sdk_seen = True
                changed += 1
            else:
                new_lines.append(line)
        path.write_text("".join(new_lines), encoding="utf-8")

    (DESTINATION / "pubspec.yaml").write_text(
        "name: multi_video\n"
        "description: Isolated host demo testing the published Flutter Realtime SDK.\n"
        "version: 1.0.0+1\n"
        "publish_to: none\n"
        "environment:\n"
        "  sdk: '>=3.12.0 <4.0.0'\n"
        "  flutter: '>=3.47.0'\n"
        "dependencies:\n"
        "  flutter:\n"
        "    sdk: flutter\n"
        f"  flutter_realtime_sdk: {version}\n"
        "  cupertino_icons: ^1.0.2\n"
        "  shared_preferences: ^2.5.3\n"
        "  url_launcher: ^6.3.3\n"
        "dev_dependencies:\n"
        "  flutter_test:\n"
        "    sdk: flutter\n"
        "  lints: ^5.0.0\n"
        "flutter:\n"
        "  config:\n"
        "    enable-swift-package-manager: true\n"
        "  uses-material-design: true\n"
        "  assets:\n"
        "    - assets/backgrounds/\n",
        encoding="utf-8",
    )
    (DESTINATION / STAMP).write_text(
        f"Hosted SDK Demo: flutter_realtime_sdk {version}\n"
        f"Adapted {changed} package imports from example/lib.\n"
        "Generated inside ignored build/; the source Demo is unchanged.\n",
        encoding="utf-8",
    )
    return DESTINATION


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    print(prepare(args.version))
