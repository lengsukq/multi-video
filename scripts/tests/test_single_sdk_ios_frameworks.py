"""Exercise offline IVS resolution, integrity failures and repeat installs."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
RUBY = shutil.which("ruby")


@unittest.skipUnless(RUBY and pathlib.Path("/usr/bin/unzip").exists(), "Ruby/unzip required")
class IosFrameworkInstallTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        shutil.copy2(ROOT / "scripts/templates/single_sdk_ios_vendor_frameworks.rb",
                     self.root / "vendor_frameworks.rb")
        archive = self.root / "sdk.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("Fixture.xcframework/Info.plist", "fixture metadata")
            # Official Chat ZIP includes AppleDouble metadata with the same
            # directory name; it must not be mistaken for a second framework.
            bundle.writestr("__MACOSX/Fixture.xcframework/._Info.plist", "metadata")
        self.checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.archive = self.cache / f"{self.checksum}.zip"
        archive.rename(self.archive)
        (self.root / "vendor_frameworks.json").write_text(json.dumps({"frameworks": [{
            "name": "Fixture", "sha256": self.checksum,
            "url": "https://example.invalid/fixture.zip",
        }]}))

    def install(self):
        return subprocess.run([
            RUBY, "-e",
            "ENV['FLUTTER_REALTIME_SDK_IOS_OFFLINE'] = '1'; "
            "ENV['FLUTTER_REALTIME_SDK_IOS_ARCHIVE_CACHE'] = ARGV[0]; "
            "require File.join(Dir.pwd, 'vendor_frameworks'); "
            "FlutterRealtimeSdk::VendorFrameworks.install!(Dir.pwd)", str(self.cache),
        ], cwd=self.root, capture_output=True, text=True)

    def test_verified_cached_archive_installs_and_survives_cache_removal(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "Frameworks/Fixture.xcframework/Info.plist").exists())
        self.archive.unlink()
        repeated = self.install()
        self.assertEqual(repeated.returncode, 0, repeated.stderr)

    def test_corrupt_archive_fails_before_any_framework_is_installed(self):
        self.archive.write_bytes(b"corrupt archive")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertFalse((self.root / "Frameworks/Fixture.xcframework").exists())
        self.assertFalse((self.root / "Frameworks/.Fixture.sha256").exists())

    def test_missing_offline_archive_reports_dependency_without_network(self):
        self.archive.unlink()
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned archive missing", result.stderr)
        self.assertNotIn("Fetching", result.stderr)


@unittest.skipUnless(RUBY, "Ruby required")
class AgoraFrameworkEmbedTest(unittest.TestCase):
    def test_preinstall_deduplicates_only_the_older_infrastructure_podspec(self):
        # No framework directory or official vendor archive is deleted.
        script = """
require 'ostruct'
module Pod
  module UI
    def self.puts(*args); end
  end
end
Spec = Struct.new(:version, :attributes_hash)
Target = Struct.new(:pod_name, :specs)
older = Spec.new(ARGV[0], {
  'vendored_frameworks' => 'aosl.xcframework', 'weak_frameworks' => 'aosl'
})
newer = Spec.new(ARGV[1], {
  'vendored_frameworks' => 'aosl.xcframework', 'weak_frameworks' => 'aosl'
})
agora = Target.new('AgoraInfra_iOS', [older])
shengwang = Target.new('ShengwangInfra_iOS', [newer])
installer = OpenStruct.new(pod_targets: [agora, shengwang])
2.times { FlutterRealtimeSdk::PodfileIntegration.prepare_agora_infrastructure!(installer) }
puts "#{older.attributes_hash.key?('vendored_frameworks')} #{newer.attributes_hash.key?('vendored_frameworks')}"
"""
        for agora_version, shengwang_version, expected in (
            ("1.3.5", "1.3.16", "false true"),
            ("1.4.0", "1.3.16", "true false"),
        ):
            with self.subTest(versions=(agora_version, shengwang_version)):
                result = subprocess.run(
                    [RUBY, "-r", str(ROOT / "scripts/templates/single_sdk_ios_podfile.rb"),
                     "-e", script, agora_version, shengwang_version],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_only_duplicate_chat_embed_is_removed_when_rtc_uses_swiftpm(self):
        self.check_embed(rtc=True)

    def test_chat_keeps_its_only_runtime_without_rtc_swiftpm(self):
        self.check_embed(rtc=False)

    def check_embed(self, rtc):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = root / "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('name: "agora-rtc-engine"' if rtc else 'name: "other-plugin"')
            support = root / "Pods/Target Support Files/Pods-Runner"
            support.mkdir(parents=True)
            script = support / "Pods-Runner-frameworks.sh"
            original = ('install_framework "${PODS_XCFRAMEWORKS_BUILD_DIR}/ShengwangInfra_iOS/aosl.framework"\n'
                        'install_framework "${PODS_ROOT}/HyphenateChat/HyphenateChat.framework"\n')
            script.write_text(original)
            inputs = support / "Pods-Runner-frameworks-Release-input-files.xcfilelist"
            inputs.write_text('${PODS_XCFRAMEWORKS_BUILD_DIR}/ShengwangInfra_iOS/aosl.framework/aosl\nkeep\n')
            outputs = support / "Pods-Runner-frameworks-Release-output-files.xcfilelist"
            outputs.write_text('${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/aosl.framework\nkeep\n')
            result = subprocess.run([
                RUBY, "-r", str(ROOT / "scripts/templates/single_sdk_ios_podfile.rb"), "-e",
                "require 'ostruct'; "
                "installer = OpenStruct.new(config: OpenStruct.new(installation_root: ARGV[0]), "
                "sandbox: OpenStruct.new(root: File.join(ARGV[0], 'Pods'))); "
                "2.times { FlutterRealtimeSdk::PodfileIntegration.deduplicate_agora_frameworks!(installer) }",
                str(root),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            if rtc:
                self.assertNotIn("aosl", script.read_text())
                self.assertIn("HyphenateChat.framework", script.read_text())
                self.assertEqual(inputs.read_text(), "keep\n")
                self.assertEqual(outputs.read_text(), "keep\n")
            else:
                self.assertEqual(script.read_text(), original)
                self.assertIn("aosl", inputs.read_text())
                self.assertIn("aosl", outputs.read_text())


if __name__ == "__main__":
    unittest.main()
