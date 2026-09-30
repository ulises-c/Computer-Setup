#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IsolationTests(unittest.TestCase):
    def test_no_symlinks(self):
        links = [str(p.relative_to(ROOT)) for p in ROOT.rglob("*") if p.is_symlink()]
        self.assertEqual(links, [])

    def test_deployed_files_do_not_reference_linux_server(self):
        offenders = []
        for path in ROOT.rglob("*"):
            if not path.is_file() or path.suffix == ".md" or "tests" in path.parts or "__pycache__" in path.parts:
                continue
            try:
                text = path.read_text()
            except UnicodeDecodeError:
                continue
            if "linux-server" in text:
                offenders.append(str(path.relative_to(ROOT)))
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
