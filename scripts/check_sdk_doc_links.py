"""Validate the ten canonical SDK documentation pages and their local links.

Usage: python3 scripts/check_sdk_doc_links.py
Run from any directory; this checks relative destinations from docs and
repository README files, without visiting or rewriting external websites.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "doc"
EXPECTED = {
    "README.md",
    "APP_INTEGRATION_QUICKSTART.zh-CN.md",
    "ARCHITECTURE.md",
    "MEDIA_BACKEND_CONTRACT.md",
    "SDK_CAPABILITY_MATRIX.zh-CN.md",
    "CLASSROOM_SDK.md",
    "CLOUD_RECORDING.md",
    "REALTIME_DESIGN_SYSTEM.md",
    "ACCEPTANCE.md",
    "PUB_DEV_RELEASE_GUIDE.zh-CN.md",
}
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")


def scan_files() -> list[Path]:
    files = list(DOC.rglob("*.md"))
    files += [ROOT / "README.md", ROOT / "README.zh-CN.md"]
    files += [ROOT / "example/README.md", ROOT / "demo-server/README.md"]
    files += list((ROOT / "packages").glob("flutter_realtime_*/README*.md"))
    files += list((ROOT / "scripts/templates").glob("single_sdk_README*.md"))
    return [p for p in dict.fromkeys(files) if p.is_file()]


def check() -> list[str]:
    errors: list[str] = []
    actual = {p.name for p in DOC.glob("*.md")}
    if actual != EXPECTED:
        errors.append(f"doc/ contains {len(actual)} hand-maintained pages; unexpected={sorted(actual - EXPECTED)}, missing={sorted(EXPECTED - actual)}")
    if not (DOC / "generated/SDK_DECLARATIONS.md").is_file():
        errors.append("Missing source-generated capability declarations")
    for page in scan_files():
        text = page.read_text(encoding="utf-8")
        if len(re.findall(r"^\s*```", text, flags=re.MULTILINE)) % 2:
            errors.append(f"{page.relative_to(ROOT)}: unmatched Markdown code fence")
        for m in LINK.finditer(text):
            url = m.group(1).split(" ", 1)[0].strip("<>")
            if not url or url.startswith(("https:", "http:", "mailto:", "data:", "#", "app:")):
                continue
            filename = unquote(url.split("#", 1)[0].split("?", 1)[0])
            if any(token in filename for token in ("{", "}", "<", ">")):
                continue
            # Distribution templates are rendered into a new package root;
            # their language-switching README links are valid after assembly.
            if page.parent == ROOT / "scripts/templates" and filename in {
                "README.md", "README.zh-CN.md"
            }:
                continue
            dest = page.parent / filename
            if not dest.exists():
                line = text.count("\n", 0, m.start()) + 1
                errors.append(f"{page.relative_to(ROOT)}:{line}: missing {url}")
    return errors


if __name__ == "__main__":
    errors = check()
    if errors:
        print("\n".join(errors))
        sys.exit(1)
    print(f"SDK docs OK: {len(EXPECTED)} canonical pages, 1 generated declaration, local links and code fences valid")
