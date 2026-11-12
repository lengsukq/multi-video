"""Provider declaration evidence must survive splitting a session library."""

import tempfile
import unittest
from pathlib import Path

from scripts import generate_capability_matrix as declarations


class CapabilityDeclarationsTest(unittest.TestCase):
    def test_nested_platform_sets_and_windows_chat_do_not_drop_mobile(self):
        source = declarations.generate()
        self.assertIn(
            '| agora | agora | native | android, ios, macos, windows |',
            source,
        )
        self.assertIn(
            '| ivs-chat | ivs-chat | native | android, ios, macos, windows |',
            source,
        )
        self.assertIn(
            '| agora-chat | agora-chat | native | android, ios, macos, windows |',
            source,
        )

    def test_split_role_and_capability_parts_remain_in_declaration_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            session = folder / 'session.dart'
            session.write_text("part 'capabilities.dart';\npart 'publisher.dart';\nclass Session {}\n")
            (folder / 'capabilities.dart').write_text(
                "part of 'session.dart';\nconst capabilities = MediaCapabilities(canBlurBackground: true);\n")
            publisher = folder / 'publisher.dart'
            publisher.write_text("part of 'session.dart';\nclass Publisher implements ProcessedVideoSink {}\n")
            # Unrelated Dart files must not inflate a provider's declarations.
            (folder / 'unrelated.dart').write_text('canScreenShare: true')
            sources = declarations.adapter_sources(session)
            source = '\n'.join(text for _, text in sources)
            self.assertIn('canBlurBackground: true', source)
            self.assertIn('implements ProcessedVideoSink', source)
            self.assertNotIn('canScreenShare', source)
            self.assertIn(publisher.resolve(), [path for path, _ in sources])

    def test_a_changed_private_part_changes_the_generated_fingerprint(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            session = folder / 'session.dart'
            session.write_text("part 'capabilities.dart';\n")
            part = folder / 'capabilities.dart'
            part.write_text('canBlurBackground: false')
            before = declarations.adapter_sources(session)
            part.write_text('canBlurBackground: true')
            after = declarations.adapter_sources(session)
            self.assertEqual(before[0], after[0])
            fingerprint = lambda text: declarations.hashlib.sha256(text.encode()).hexdigest()
            self.assertNotEqual(fingerprint(before[1][1]), fingerprint(after[1][1]))


if __name__ == '__main__':
    unittest.main()
