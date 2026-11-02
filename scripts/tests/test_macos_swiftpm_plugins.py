"""Keep the macOS SwiftPM migration and CocoaPods source compatibility intact."""

import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ROOT / "packages"
MIGRATED = (
    "flutter_realtime_chat_agora",
    "flutter_realtime_media_agora",
    "flutter_realtime_media_artc",
    "flutter_realtime_media_aws_desktop",
    "flutter_realtime_media_core",
    "flutter_realtime_media_livekit",
    "flutter_realtime_media_trtc",
    "flutter_realtime_screen_annotation",
)


class MacosSwiftPmTests(unittest.TestCase):
    def test_single_native_source_tree_supports_both_package_managers(self):
        for name in MIGRATED:
            with self.subTest(name=name):
                root = PACKAGES / name / "macos"
                native = root / name / "Sources" / name
                swift = (root / name / "Package.swift").read_text()
                podspec = (root / f"{name}.podspec").read_text()
                self.assertFalse((root / "Classes").exists())
                self.assertTrue(native.is_dir())
                self.assertIn(f'name: "{name}"', swift)
                self.assertIn(f'path: "Sources/{name}"', swift)
                self.assertIn('.product(name: "FlutterFramework"', swift)
                self.assertIn(f"{name}/Sources/{name}/", podspec)
                self.assertNotIn("'Classes/", podspec)

    def test_native_processed_video_sinks_share_one_spm_dependency(self):
        for name in ("flutter_realtime_media_agora", "flutter_realtime_media_trtc"):
            with self.subTest(name=name):
                manifest = (PACKAGES / name / "macos" / name / "Package.swift").read_text()
                self.assertIn(
                    '.product(name: "flutter-realtime-processed-video", '
                    'package: "flutter_realtime_processed_video")',
                    manifest,
                )

    def test_javascript_bundles_are_identical_across_managers(self):
        for name in ("flutter_realtime_chat_agora", "flutter_realtime_media_aws_desktop"):
            with self.subTest(name=name):
                root = PACKAGES / name / "macos"
                shared = root / name / "Sources" / name
                for legacy in (root / "Resources").iterdir():
                    mirrored = shared / "Resources" / legacy.name
                    self.assertTrue(mirrored.exists(), str(mirrored))
                    self.assertEqual(
                        hashlib.sha256(legacy.read_bytes()).digest(),
                        hashlib.sha256(mirrored.read_bytes()).digest(),
                    )
                native = "".join(p.read_text() for p in shared.glob("*.swift"))
                self.assertIn("Bundle.module", native)
                self.assertIn("SWIFT_PACKAGE", native)

    def test_both_platforms_use_one_flutter_application(self):
        pubspec = (ROOT / "example/pubspec.yaml").read_text()
        self.assertIn("enable-swift-package-manager: true", pubspec)
        self.assertFalse((ROOT / "example_macos").exists())
        self.assertIn("flutter run -d macos", (ROOT / "example/README.md").read_text())


if __name__ == "__main__":
    unittest.main()
