"""Prevent language links, hosted/source distinctions and staged docs drifting."""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BilingualReadmeTest(unittest.TestCase):
    def test_repo_and_facade_language_pairs(self):
        for directory in (ROOT, ROOT / "packages/flutter_realtime_sdk"):
            english = directory / "README.md"
            chinese = directory / "README.zh-CN.md"
            self.assertTrue(english.exists(), str(english))
            self.assertTrue(chinese.exists(), str(chinese))
            self.assertIn("(README.zh-CN.md)", english.read_text())
            self.assertIn("(README.md)", chinese.read_text())
            self.assertIn("0.1.0-dev.15", english.read_text())
            self.assertIn("0.1.0-dev.15", chinese.read_text())

    def test_repository_local_links_are_valid(self):
        for file in (
            ROOT / "README.md",
            ROOT / "README.zh-CN.md",
            ROOT / "packages/flutter_realtime_sdk/README.md",
            ROOT / "packages/flutter_realtime_sdk/README.zh-CN.md",
        ):
            text = file.read_text()
            # Drop fenced examples before looking for Markdown links.
            text = re.sub(r"(?ms)^(`{3}|~{3}).*?^\1\s*$", "", text)
            for path in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
                if path.startswith(("https://", "http://", "mailto:", "#")):
                    continue
                local = file.parent / path.split("#")[0]
                self.assertTrue(local.exists(), f"{file}: unresolved {path}")

    def test_pub_templates_and_staged_docs_are_bilingual(self):
        english = ROOT / "scripts/templates/single_sdk_README.md"
        chinese = ROOT / "scripts/templates/single_sdk_README.zh-CN.md"
        self.assertIn("(README.zh-CN.md)", english.read_text())
        self.assertIn("(README.md)", chinese.read_text())
        self.assertIn("@VERSION@", english.read_text())
        self.assertIn("@VERSION@", chinese.read_text())
        staged = ROOT / "build/pub_release/0.1.0-dev.9/flutter_realtime_sdk"
        if staged.exists():
            self.assertTrue((staged / "README.zh-CN.md").exists())
            for lang in ("README.md", "README.zh-CN.md"):
                content = (staged / lang).read_text()
                self.assertIn("0.1.0-dev.9", content)
                self.assertNotIn("@VERSION@", content)


if __name__ == "__main__":
    unittest.main()
