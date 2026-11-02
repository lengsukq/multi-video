import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "macos_build", Path(__file__).parents[1] / "build_flutter_macos.py"
)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class MacosBuildTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.manifest = self.project / "pubspec.yaml"
        self.manifest.write_text(
            "name: demo\nflutter:\n  config:\n"
            "    enable-swift-package-manager: true\n"
        )
        self.runner = self.project / "macos/Runner.xcodeproj/project.pbxproj"
        self.runner.parent.mkdir(parents=True)
        self.runner.write_text("The macOS Runner's SwiftPM dependencies\n")
        self.swift = (
            self.project
            / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage/Package.swift"
        )
        self.swift.parent.mkdir(parents=True)
        self.swift.write_text("Generated Swift package manifest\n")

    def assert_no_mutations(self):
        self.assertIn("enable-swift-package-manager: true", self.manifest.read_text())
        self.assertEqual(
            self.runner.read_text(), "The macOS Runner's SwiftPM dependencies\n"
        )
        self.assertEqual(
            self.swift.read_text(), "Generated Swift package manifest\n"
        )

    def test_release_build_is_standard_flutter(self):
        calls = []
        def run(command, cwd):
            calls.append((command, cwd))
            self.assert_no_mutations()
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(helper.build(self.project, ["--release", "--no-pub"], run), 0)
        self.assertEqual(
            calls,
            [(["flutter", "build", "macos", "--release", "--no-pub"], self.project)],
        )
        self.assert_no_mutations()

    def test_interactive_debug_is_standard_flutter(self):
        def run(command, cwd):
            self.assertEqual(command, ["flutter", "run", "-d", "macos", "--debug"])
            self.assertEqual(cwd, self.project)
            self.assert_no_mutations()
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(helper.debug(self.project, ["--debug"], run), 0)
        self.assert_no_mutations()

    def test_build_failure_does_not_change_project(self):
        self.assertEqual(
            helper.build(
                self.project, [],
                lambda command, cwd: subprocess.CompletedProcess(command, 8),
            ),
            8,
        )
        self.assert_no_mutations()

    def test_interruption_does_not_change_project(self):
        def interrupt(command, cwd):
            raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            helper.debug(self.project, [], interrupt)
        self.assert_no_mutations()

    def test_disabled_swiftpm_fails_without_running_command(self):
        self.manifest.write_text(
            "flutter:\n  config:\n    enable-swift-package-manager: false\n"
        )
        with self.assertRaisesRegex(ValueError, "Expected SwiftPM"):
            helper.build(
                self.project, [],
                lambda command, cwd: self.fail("must not run"),
            )
        self.assertIn("false", self.manifest.read_text())
        self.assertEqual(
            self.runner.read_text(), "The macOS Runner's SwiftPM dependencies\n"
        )

    def test_newer_concurrent_edits_are_never_reverted(self):
        def modify(command, cwd):
            self.manifest.write_text("newer user edit")
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(helper.debug(self.project, [], modify), 0)
        self.assertEqual(self.manifest.read_text(), "newer user edit")
        self.assertEqual(
            self.runner.read_text(), "The macOS Runner's SwiftPM dependencies\n"
        )
