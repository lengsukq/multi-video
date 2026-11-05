"""Protect the iOS multi-vendor host against IVS grabbing audio at registration."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / (
    "packages/flutter_realtime_media_ivs/ios/flutter_realtime_media_ivs/"
    "Sources/flutter_realtime_media_ivs/FlutterRealtimeMediaIvsPlugin.swift"
)


class IvsAudioSessionLifecycleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()

    def test_registration_does_not_create_ivs_device_discovery(self):
        registration = self.source.split("public static func register", 1)[1].split(
            "public func onListen", 1
        )[0]
        self.assertNotIn("IVSDeviceDiscovery()", registration)
        self.assertIn("private var discovery: IVSDeviceDiscovery?", self.source)
        self.assertNotIn("private var discovery = IVSDeviceDiscovery()", self.source)

    def test_prejoin_probe_does_not_activate_ivs_audio_session(self):
        probe = self.source.split("private func probeDevices", 1)[1].split(
            "private func join", 1
        )[0]
        self.assertIn("AVCaptureDevice.devices(for: .audio)", probe)
        self.assertNotIn("IVSDeviceDiscovery()", probe)
        self.assertNotIn("deviceDiscovery()", probe)

    def test_active_publisher_initializes_and_tears_down_discovery(self):
        self.assertIn("private func deviceDiscovery() -> IVSDeviceDiscovery", self.source)
        self.assertIn("let devices = deviceDiscovery().listLocalDevices()", self.source)
        leave = self.source.split("private func leave()", 1)[1].split(
            "private func attachIosScreenCaptureKitSource", 1
        )[0]
        self.assertIn("discovery = nil", leave)


if __name__ == "__main__":
    unittest.main()
