#!/usr/bin/env python3
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "dragonwilds/backup-save.py"
spec = importlib.util.spec_from_file_location("backup_save", MODULE_PATH)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class BackupSaveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.install = self.root / "game"
        self.output = self.root / "Downloads"
        saved = self.install / "RSDragonwilds/Saved"
        self.config = saved / "Config/LinuxServer/DedicatedServer.ini"
        self.config.parent.mkdir(parents=True)
        self.config.write_text("[/Script/Dominion.DedicatedServerSettings]\nDefaultWorldName=fixture\n")
        self.save = saved / "SaveGames/fixture.sav"
        self.save.parent.mkdir()
        self.data = b"".join(struct.pack("<i", len(value) + 1) + value + b"\0"
                             for value in (b"fixture", b"L_World"))
        self.save.write_bytes(self.data)
        self.delay = patch.object(backup.time, "sleep")
        self.delay.start()
        self.addCleanup(self.delay.stop)

    def test_hash_verified_private_backup_does_not_change_source(self):
        result = backup.backup_save(self.install, self.output)
        copied = Path(result["backup"])
        checksum = Path(result["checksum"])
        self.assertEqual(copied.read_bytes(), self.data)
        self.assertEqual(self.save.read_bytes(), self.data)
        self.assertEqual(result["sha256"], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(checksum.read_text(), f"{result['sha256']}  {copied.name}\n")
        self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
        self.assertEqual(checksum.stat().st_mode & 0o777, 0o600)
        self.assertIn("not a stopped-server snapshot", result["consistency"])

    def test_repeated_backups_do_not_overwrite(self):
        first = backup.backup_save(self.install, self.output)
        second = backup.backup_save(self.install, self.output)
        self.assertNotEqual(first["backup"], second["backup"])
        self.assertTrue(Path(first["backup"]).exists())

    def test_rejects_mismatched_save_header_before_writing(self):
        self.save.write_bytes(self.data.replace(b"fixture", b"changed"))
        with self.assertRaisesRegex(ValueError, "does not match"):
            backup.backup_save(self.install, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_traversal_world_name(self):
        self.config.write_text("[/Script/Dominion.DedicatedServerSettings]\nDefaultWorldName=../fixture\n")
        with self.assertRaisesRegex(ValueError, "Invalid world name"):
            backup.backup_save(self.install, self.output)
        self.assertFalse(self.output.exists())

    def test_refuses_continuously_changing_save(self):
        reads = iter([self.data, self.data + b"changed"] * 5)
        with patch.object(Path, "read_bytes", side_effect=lambda: next(reads)):
            with self.assertRaisesRegex(ValueError, "kept changing"):
                backup.backup_save(self.install, self.output)
        self.assertFalse(self.output.exists())

    def test_corrupt_written_backup_is_removed(self):
        original = Path.read_bytes
        def read_bytes(path):
            return b"corrupt" if path.parent == self.output else original(path)
        with patch.object(Path, "read_bytes", read_bytes):
            with self.assertRaisesRegex(ValueError, "Written backup hash"):
                backup.backup_save(self.install, self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_malformed_config_error_does_not_print_config_values(self):
        self.config.write_text("WorldPassword=private-fixture-value\n")
        error = io.StringIO()
        with patch("sys.argv", ["backup-save.py", "--install-dir", str(self.install)]), patch("sys.stderr", error):
            with self.assertRaises(SystemExit) as result:
                backup.main()
        self.assertEqual(result.exception.code, 1)
        self.assertIn("no config values were printed", error.getvalue())
        self.assertNotIn("private-fixture-value", error.getvalue())


if __name__ == "__main__":
    unittest.main()
