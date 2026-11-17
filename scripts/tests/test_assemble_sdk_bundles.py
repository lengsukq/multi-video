"""End-to-end unit tests for modular on-demand SDK bundle assembly and staging.

Verifies:
  1. All 44 workspace modules partition cleanly across the 11 modular bundles.
  2. Core `flutter_realtime_sdk` carries zero third-party RTC/IM vendor SDKs.
  3. Selecting one provider (`flutter_realtime_sdk_livekit`) preserves the
     one-import `Realtime` facade while excluding every other vendor's Dart,
     Maven, CocoaPods, CMake, and Web/WASM dependencies.
  4. Cross-bundle `processed_video` native linkage (Android `compileOnly`,
     Apple `import flutter_realtime_sdk` + pod dependency, Windows dynamic
     `flutter_realtime_sdk_effects_plugin.dll` lookup) and macOS AWS asset keys
     are accurately generated without mutating `packages/`.
  5. Lockstep staging (`prepare_bundles_release` + `verify_staged_bundles`)
     produces valid publishable manifests and SHA-256 inventories.
"""

import json
import pathlib
import shutil
import sys
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from assemble_sdk_bundles import load_bundle_manifest
from assemble_sdk_bundles_native import build_modular_distribution
from audit_single_pub_package import ROOT
from prepare_sdk_bundles_release import (
    prepare_bundles_release,
    verify_host_isolation,
    verify_staged_bundles,
)


class ModularSdkBundlesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.summary = build_modular_distribution(ROOT)
        cls.out = pathlib.Path(cls.summary["outputRoot"])

    def test_all_44_modules_are_partitioned_exactly_once(self):
        spec = load_bundle_manifest(ROOT)
        inventory = json.loads((ROOT / "scripts/sdk_packages.json").read_text())
        assigned = [
            mod
            for cfg in spec["bundles"].values()
            for mod in cfg["ownedModules"]
        ]
        self.assertEqual(len(assigned), 44)
        self.assertEqual(set(assigned), set(inventory))
        self.assertEqual(self.summary["bundleCount"], 12)  # 11 bundles + sdk_all

    def test_core_bundle_has_zero_vendor_rtc_or_im_dependencies(self):
        core = self.summary["bundles"]["flutter_realtime_sdk"]
        forbidden = {
            "livekit_client",
            "flutter_webrtc",
            "dart_webrtc",
            "agora_rtc_engine",
            "agora_chat_sdk",
            "tencent_rtc_sdk",
            "tencent_cloud_chat_sdk",
            "webview_flutter_windows",
        }
        self.assertEqual(set(core["externalDependencies"]) & forbidden, set())
        core_root = self.out / "flutter_realtime_sdk"
        self.assertTrue((core_root / "lib/flutter_realtime_sdk.dart").is_file())
        self.assertTrue((core_root / "lib/provider_spi.dart").is_file())
        self.assertTrue((core_root / "lib/media_web_spi.dart").is_file())
        self.assertTrue((core_root / "lib/chat_web_spi.dart").is_file())
        self.assertTrue((core_root / "ios/flutter_realtime_sdk/Package.swift").is_file())
        self.assertFalse((core_root / "ios/vendor_frameworks.json").exists())

    def test_livekit_host_isolation_excludes_all_other_vendors(self):
        report = verify_host_isolation(
            self.out,
            ["flutter_realtime_sdk_livekit"],
            ROOT,
        )
        self.assertEqual(
            report["resolvedBundles"],
            ["flutter_realtime_sdk", "flutter_realtime_sdk_livekit"],
        )
        for excluded in (
            "flutter_realtime_sdk_agora",
            "flutter_realtime_sdk_trtc",
            "flutter_realtime_sdk_artc",
            "flutter_realtime_sdk_aws",
            "flutter_realtime_sdk_agora_chat",
            "flutter_realtime_sdk_tencent_chat",
            "flutter_realtime_sdk_ivs_chat",
            "flutter_realtime_sdk_effects",
            "flutter_realtime_sdk_annotation",
        ):
            self.assertIn(excluded, report["excludedBundles"])

        for vendor_dep in (
            "agora_rtc_engine",
            "agora_chat_sdk",
            "tencent_rtc_sdk",
            "tencent_cloud_chat_sdk",
            "webview_flutter_windows",
        ):
            self.assertNotIn(vendor_dep, report["externalDependencies"])

        lk_entry = (
            self.out / "flutter_realtime_sdk_livekit/lib/flutter_realtime_sdk_livekit.dart"
        ).read_text()
        self.assertIn(
            "export 'package:flutter_realtime_sdk/flutter_realtime_sdk.dart';",
            lk_entry,
        )
        lk_win_cmake = (
            self.out / "flutter_realtime_sdk_livekit/windows/CMakeLists.txt"
        ).read_text()
        self.assertNotIn("AGORA_SDK_HEADERS", lk_win_cmake)
        self.assertNotIn("TRTC_WINDOWS", lk_win_cmake)
        self.assertNotIn("onnxruntime.cmake", lk_win_cmake)

    def test_vendor_native_quirks_are_strictly_confined_to_owning_bundles(self):
        artc_gradle = (self.out / "flutter_realtime_sdk_artc/android/build.gradle").read_text()
        livekit_gradle = (self.out / "flutter_realtime_sdk_livekit/android/build.gradle").read_text()
        self.assertIn("maven.aliyun.com", artc_gradle)
        self.assertNotIn("maven.aliyun.com", livekit_gradle)

        aws_gradle = (self.out / "flutter_realtime_sdk_aws/android/build.gradle").read_text()
        self.assertIn("ivs-broadcast", aws_gradle)
        self.assertNotIn("ivs-broadcast", livekit_gradle)

        aws_ios = json.loads(
            (self.out / "flutter_realtime_sdk_aws/ios/vendor_frameworks.json").read_text()
        )
        ivs_chat_ios = json.loads(
            (self.out / "flutter_realtime_sdk_ivs_chat/ios/vendor_frameworks.json").read_text()
        )
        self.assertEqual([x["name"] for x in aws_ios["frameworks"]], ["AmazonIVSBroadcast"])
        self.assertEqual([x["name"] for x in ivs_chat_ios["frameworks"]], ["AmazonIVSChatMessaging"])

        agora_chat_gradle = (
            self.out / "flutter_realtime_sdk_agora_chat/android/build.gradle"
        ).read_text()
        self.assertIn("io.agora.infra:aosl", agora_chat_gradle)
        self.assertTrue(
            (self.out / "flutter_realtime_sdk_agora_chat/android/consumer-rules.pro").is_file()
        )

    def test_cross_bundle_processed_video_and_asset_rewrites(self):
        effects_ios_swift = next(
            (
                self.out
                / "flutter_realtime_sdk_effects/ios/Classes/flutter_realtime_video_effects"
            ).rglob("*.swift")
        ).read_text()
        self.assertIn("import flutter_realtime_sdk", effects_ios_swift)
        self.assertNotIn("import flutter_realtime_processed_video", effects_ios_swift)
        agora_podspec = (
            self.out / "flutter_realtime_sdk_agora/ios/flutter_realtime_sdk_agora.podspec"
        ).read_text()
        self.assertIn("s.dependency 'flutter_realtime_sdk'", agora_podspec)

        lk_frame_client = (
            self.out
            / "flutter_realtime_sdk_livekit/windows/processed_video/include/processed_video_frame_client.h"
        ).read_text()
        self.assertIn('L"flutter_realtime_sdk_effects_plugin.dll"', lk_frame_client)

        effects_cpp = (
            self.out
            / "flutter_realtime_sdk_effects/windows/flutter_realtime_video_effects_plugin.cpp"
        ).read_text()
        self.assertIn('"flutter_realtime_sdk_effects" / "assets" / "bundled"', effects_cpp)

        effects_js = (
            self.out
            / "flutter_realtime_sdk_effects/assets/bundled/flutter_realtime_video_effects/web/video-effects-bridge.js"
        ).read_text()
        self.assertIn("assets/packages/flutter_realtime_sdk_effects/assets/bundled/", effects_js)

        aws_assets_dart = (
            self.out
            / "flutter_realtime_sdk_aws/lib/src/_bundled/flutter_realtime_provider_aws/src/assets.dart"
        ).read_text()
        self.assertIn(
            "assets/packages/flutter_realtime_sdk_aws/assets/bundled/flutter_realtime_provider_aws/chime-sdk.js",
            aws_assets_dart,
        )
        self.assertIn(
            "assets/packages/flutter_realtime_sdk/assets/bundled/flutter_realtime_media_web/media-provider-bridge.js",
            aws_assets_dart,
        )

        aws_macos_swift = next(
            (self.out / "flutter_realtime_sdk_aws/macos/Classes").rglob("FlutterRealtimeMediaAwsDesktopPlugin.swift")
        ).read_text()
        self.assertIn('"flutter_realtime_provider_aws": "flutter_realtime_sdk_aws"', aws_macos_swift)

    def test_lockstep_release_staging_and_sha256_verification(self):
        test_version = "0.99.0-dev.999"
        target_dir = ROOT / "build/pub_release" / test_version
        if target_dir.exists():
            shutil.rmtree(target_dir)
        self.addCleanup(lambda: shutil.rmtree(target_dir, ignore_errors=True))

        staged = prepare_bundles_release(test_version, ROOT)
        self.assertEqual(staged["publishOrder"][0], "flutter_realtime_sdk")
        self.assertEqual(staged["publishOrder"][-1], "flutter_realtime_sdk_all")
        self.assertEqual(len(staged["bundles"]), 12)

        verified = verify_staged_bundles(test_version, ROOT)
        self.assertEqual(verified["version"], test_version)
        lk_pubspec = (
            target_dir / "bundles/flutter_realtime_sdk_livekit/pubspec.yaml"
        ).read_text()
        self.assertIn(f"flutter_realtime_sdk: ^{test_version}", lk_pubspec)
        self.assertNotIn("publish_to:", lk_pubspec)
        self.assertNotIn("    path:", lk_pubspec)


if __name__ == "__main__":
    unittest.main()
