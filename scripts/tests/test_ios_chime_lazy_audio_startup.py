"""Keep nonselected iOS Chime vendor registration free of audio-session reads."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHIME_COORDINATOR = (
    ROOT
    / "packages/flutter_aws_chime/ios/flutter_aws_chime/Sources"
    / "flutter_aws_chime/MethodChannelCoordinator.swift"
)


class ChimeAudioStartupTest(unittest.TestCase):
    def test_registering_chime_does_not_read_global_audio_session(self):
        source = CHIME_COORDINATOR.read_text(encoding="utf-8")
        before_volume_action, volume_action = source.split(
            "func toggleVolume(off:Bool)", maxsplit=1
        )
        plugin_registration = before_volume_action.split(
            "func setUpMethodCallHandler()", maxsplit=1
        )[0]
        self.assertNotIn("AVAudioSession.sharedInstance()", plugin_registration)
        self.assertIn("private var currentVolumeValue: Float?", before_volume_action)
        self.assertIn(
            "currentVolumeValue = AVAudioSession.sharedInstance().outputVolume",
            volume_action,
        )
        self.assertIn(
            "currentVolumeValue ?? AVAudioSession.sharedInstance().outputVolume",
            volume_action,
        )


if __name__ == "__main__":
    unittest.main()
