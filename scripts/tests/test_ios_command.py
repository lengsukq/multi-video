import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

scripts = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location('ios_command', scripts / 'flutter_ios.py')
helper = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(scripts))
try:
    spec.loader.exec_module(helper)
finally:
    sys.path.pop(0)


class IosCommandTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        self.manifest = self.project / 'pubspec.yaml'
        self.original = 'name: demo\nflutter:\n  config:\n    enable-swift-package-manager: true\n'
        self.manifest.write_text(self.original)
        self.commands = []

    def run_command(self, command, cwd):
        self.assertEqual(cwd, self.project)
        self.assertIn('enable-swift-package-manager: true', self.manifest.read_text())
        self.commands.append(command)
        return subprocess.CompletedProcess(command, 0)

    def test_ios_build_resolves_plugins_without_changing_manifest(self):
        args = ['build', 'ios', '--release', '--no-pub']
        self.assertEqual(helper.run_ios(self.project, args, self.run_command), 0)
        self.assertEqual(self.commands, [['flutter', 'pub', 'get', '--offline'], ['flutter', *args]])
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_ios_debug_device_arguments_are_forwarded(self):
        args = ['run', '-d', 'ios-device-id', '--debug']
        self.assertEqual(helper.run_ios(self.project, args, self.run_command), 0)
        self.assertEqual(self.commands[-1], ['flutter', *args])
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_failed_resolution_prevents_build_and_restores_configuration(self):
        def fail(command, cwd):
            self.run_command(command, cwd)
            return subprocess.CompletedProcess(command, 1)
        self.assertEqual(helper.run_ios(self.project, ['build', 'ios'], fail), 1)
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_ios_resolution_preserves_macos_swiftpm_runner(self):
        runner = self.project / 'macos/Runner.xcodeproj/project.pbxproj'
        runner.parent.mkdir(parents=True)
        original = 'user-owned object\nSwiftPM macOS Runner dependency\n'
        runner.write_text(original)
        def resolve(command, cwd):
            self.run_command(command, cwd)
            return subprocess.CompletedProcess(command, 0)
        helper.run_ios(self.project, ['build', 'ios'], resolve)
        self.assertEqual(runner.read_text(), original)

    def test_interrupted_debug_run_restores_configuration(self):
        def interrupted(command, cwd):
            self.run_command(command, cwd)
            if command[1] == 'run':
                raise KeyboardInterrupt
            return subprocess.CompletedProcess(command, 0)
        with self.assertRaises(KeyboardInterrupt):
            helper.run_ios(self.project, ['run', '-d', 'ios-device-id'], interrupted)
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_newer_user_manifest_edits_are_preserved(self):
        def edit(command, cwd):
            if command[1] == 'build':
                self.manifest.write_text('newer user edit')
            return subprocess.CompletedProcess(command, 0)
        self.assertEqual(helper.run_ios(self.project, ['build', 'ios'], edit), 0)
        self.assertEqual(self.manifest.read_text(), 'newer user edit')

    def test_wrong_platform_command_is_rejected_before_mutation(self):
        with self.assertRaises(ValueError):
            helper.run_ios(self.project, ['build', 'macos'], self.run_command)
        self.assertEqual(self.commands, [])
        self.assertEqual(self.manifest.read_text(), self.original)

    def test_demo_defaults_to_swiftpm_for_ios(self):
        manifest = (scripts.parent / 'example/pubspec.yaml').read_text()
        self.assertIn('enable-swift-package-manager: true', manifest)

    def test_ios_rejects_disabled_swiftpm_before_running_flutter(self):
        self.manifest.write_text(self.original.replace(': true', ': false'))
        with self.assertRaisesRegex(ValueError, 'iOS requires'):
            helper.run_ios(self.project, ['build', 'ios'], self.run_command)
        self.assertEqual(self.commands, [])

    def test_macos_compatibility_entrypoint_preserves_shared_swiftpm_config(self):
        from build_flutter_macos import debug
        commands = []

        def run(command, cwd):
            self.assertEqual(cwd, self.project)
            self.assertIn('enable-swift-package-manager: true', self.manifest.read_text())
            commands.append(command)
            return subprocess.CompletedProcess(command, 0)

        self.assertEqual(debug(self.project, [], run), 0)
        self.assertEqual(commands, [['flutter', 'run', '-d', 'macos']])
        self.assertEqual(self.manifest.read_text(), self.original)
