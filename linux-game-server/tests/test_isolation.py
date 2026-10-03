#!/usr/bin/env python3
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHARED = (ROOT.parent / "linux-server", ROOT.parent / "server-base")


class IsolationTests(unittest.TestCase):
    def test_symlinks_resolve_into_shared_trees(self):
        bad = []
        for path in ROOT.rglob("*"):
            if path.is_symlink():
                target = path.resolve()
                if not target.is_file() or not any(target.is_relative_to(d) for d in SHARED):
                    bad.append(str(path.relative_to(ROOT)))
        self.assertEqual(bad, [])

    def test_game_specific_files_do_not_reference_linux_server(self):
        offenders = []
        for path in ROOT.rglob("*"):
            if path.is_symlink() or not path.is_file() or path.suffix == ".md":
                continue
            if "tests" in path.parts or "__pycache__" in path.parts:
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
