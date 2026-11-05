"""The single-package iOS Podspec can omit conflicting native RTC vendors."""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUBY = shutil.which("ruby")


@unittest.skipUnless(RUBY, "Ruby required to verify CocoaPods vendor isolation")
class IosVendorConflictIsolationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from sys import path
        scripts = str(ROOT / "scripts")
        if scripts not in path:
            path.insert(0, scripts)
        from assemble_single_sdk_distribution import build
        cls.candidate = pathlib.Path(build()["target"])

    def podspec(self, *, chime=False, artc=False):
        with tempfile.TemporaryDirectory() as temporary:
            folder = pathlib.Path(temporary)
            shutil.copyfile(
                self.candidate / "ios/flutter_realtime_sdk.podspec",
                folder / "flutter_realtime_sdk.podspec",
            )
            (folder / "vendor_frameworks.rb").write_text(
                "module FlutterRealtimeSdk; module VendorFrameworks; "
                "def self.install!(_path); end; end; end\n"
            )
            stub = r"""
require 'json'
module Pod
  class Spec
    # Real CocoaPods supports assigning `exclude_files`, but does not expose
    # a public getter. A permissive attr_accessor masked a broken podspec.
    attr_writer :exclude_files
    attr_accessor :pod_target_xcconfig
    attr_reader :dependencies
    def initialize
      @dependencies = []
      yield self
      $captured_spec = self
    end
    def dependency(name, *args); @dependencies << name; end
    def method_missing(name, *args)
      return instance_variable_set("@#{name.to_s.chomp('=')}", args.first) if name.to_s.end_with?('=')
      return instance_variable_get("@#{name}") if instance_variable_defined?("@#{name}")
      super
    end
  end
end
load ARGV[0]
puts JSON.generate({
  dependencies: $captured_spec.dependencies,
  excluded: $captured_spec.instance_variable_get(:@exclude_files),
  conditions: $captured_spec.pod_target_xcconfig['SWIFT_ACTIVE_COMPILATION_CONDITIONS']
})
"""
            env = dict(os.environ)
            env["FRSDK_IOS_DISABLE_CHIME"] = "1" if chime else "0"
            env["FRSDK_IOS_DISABLE_ARTC"] = "1" if artc else "0"
            result = subprocess.run(
                [RUBY, "-e", stub, str(folder / "flutter_realtime_sdk.podspec")],
                capture_output=True, text=True, env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_defaults_remain_backward_compatible(self):
        metadata = self.podspec()
        self.assertIn("AliVCSDK_ARTC", metadata["dependencies"])
        self.assertIn("AmazonChimeSDKMedia", metadata["dependencies"])
        self.assertEqual(metadata["excluded"], [])
        self.assertNotIn("FRSDK_DISABLE_", metadata["conditions"])

    def test_host_can_omit_both_conflicting_native_vendors(self):
        metadata = self.podspec(chime=True, artc=True)
        self.assertNotIn("AliVCSDK_ARTC", metadata["dependencies"])
        self.assertFalse(any(d.startswith("AmazonChimeSDK") for d in metadata["dependencies"]))
        self.assertIn("flutter_webrtc", metadata["dependencies"])
        self.assertIn("Classes/flutter_aws_chime/**/*", metadata["excluded"])
        self.assertIn("Classes/flutter_realtime_media_artc/**/*", metadata["excluded"])
        self.assertIn("FRSDK_DISABLE_CHIME", metadata["conditions"])
        self.assertIn("FRSDK_DISABLE_ARTC", metadata["conditions"])

    def test_can_omit_only_chime_or_only_artc(self):
        chime = self.podspec(chime=True)
        self.assertIn("AliVCSDK_ARTC", chime["dependencies"])
        self.assertFalse(any(d.startswith("AmazonChimeSDK") for d in chime["dependencies"]))
        artc = self.podspec(artc=True)
        self.assertNotIn("AliVCSDK_ARTC", artc["dependencies"])
        self.assertIn("AmazonChimeSDKMedia", artc["dependencies"])

    def test_registration_respects_conditional_compilation(self):
        registration = (
            self.candidate / "ios/Classes/FlutterRealtimeSdkPlugin.swift"
        ).read_text()
        self.assertIn(
            "#if !FRSDK_DISABLE_CHIME\n"
            "    FlutterAwsChimePlugin.register(with: registrar)\n"
            "    #endif", registration,
        )
        self.assertIn(
            "#if !FRSDK_DISABLE_ARTC\n"
            "    FlutterRealtimeMediaArtcPlugin.register(with: registrar)\n"
            "    #endif", registration,
        )


if __name__ == "__main__":
    unittest.main()
