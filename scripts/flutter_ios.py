#!/usr/bin/env python3
"""Build/debug the iOS Demo, preparing native SwiftPM FlutterFramework shims.

SwiftPM is the Demo default. Do not modify pubspec.yaml here: temporarily
rewriting it races standard iOS commands and macOS development sessions.
"""
import re
import signal
import subprocess
import sys
from pathlib import Path

_FLUTTER_FRAMEWORK_PACKAGE = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FlutterFramework",
    platforms: [.iOS("15.0")],
    products: [.library(name: "FlutterFramework", targets: ["Flutter"])],
    targets: [.binaryTarget(name: "Flutter", path: "Flutter.xcframework")]
)
'''


def ensure_flutter_framework_dependencies(project: Path) -> None:
    """Repair missing local SwiftPM Flutter wrappers used by native plugins.

    Flutter only creates these wrappers for some plugins. Their Package.swift
    files still refer to ../FlutterFramework, so Xcode cannot resolve a fresh
    checkout unless the missing local binary packages are bootstrapped.
    """
    packages = project.parent / 'packages'
    plugin_manifests = list(packages.glob('*/ios/*/Package.swift'))
    required = [
        manifest.parent.parent / 'FlutterFramework'
        for manifest in plugin_manifests
        if '.package(name: "FlutterFramework", path: "../FlutterFramework")'
        in manifest.read_text()
    ]
    if not required:
        return
    generated = project / 'ios/Flutter/Generated.xcconfig'
    settings = generated.read_text() if generated.is_file() else ''
    match = re.search(r'(?m)^FLUTTER_ROOT=(.+)$', settings)
    if not match:
        raise RuntimeError('Run flutter pub get to generate ios/Flutter/Generated.xcconfig first.')
    framework = (Path(match.group(1).strip()) /
                 'bin/cache/artifacts/engine/ios/Flutter.xcframework')
    if not framework.exists():
        raise RuntimeError('Flutter iOS engine is missing. Run flutter precache --ios.')
    for folder in required:
        folder.mkdir(parents=True, exist_ok=True)
        package_manifest = folder / 'Package.swift'
        if not package_manifest.exists():
            package_manifest.write_text(_FLUTTER_FRAMEWORK_PACKAGE)
        binary = folder / 'Flutter.xcframework'
        if binary.is_symlink() and not binary.exists():
            binary.unlink()
        if not binary.exists():
            binary.symlink_to(framework, target_is_directory=True)


def run_ios(project: Path, args: list[str], run=subprocess.run) -> int:
    if not args or (args[0] != 'run' and args[:2] != ['build', 'ios']):
        raise ValueError('Use build ios [options] or run -d <iOS device> [options].')
    manifest = project / 'pubspec.yaml'
    if not re.search(r'(?m)^[ \t]+enable-swift-package-manager:[ \t]*true[ \t]*$', manifest.read_text()):
        raise ValueError('iOS requires enable-swift-package-manager: true in the Demo pubspec.yaml.')
    resolved = run(['flutter', 'pub', 'get', '--offline'], cwd=project)
    if resolved.returncode != 0:
        return resolved.returncode
    ensure_flutter_framework_dependencies(project)
    # The macOS Runner is also SwiftPM-based now. Never remove its generated
    # package integration when iOS exits, including after an interrupted run.
    return run(['flutter', *args], cwd=project).returncode


def stop(_signal, _frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, stop)
    raise SystemExit(run_ios(Path(__file__).resolve().parents[1] / 'example', sys.argv[1:]))
