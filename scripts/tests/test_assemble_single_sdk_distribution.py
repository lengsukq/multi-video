"""Release-candidate generation and integration wiring regression tests.

These tests never publish or access vendor cloud credentials.
"""

import pathlib
import sys
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from assemble_single_sdk_distribution import build
from verify_single_sdk_web_assets import verify


class SingleSdkDistributionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = build()
        cls.root = pathlib.Path(cls.report["target"])

    def test_bundled_runtime_scripts_are_valid_javascript(self):
        verify(self.root)

    def test_one_hosted_dependency_surface(self):
        pubspec = (self.root / "pubspec.yaml").read_text()
        self.assertIn("publish_to: none", pubspec)
        self.assertIn("repository: https://github.com/", pubspec)
        self.assertNotIn("    path:", pubspec)
        self.assertNotIn("    git:", pubspec)
        self.assertTrue((self.root / "LICENSE").is_file())
        self.assertTrue((self.root / "CHANGELOG.md").is_file())
        self.assertTrue((self.root / ".git").is_dir())
        self.assertTrue((self.root / ".pubignore").is_file())
        self.assertFalse(self.report["publishable"])

    def test_native_distribution_excludes_python_bytecode_and_cache(self):
        # A source-machine __pycache__ must never leak into the pub.dev zip.
        for path in self.root.rglob("*"):
            if path.is_file():
                self.assertNotIn("__pycache__", path.parts)
                self.assertNotIn(path.suffix, {".pyc", ".pyo"})

    def test_distribution_exposes_current_pages_without_legacy_templates(self):
        # Validate the supported surface; removing obsolete pages legitimately
        # lowers the library count and must not require keeping dead modules.
        bundled = self.root / "lib/src/_bundled/flutter_realtime_sdk_ui"
        public_ui = (bundled / "flutter_realtime_sdk_ui.dart").read_text()
        for module in ("realtime_room_view", "realtime_meeting_page", "realtime_live_page",
                       "realtime_pre_join_page", "realtime_chat_page", "realtime_room_view_config",
                       "realtime_room_ui_overlay"):
            self.assertIn(f"export 'src/{module}.dart';", public_ui)
            self.assertTrue((bundled / f"src/{module}.dart").is_file())
        for removed in ("realtime_composable_template", "legacy_room_content_controls"):
            self.assertFalse((bundled / f"src/{removed}.dart").exists())
        media = self.root / "lib/src/_bundled/flutter_realtime_media_ui/src"
        for removed in ("media_room_view", "media_pre_join_dialog", "realtime_chat_view",
                        "composable_pre_join_template", "media_room_view_config"):
            self.assertFalse((media / f"{removed}.dart").exists())
        smoke = (self.root / "tool/single_import_smoke.dart").read_text()
        for symbol in ("RealtimeRoomViewConfig", "RealtimePreJoinEnter", "RealtimePreJoinPage", "RealtimeChatPage"):
            self.assertIn(symbol, smoke)

    def test_single_public_entry_supports_headless_video_effects(self):
        entry = (self.root / "lib/flutter_realtime_sdk.dart").read_text()
        self.assertIn("show DefaultRealtimeVideoEffects;", entry)
        smoke = (self.root / "tool/single_import_smoke.dart").read_text()
        self.assertIn("DefaultRealtimeVideoEffects.new", smoke)
        room = (self.root / "lib/src/_bundled/flutter_realtime_sdk_runtime/src/realtime_room.dart").read_text()
        self.assertIn("Future<void> setCameraEnabled(bool enabled)", room)

    def test_web_video_effects_nested_assets_and_runtime_urls(self):
        """An external single-package Web build needs scripts AND nested models."""
        prefix = "assets/bundled/flutter_realtime_video_effects/web/"
        manifest = (self.root / "pubspec.yaml").read_text()
        required = (
            "vision.js",
            "video-effects-bridge.js",
            "models/selfie_segmenter_landscape.tflite",
            "models/blaze_face_short_range.tflite",
            "wasm/vision_wasm_internal.wasm",
            "wasm/vision_wasm_nosimd_internal.wasm",
            "wasm/vision_wasm_internal.js",
            "wasm/vision_wasm_nosimd_internal.js",
        )
        for item in required:
            file = self.root / prefix / item
            self.assertTrue(file.is_file(), f"Missing Web asset: {file}")
            # Flutter directory asset declarations are not recursive.
            # Require the precise parent for every bundled asset.
            self.assertIn(
                f"    - {file.parent.relative_to(self.root).as_posix()}/",
                manifest,
            )
        bridge = (self.root / prefix / "video-effects-bridge.js").read_text()
        self.assertIn(
            "assets/packages/flutter_realtime_sdk/assets/bundled/"
            "flutter_realtime_video_effects/web/",
            bridge,
        )
        self.assertNotIn(
            "assets/packages/flutter_realtime_video_effects/assets/web/",
            bridge,
        )
        loader = (
            self.root
            / "lib/src/_bundled/flutter_realtime_video_effects/src/"
            "video_effects_assets_web.dart"
        ).read_text()
        self.assertIn(
            "assets/packages/flutter_realtime_sdk/assets/bundled/"
            "flutter_realtime_video_effects/web/",
            loader,
        )

    def test_all_copied_assets_are_declared_in_the_generated_pubspec(self):
        """Protect new provider asset subdirectories from silent omissions."""
        pubspec = (self.root / "pubspec.yaml").read_text()
        for file in (self.root / "assets/bundled").rglob("*"):
            if not file.is_file():
                continue
            directory = file.parent.relative_to(self.root).as_posix()
            self.assertIn(f"    - {directory}/", pubspec, str(file))

    def test_bundled_fonts_are_packaged_and_resolved_from_the_single_package(self):
        """A folded design package must still find its own font files."""
        fonts = self.root / "fonts"
        expected = {
            "Onest-Regular.ttf",
            "Onest-Medium.ttf",
            "Onest-SemiBold.ttf",
            "Onest-Bold.ttf",
            "BricolageGrotesque-Medium.ttf",
            "BricolageGrotesque-Bold.ttf",
        }
        self.assertEqual({p.name for p in fonts.glob("*.ttf")}, expected)
        pubspec = (self.root / "pubspec.yaml").read_text()
        self.assertIn("  fonts:", pubspec)
        for family in ("Onest", "BricolageGrotesque"):
            self.assertIn(f"    - family: {family}", pubspec)
        for font in expected:
            self.assertIn(f"        - asset: fonts/{font}", pubspec)
        # Families must be addressed through the hosted package, not the
        # internal design package that no longer exists at runtime.
        theme = (
            self.root
            / "lib/src/_bundled/flutter_realtime_design_ui/src/realtime_ui_theme.dart"
        ).read_text()
        self.assertIn("packages/flutter_realtime_sdk/Onest", theme)
        self.assertIn("packages/flutter_realtime_sdk/BricolageGrotesque", theme)
        self.assertNotIn("packages/flutter_realtime_design_ui/Onest", theme)
        self.assertNotIn(
            "packages/flutter_realtime_design_ui/BricolageGrotesque", theme
        )
        self.assertTrue(self.report["bundledFonts"])
        self.assertGreaterEqual(self.report["fontFilesRewritten"], 1)

    def test_ios_resolves_official_binaries_without_nonexistent_pods(self):
        import json
        from assemble_single_sdk_ios import ivs_frameworks

        spec = (self.root / "ios/flutter_realtime_sdk.podspec").read_text()
        self.assertNotIn("s.dependency 'AmazonIVS", spec)
        self.assertIn("VendorFrameworks.install!(__dir__)", spec)
        self.assertIn("s.vendored_frameworks = 'Frameworks/*.xcframework'", spec)
        manifest = json.loads((self.root / "ios/vendor_frameworks.json").read_text())
        self.assertEqual(manifest["frameworks"], ivs_frameworks())
        self.assertEqual({item["name"] for item in manifest["frameworks"]},
                         {"AmazonIVSBroadcast", "AmazonIVSChatMessaging"})
        self.assertIn("/ios/Frameworks/", (self.root / ".pubignore").read_text())
        self.assertFalse((self.root / "ios/Frameworks").exists())

    def test_all_platform_registration_entries_are_present(self):
        pubspec = (self.root / "pubspec.yaml").read_text()
        self.assertEqual(self.report["native"]["android"]["registrations"], 10)
        self.assertEqual(self.report["native"]["macos"]["registrations"], 10)
        # iOS effects, processed frame hub and LiveKit publisher add three
        # iOS now registers Agora and TRTC processed-video provider plugins
        # alongside the existing Apple native effect pipeline.
        self.assertEqual(self.report["native"]["ios"]["registrations"], 9)
        for platform in ("android", "ios", "macos", "windows", "linux", "web"):
            self.assertIn(f"      {platform}:", pubspec)
        self.assertIn(
            "src/_bundled/flutter_realtime_video_effects/flutter_realtime_video_effects_web.dart",
            pubspec,
        )

    def test_android_merged_plugin_keeps_plugin_channels_and_jni(self):
        plugin = (
            self.root / "android/src/main/java/com/oneplusdream/"
            "flutter_realtime_sdk/FlutterRealtimeSdkPlugin.java"
        ).read_text()
        self.assertEqual(plugin.count("children.add(new "), 10)
        self.assertIn("onReattachedToActivityForConfigChanges", plugin)
        gradle = (self.root / "android/build.gradle").read_text()
        self.assertIn("hyphenate-chat-", gradle)
        self.assertIn("libaosl", gradle)
        self.assertIn("ivs-broadcast", gradle)
        self.assertIn("JVM_17", gradle)
        self.assertNotIn("pickFirst", gradle)

    def test_apple_and_desktop_registration_bridges(self):
        ios = (self.root / "ios/Classes/FlutterRealtimeSdkPlugin.swift").read_text()
        self.assertEqual(ios.count(".register(with: registrar)"), 9)
        mac = (self.root / "macos/Classes/FlutterRealtimeSdkPlugin.m").read_text()
        self.assertEqual(mac.count('@"FlutterRealtime'), 10)
        self.assertIn("FlutterRealtimeMediaAwsDesktopPlugin", mac)
        self.assertTrue((self.root / "windows/sdk_plugin_c_api.cpp").exists())
        windows_registrar = (
            self.root / "windows/sdk_plugin_c_api.cpp"
        ).read_text()
        self.assertIn(
            "FlutterRealtimeVideoEffectsPluginCApiRegisterWithRegistrar",
            windows_registrar,
        )
        for module, source in (
            ("livekit", "livekit_processed_video_plugin.cpp"),
            ("agora", "agora_processed_video_plugin.cpp"),
            ("trtc", "trtc_processed_video_plugin.cpp"),
        ):
            self.assertTrue((self.root / "windows" / module / source).is_file())
            self.assertIn(
                f"FlutterRealtimeMedia{module.title()}PluginCApiRegisterWithRegistrar",
                windows_registrar,
            )
        self.assertTrue(
            (self.root / "windows/effects/flutter_realtime_video_effects_plugin.cpp").exists()
        )
        self.assertTrue(
            (self.root / "windows/processed_video/include/processed_video_frame_hub.h").exists()
        )
        windows_cmake = (self.root / "windows/CMakeLists.txt").read_text()
        self.assertIn("effects/flutter_realtime_video_effects_plugin.cpp", windows_cmake)
        self.assertIn("realtime_effects_configure_ort", windows_cmake)
        ort_setup = (self.root / "windows/effects/onnxruntime.cmake").read_text()
        self.assertIn("REALTIME_ONNXRUNTIME_ROOT", ort_setup)
        self.assertIn("EXPECTED_HASH", ort_setup)
        self.assertIn("livekit/livekit_processed_video_plugin.cpp", windows_cmake)
        self.assertIn("agora/agora_processed_video_plugin.cpp", windows_cmake)
        self.assertIn("trtc/trtc_processed_video_plugin.cpp", windows_cmake)
        self.assertIn("AGORA_NATIVE_INCLUDE", windows_cmake)
        self.assertIn("TRTC_WINDOWS", windows_cmake)
        self.assertTrue(
            (self.root / "assets/bundled/flutter_realtime_video_effects/windows/pphumanseg.onnx").exists()
        )
        self.assertTrue(
            (self.root / "assets/bundled/flutter_realtime_video_effects/windows/PPHUMANSEG_LICENSE.txt").exists()
        )
        self.assertTrue((self.root / "linux/sdk_plugin.cc").exists())

    def test_known_generated_vendor_false_positive_is_precisely_scoped(self):
        expected = (
            "assets/bundled/flutter_realtime_provider_trtc/"
            "trtc-assets/audioProcessor-wasm.js"
        )
        self.assertTrue((self.root / expected).exists())
        pubspec = (self.root / "pubspec.yaml").read_text()
        self.assertIn(f"  - /{expected}", pubspec)


if __name__ == "__main__":
    unittest.main()
