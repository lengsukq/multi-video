"""Ensure staging never uploads vendor frameworks or changes source modules."""
import json
import pathlib
import sys
import tempfile
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from prepare_single_sdk_release import (
    prepare,
    refresh_readmes,
    verify_staged,
)


class ReleasePreparationTest(unittest.TestCase):
    def test_latest_notes_and_safe_verification_preserve_staged_sources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            source = root / "build/single_sdk_candidate"
            for name, value in {
                "pubspec.yaml": "name: flutter_realtime_sdk\nversion: 0.1.0\npublish_to: none\n",
                "ios/vendor_frameworks.json": "{}",
                "ios/vendor_frameworks.rb": "# resolver",
                "ios/podfile.rb": "# helper",
                "ios/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "macos/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "LICENSE": "MIT",
                "lib/flutter_realtime_sdk.dart": "// do not change source",
            }.items():
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value)
            templates = root / "scripts/templates"
            templates.mkdir(parents=True)
            (templates / "single_sdk_README.md").write_text("@VERSION@")
            (templates / "single_sdk_README.zh-CN.md").write_text("@VERSION@")
            (templates.parent / "release_notes_current.md").write_text(
                "## 0.1.0-dev.27\n\n- Owners close meetings for everyone.\n"
            )
            release = prepare("0.1.0-dev.27", root)
            dart_source = (release / "lib/flutter_realtime_sdk.dart").read_bytes()
            changelog = (release / "CHANGELOG.md").read_text()
            self.assertIn("Owners close meetings for everyone", changelog)
            self.assertNotIn("dev.16", changelog)
            self.assertEqual((release / "lib/flutter_realtime_sdk.dart").read_bytes(), dart_source)
            self.assertEqual((release / "CHANGELOG.md").read_text(), changelog)
            self.assertEqual(verify_staged("0.1.0-dev.27", root), release)
            with self.assertRaisesRegex(ValueError, "Update"):
                prepare("0.1.0-dev.28", root)
            self.assertFalse((root / "build/pub_release/0.1.0-dev.28").exists())

    def test_preview_excludes_local_artifacts_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            candidate = root / "build/single_sdk_candidate"
            files = {
                "pubspec.yaml": "name: flutter_realtime_sdk\nversion: 0.1.0\npublish_to: none\n",
                "ios/vendor_frameworks.json": '{"frameworks": []}',
                "ios/vendor_frameworks.rb": "# resolver",
                "ios/podfile.rb": "# integration",
                "ios/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "macos/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "LICENSE": "MIT",
                ".pubignore": "/ios/Frameworks/\n.dart_tool/\n",
                "lib/flutter_realtime_sdk.dart": "// entry",
                "ios/Frameworks/AmazonIVS.xcframework/Info.plist": "vendor binary metadata",
                ".dart_tool/package_config.json": "local paths",
                ".git/config": "local repository",
                "tool/single_import_smoke.dart": "// internal assembly-only smoke test",
                "tool/setup_ios_broadcast_extension.rb": "# public ReplayKit installer",
                "pubspec.lock": "local resolution",
            }
            for name, contents in files.items():
                path = candidate / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            template = root / "scripts/templates/single_sdk_README.md"
            template.parent.mkdir(parents=True)
            template.write_text("Preview @VERSION@")
            template_zh = root / "scripts/templates/single_sdk_README.zh-CN.md"
            template_zh.write_text("预览版 @VERSION@\n[English](README.md)\n")
            (template.parent.parent / "release_notes_current.md").write_text(
                "## 0.1.0-dev.28\n\n- Reviewed next-preview changes.\n"
            )

            release = prepare("0.1.0-dev.28", root)
            self.assertEqual((candidate / "pubspec.yaml").read_text(), files["pubspec.yaml"])
            self.assertNotIn("publish_to:", (release / "pubspec.yaml").read_text())
            self.assertIn("version: 0.1.0-dev.28", (release / "pubspec.yaml").read_text())
            self.assertEqual((release / "README.md").read_text(), "Preview 0.1.0-dev.28")
            self.assertIn("预览版 0.1.0-dev.28", (release / "README.zh-CN.md").read_text())
            for excluded in ("ios/Frameworks", ".dart_tool",
                             "tool/single_import_smoke.dart", "pubspec.lock"):
                self.assertFalse((release / excluded).exists(), excluded)
            self.assertEqual(
                (release / "tool/setup_ios_broadcast_extension.rb").read_text(),
                "# public ReplayKit installer",
            )
            inventory = json.loads((release.parent / "FILES.sha256.json").read_text())
            self.assertIn("ios/vendor_frameworks.json", inventory)
            self.assertIn("README.md", inventory)
            self.assertIn("README.zh-CN.md", inventory)
            self.assertIn("tool/setup_ios_broadcast_extension.rb", inventory)
            self.assertNotIn(".git/config", inventory)
            self.assertFalse(any(name.startswith("ios/Frameworks/") for name in inventory))
            with self.assertRaises(FileExistsError):
                prepare("0.1.0-dev.28", root)

            # Updating staged documentation leaves Dart, native and package
            # metadata byte-for-byte intact, even after dependency resolution.
            (release / "pubspec.lock").write_text("transient")
            (release / ".dart_tool").mkdir()
            (release / ".dart_tool/package_config.json").write_text("{}")
            native_cache = release / "ios/Frameworks/AmazonIVS.xcframework/Info.plist"
            native_cache.parent.mkdir(parents=True)
            native_cache.write_text("verified pod-install download, not a publishable file")
            original_pubspec = (release / "pubspec.yaml").read_bytes()
            original_licenses = (release / "LICENSE").read_bytes()
            template.write_text("Updated English @VERSION@\n[简体中文](README.zh-CN.md)\n")
            template_zh.write_text("更新中文 @VERSION@\n[English](README.md)\n")
            self.assertEqual(refresh_readmes("0.1.0-dev.28", root), release)
            self.assertIn("Updated English 0.1.0-dev.28", (release / "README.md").read_text())
            self.assertIn("更新中文 0.1.0-dev.28", (release / "README.zh-CN.md").read_text())
            self.assertEqual((release / "pubspec.yaml").read_bytes(), original_pubspec)
            self.assertEqual((release / "LICENSE").read_bytes(), original_licenses)
            revised = json.loads((release.parent / "FILES.sha256.json").read_text())
            self.assertNotIn("pubspec.lock", revised)
            self.assertNotIn(".dart_tool/package_config.json", revised)
            self.assertFalse(any(name.startswith("ios/Frameworks/") for name in revised))
            self.assertIn("README.zh-CN.md", revised)
            self.assertEqual(
                json.loads((release.parent / "PREPARATION.json").read_text())["fileCount"],
                len(revised),
            )
            # A canceled publishing prompt is resumable without rebuilding.
            # Dependency cache files must not invalidate the immutable stage.
            self.assertEqual(verify_staged("0.1.0-dev.28", root), release)
            original_readme = (release / "README.md").read_text()
            (release / "README.md").write_text("tampered")
            with self.assertRaisesRegex(ValueError, "README.md"):
                verify_staged("0.1.0-dev.28", root)
            (release / "README.md").write_text(original_readme)
            (release / "unexpected_file.txt").write_text("not in inventory")
            with self.assertRaisesRegex(ValueError, "unexpected_file.txt"):
                verify_staged("0.1.0-dev.28", root)
            (release / "unexpected_file.txt").unlink()
            self.assertEqual(verify_staged("0.1.0-dev.28", root), release)

    def test_changelog_contains_only_matching_current_release_notes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            candidate = root / "build/single_sdk_candidate"
            files = {
                "pubspec.yaml": "name: flutter_realtime_sdk\nversion: 0.1.0\npublish_to: none\n",
                "ios/vendor_frameworks.json": '{"frameworks": []}',
                "ios/vendor_frameworks.rb": "# resolver",
                "ios/podfile.rb": "# integration",
                "ios/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "macos/flutter_realtime_sdk.podspec": "s.version = '0.1.0'",
                "LICENSE": "MIT",
                "lib/flutter_realtime_sdk.dart": "// entry",
            }
            for name, contents in files.items():
                path = candidate / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            template = root / "scripts/templates/single_sdk_README.md"
            template.parent.mkdir(parents=True)
            template.write_text("Preview @VERSION@")
            template_zh = root / "scripts/templates/single_sdk_README.zh-CN.md"
            template_zh.write_text("预览版 @VERSION@")
            (template.parent.parent / "release_notes_current.md").write_text(
                "## 0.1.0-dev.27\n\n- Room owners end the whole meeting.\n"
            )

            release = prepare("0.1.0-dev.27", root)
            changelog = (release / "CHANGELOG.md").read_text()

            self.assertIn("## 0.1.0-dev.27", changelog)
            self.assertIn("Room owners end the whole meeting", changelog)
            self.assertNotIn("## 0.1.0-dev.10", changelog)
            metadata = json.loads((release.parent / "PREPARATION.json").read_text())
            self.assertEqual(metadata["version"], "0.1.0-dev.27")
            self.assertFalse(metadata["published"])

    def test_stable_release_requires_a_separate_acceptance_decision(self):
        with self.assertRaises(ValueError):
            prepare("0.1.0")


if __name__ == "__main__":
    unittest.main()
