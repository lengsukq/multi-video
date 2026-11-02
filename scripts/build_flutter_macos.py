#!/usr/bin/env python3
"""Backward-compatible macOS launch/build alias for standard Flutter commands.

All Apple platforms use the same Demo and SwiftPM config. Never rewrite
pubspec.yaml, generated Xcode package references, or native plugin manifests.
Run flutter run -d macos directly from example/ for normal development.
"""

import re
import signal
import subprocess
import sys
from pathlib import Path


def run_flutter(project: Path, command: list[str], run=subprocess.run) -> int:
    manifest = (project / "pubspec.yaml").read_text()
    if not re.search(
        r"(?m)^\s+enable-swift-package-manager:\s*true\s*$", manifest
    ):
        raise ValueError(
            "Expected SwiftPM enabled in the shared Demo; refusing a stale "
            "CocoaPods-only configuration."
        )
    return run(command, cwd=project).returncode


def build(project: Path, args: list[str], run=subprocess.run) -> int:
    return run_flutter(
        project, ["flutter", "build", "macos", *(args or ["--release", "--no-pub"])], run
    )


def debug(project: Path, args: list[str], run=subprocess.run) -> int:
    return run_flutter(project, ["flutter", "run", "-d", "macos", *args], run)


def stop(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop)
    raise SystemExit(build(Path(__file__).resolve().parents[1] / "example", sys.argv[1:]))
