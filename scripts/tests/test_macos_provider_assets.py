"""Regression tests for provider package assets in macOS desktop builds."""

import tempfile
import unittest
from pathlib import Path

from scripts import check_macos_provider_assets as checker


class MacosProviderAssetsTest(unittest.TestCase):
    def test_aws_native_bridge_uses_separate_provider_packages(self):
        source = (checker.ROOT /
                  'packages/flutter_realtime_media_aws_desktop/macos/'
                  'flutter_realtime_media_aws_desktop/Sources/'
                  'flutter_realtime_media_aws_desktop/'
                  'FlutterRealtimeMediaAwsDesktopPlugin.swift').read_text()
        for snippet in (
            'vendorAsset = "assets/chime-sdk.js"',
            'vendorAsset = "assets/amazon-ivs-web-broadcast.js"',
            'fromPackage: "flutter_realtime_provider_aws"',
            '"assets/media-provider-bridge.js",\n        fromPackage: "flutter_realtime_media_web"',
            '"assets/ivs-chat-provider.js",\n      fromPackage: "flutter_realtime_provider_ivs_chat"',
            'fromPackage: package',
        ):
            self.assertIn(snippet, source)
        self.assertNotIn('fromPackage: "flutter_realtime_sdk"', source)
        self.assertNotIn('assets/provider_web_runtime/', source)

    def test_all_provider_dart_asset_paths_exist_in_their_packages(self):
        assets = checker.expected_assets()
        self.assertTrue(checker.AWS_DESKTOP_SCRIPTS <= assets)
        # Includes the JS runtime of Agora/TRTC/ARTC and all product chats.
        self.assertGreaterEqual(len(assets), 10)
        for asset in assets:
            with self.subTest(asset=asset):
                self.assertTrue((checker.ROOT / asset).is_file(), asset)

    def test_missing_assets_report_all_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Demo.app'
            self.assertEqual(checker.missing_assets(app), sorted(checker.expected_assets()))
            with self.assertRaisesRegex(RuntimeError, 'missing .* provider runtime asset'):
                checker.verify_assets(app)

            flutter_assets = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets'
            for path in checker.expected_assets():
                asset = flutter_assets / path
                asset.parent.mkdir(parents=True, exist_ok=True)
                asset.write_bytes(b'// test')
            checker.verify_assets(app)


if __name__ == '__main__':
    unittest.main()
