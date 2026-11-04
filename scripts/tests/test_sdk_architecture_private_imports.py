"""Guard the narrowly scoped vendor-private imports used by the SDK."""

import runpy
import unittest
from pathlib import Path


CHECKER = Path(__file__).resolve().parents[1] / 'check_sdk_architecture.py'


class PrivateImportBoundariesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The architecture assertions run as part of loading the checker.
        cls.allows = staticmethod(runpy.run_path(str(CHECKER))['allows_private_import'])

    def test_only_the_specific_legacy_broadcast_manager_import_is_exempt(self):
        source = 'flutter_realtime_media_livekit/lib/src/livekit_media_session.dart'
        self.assertTrue(self.allows('flutter_realtime_media_livekit', source,
                                    'livekit_client/src/managers/broadcast_manager.dart'))
        self.assertFalse(self.allows('flutter_realtime_media_livekit', source,
                                     'livekit_client/src/managers/other_manager.dart'))
        self.assertFalse(self.allows('flutter_realtime_media_livekit',
                                     'flutter_realtime_media_livekit/lib/src/unrelated.dart',
                                     'livekit_client/src/managers/broadcast_manager.dart'))

    def test_existing_native_webrtc_exception_is_exact(self):
        source = 'flutter_realtime_media_livekit/lib/src/livekit_processed_video_native.dart'
        self.assertTrue(self.allows('flutter_realtime_media_livekit', source,
                                    'flutter_webrtc/src/native/media_stream_impl.dart'))
        self.assertFalse(self.allows('flutter_realtime_media_livekit', source,
                                     'flutter_webrtc/src/native/another.dart'))

    def test_same_package_private_imports_remain_valid(self):
        self.assertTrue(self.allows('flutter_realtime_media_livekit',
                                    'flutter_realtime_media_livekit/lib/public.dart',
                                    'flutter_realtime_media_livekit/src/local.dart'))


if __name__ == '__main__':
    unittest.main()
