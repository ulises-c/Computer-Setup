import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = str(Path(__file__).with_name("inputs.py"))


class InputsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "botting"
        (self.root / "observations").mkdir(parents=True)
        (self.root / "learnings").mkdir()
        self.target = self.base / "target"

    def module(self):
        self.assertTrue(Path(SCRIPT).exists(), "upload helper is missing")
        spec = importlib.util.spec_from_file_location("wiki_inputs", SCRIPT)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def snapshot(self, module):
        stream = io.BytesIO()
        module.pack(self.root, stream)
        stream.seek(0)
        return stream

    def test_allowlist_roundtrip_preserves_mtime_and_empty_directories(self):
        module = self.module()
        import os
        observed = self.root / "observations/items.tsv"
        observed.write_text("item\tname\n")
        os.utime(observed, (1234567890, 1234567890))
        (self.root / "observations/accounts.tsv").write_text("SENTINEL")
        (self.root / ".env").write_text("SENTINEL")
        (self.root / "accounts.db").write_text("SENTINEL")
        stream = self.snapshot(module)
        self.assertNotIn(b"SENTINEL", stream.getvalue())
        module.receive(stream, self.target)
        current = self.target / "current"
        self.assertTrue(current.is_symlink())
        self.assertEqual((current / "observations/items.tsv").read_text(), "item\tname\n")
        self.assertEqual((current / "observations/items.tsv").stat().st_mtime, 1234567890)
        self.assertTrue((current / "learnings").is_dir())
        self.assertEqual(sorted(p.name for p in (current / "observations").iterdir()), ["items.tsv"])

    def malicious(self, name, kind=tarfile.REGTYPE, size=1):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for directory in ("observations", "learnings"):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            info = tarfile.TarInfo(name)
            info.type = kind
            info.linkname = "../escape"
            info.size = size if kind == tarfile.REGTYPE else 0
            archive.addfile(info, io.BytesIO(b"x" * info.size))
        stream.seek(0)
        return stream

    def test_receiver_rejects_unsafe_members_without_changing_current(self):
        module = self.module()
        module.receive(self.snapshot(module), self.target)
        prior = (self.target / "current").readlink()
        cases = [("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE),
                 ("observations/../escape", tarfile.REGTYPE),
                 ("observations/accounts.tsv", tarfile.REGTYPE),
                 ("learnings/a.md", tarfile.SYMTYPE),
                 ("learnings/a.md", tarfile.LNKTYPE),
                 ("learnings/a.md", tarfile.FIFOTYPE),
                 ("learnings/a.md", tarfile.CHRTYPE),
                 ("learnings/a.txt", tarfile.REGTYPE)]
        for name, kind in cases:
            with self.subTest(name=name, kind=kind):
                with self.assertRaises((ValueError, OSError, tarfile.TarError)):
                    module.receive(self.malicious(name, kind), self.target)
                self.assertEqual((self.target / "current").readlink(), prior)

    def test_idempotent_content_keeps_generation_and_old_generations(self):
        import os
        module = self.module()
        note = self.root / "learnings/nested/a.md"
        note.parent.mkdir()
        note.write_text("first")
        module.receive(self.snapshot(module), self.target)
        prior = (self.target / "current").resolve()
        os.utime(note, (1234567890, 1234567890))
        module.receive(self.snapshot(module), self.target)
        self.assertEqual((self.target / "current").resolve(), prior)
        self.assertEqual(len(list(self.target.glob("generation-*"))), 1)
        note.write_text("second")
        module.receive(self.snapshot(module), self.target)
        self.assertNotEqual((self.target / "current").resolve(), prior)
        self.assertEqual((prior / "learnings/nested/a.md").read_text(), "first")

    def test_source_rejects_symlinks_fifos_and_symlink_ancestors(self):
        import os
        module = self.module()
        sentinel = self.base / "sentinel.md"
        sentinel.write_text("SENTINEL")
        link = self.root / "learnings/a.md"
        link.symlink_to(sentinel)
        with self.assertRaises((ValueError, OSError)):
            self.snapshot(module)
        link.unlink()
        os.mkfifo(link)
        with self.assertRaises((ValueError, OSError)):
            self.snapshot(module)
        link.unlink()
        (self.root / "learnings/nested").symlink_to(self.base, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.snapshot(module)
        (self.root / "learnings/nested").unlink()
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            module.pack(alias, io.BytesIO())
        alias.unlink()
        alias.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            module.pack(alias / "botting", io.BytesIO())
        (self.root / "observations/items.tsv").symlink_to(sentinel)
        with self.assertRaises((ValueError, OSError)):
            self.snapshot(module)

    def test_receiver_bounds_and_consistency_leave_no_partial_generation(self):
        module = self.module()
        module.receive(self.snapshot(module), self.target)
        prior = (self.target / "current").readlink()
        valid = self.snapshot(module).getvalue()
        cases = [self.malicious("learnings/large.md", size=8 * 1024 * 1024 + 1),
                 io.BytesIO(valid[:512]), io.BytesIO(b""),
                 self.malicious("observations", tarfile.DIRTYPE)]
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            info = tarfile.TarInfo("learnings")
            info.type = tarfile.DIRTYPE
            archive.addfile(info)
        stream.seek(0)
        cases.append(stream)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for directory in ("observations", "learnings"):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            for index in range(10001):
                info = tarfile.TarInfo("learnings/d%d" % index)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
        stream.seek(0)
        cases.append(stream)
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for directory in ("observations", "learnings"):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            for index in range(9):
                info = tarfile.TarInfo("learnings/%d.md" % index)
                info.size = 8 * 1024 * 1024
                archive.addfile(info, io.BytesIO(b"x" * info.size))
        stream.seek(0)
        cases.append(stream)
        for index, stream in enumerate(cases):
            with self.subTest(index=index):
                with self.assertRaises((ValueError, OSError, tarfile.TarError)):
                    module.receive(stream, self.target)
                self.assertEqual((self.target / "current").readlink(), prior)
                self.assertEqual(len(list(self.target.glob("generation-*"))), 1)
                self.assertFalse(list(self.target.glob(".stage-*")))

    def test_cli_push_transports_via_ssh_and_receive_accepts_stdin(self):
        import json
        import os
        import subprocess
        import sys
        module = self.module()
        (self.root / "learnings/a.md").write_text("curated")
        bindir = self.base / "bin"
        bindir.mkdir()
        fake = bindir / "ssh"
        fake.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                        "with open(os.environ['TEST_LOG'], 'w') as log: json.dump(sys.argv[1:], log)\n"
                        "os.execv(sys.executable, [sys.executable, os.environ['TEST_RECEIVER'], "
                        "'receive', '--target', os.environ['TEST_TARGET']])\n")
        fake.chmod(0o700)
        log = self.base / "ssh.json"
        env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ['PATH'],
                   TEST_LOG=str(log), TEST_RECEIVER=SCRIPT, TEST_TARGET=str(self.target))
        receiver = "custom receiver;not-a-command.py"
        command = [sys.executable, SCRIPT, "push", "--host", "wiki-test",
                   "--botting-root", str(self.root), "--receiver", receiver]
        result = subprocess.run(command, env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "current/learnings/a.md").read_text(), "curated")
        args = json.loads(log.read_text())
        self.assertIn("BatchMode=yes", args)
        self.assertIn("ConnectTimeout=8", args)
        self.assertEqual(args[-3:-1], ["--", "wiki-test"])
        self.assertIn("'custom receiver;not-a-command.py'", args[-1])
        self.assertTrue(args[-1].endswith(" receive"))
        prior = (self.target / "current").readlink()
        result = subprocess.run([sys.executable, SCRIPT, "receive", "--target", str(self.target)],
                                input=b"broken upload", capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.target / "current").readlink(), prior)
        log.unlink()
        (self.root / "observations").rmdir()
        result = subprocess.run(command, env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(log.exists(), "must validate source before starting SSH")

    def test_receiver_rejects_symlink_target_ancestors_and_lock(self):
        module = self.module()
        real = self.base / "real"
        real.mkdir()
        self.target.symlink_to(real, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            module.receive(self.snapshot(module), self.target / "nested")
        self.assertFalse(list(real.iterdir()))
        self.target.unlink()
        self.target.mkdir()
        (self.target / ".lock").symlink_to(real / "sentinel")
        with self.assertRaises((ValueError, OSError)):
            module.receive(self.snapshot(module), self.target)
        self.assertFalse((real / "sentinel").exists())

    def test_source_snapshot_preserves_fractional_mtime_and_bounds_files(self):
        import os
        module = self.module()
        note = self.root / "learnings/a.md"
        note.write_text("snapshot")
        os.utime(note, ns=(1234567890123456789, 1234567890123456789))
        module.receive(self.snapshot(module), self.target)
        self.assertEqual((self.target / "current/learnings/a.md").stat().st_mtime, note.stat().st_mtime)
        with note.open("wb") as stream:
            stream.truncate(8 * 1024 * 1024 + 1)
        with self.assertRaises(ValueError):
            self.snapshot(module)

    def test_source_bounds_total_and_count_before_transport(self):
        module = self.module()
        note = self.root / "learnings/a.md"
        note.write_text("four")
        module.MAX_TOTAL = 3
        with self.assertRaises(ValueError):
            self.snapshot(module)
        module.MAX_TOTAL = 64 * 1024 * 1024
        module.MAX_COUNT = 2
        with self.assertRaises(ValueError):
            self.snapshot(module)

    def test_receiver_rejects_preexisting_generation_symlink(self):
        module = self.module()
        module.receive(self.snapshot(module), self.target)
        generation = (self.target / "current").resolve()
        saved = self.base / "saved"
        generation.rename(saved)
        generation.symlink_to(saved, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            module.receive(self.snapshot(module), self.target)

    def test_failed_publication_can_retry_without_changing_prior_current(self):
        from unittest.mock import patch
        module = self.module()
        module.receive(self.snapshot(module), self.target)
        prior = (self.target / "current").readlink()
        (self.root / "learnings/a.md").write_text("new")
        with patch.object(module.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                module.receive(self.snapshot(module), self.target)
        self.assertEqual((self.target / "current").readlink(), prior)
        module.receive(self.snapshot(module), self.target)
        self.assertEqual((self.target / "current/learnings/a.md").read_text(), "new")

    def test_truncated_archive_ending_in_zero_file_data_is_not_published(self):
        module = self.module()
        module.receive(self.snapshot(module), self.target)
        prior = (self.target / "current").readlink()
        (self.root / "learnings/zeros.md").write_bytes(b"\0" * 2048)
        raw = self.snapshot(module).getvalue()
        stream = io.BytesIO(raw)
        with tarfile.open(fileobj=stream) as archive:
            member = archive.getmember("learnings/zeros.md")
            end = member.offset_data + member.size
        with self.assertRaises((ValueError, tarfile.TarError)):
            module.receive(io.BytesIO(raw[:end]), self.target)
        self.assertEqual((self.target / "current").readlink(), prior)

    def test_complete_allowlist_empty_nested_dirs_and_missing_roots(self):
        module = self.module()
        for name in module.OBSERVATIONS:
            (self.root / name).write_text(name)
        (self.root / "learnings/nested/empty").mkdir(parents=True)
        (self.root / "learnings/nested/a.md").write_text("note")
        (self.root / "learnings/nested/a.db").write_text("SENTINEL")
        stream = self.snapshot(module)
        self.assertNotIn(b"SENTINEL", stream.getvalue())
        module.receive(stream, self.target)
        for name in module.OBSERVATIONS:
            self.assertEqual((self.target / "current" / name).read_text(), name)
        self.assertTrue((self.target / "current/learnings/nested/empty").is_dir())
        self.assertEqual((self.target / "current").stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.target / "current/learnings/nested/a.md").stat().st_mode & 0o777, 0o600)
        (self.root / "learnings").rename(self.root / "saved")
        with self.assertRaises((ValueError, OSError)):
            self.snapshot(module)

    def test_concurrent_receivers_share_one_generation(self):
        from concurrent.futures import ThreadPoolExecutor
        import threading
        module = self.module()
        (self.root / "learnings/a.md").write_text("content")
        raw = self.snapshot(module).getvalue()
        barrier = threading.Barrier(4)

        def upload(_):
            barrier.wait(timeout=10)
            module.receive(io.BytesIO(raw), self.target)

        with ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(upload, range(4)))
        self.assertEqual(len(list(self.target.glob("generation-*"))), 1)
        self.assertEqual((self.target / "current/learnings/a.md").read_text(), "content")
        self.assertFalse(list(self.target.glob(".stage-*")))

    def test_receiver_accepts_manifest_and_rejects_wire_overflow(self):
        module = self.module()
        module.receive(self.malicious("manifest.json"), self.target)
        self.assertEqual((self.target / "current/manifest.json").read_text(), "x")
        prior = (self.target / "current").readlink()
        module.MAX_ARCHIVE = 1024
        with self.assertRaises(ValueError):
            module.receive(self.snapshot(module), self.target)
        self.assertEqual((self.target / "current").readlink(), prior)

    def test_source_file_rename_after_open_keeps_one_file_snapshot(self):
        from unittest.mock import patch
        module = self.module()
        note = self.root / "learnings/a.md"
        note.write_text("original")
        original_open = module.os.open

        def racing_open(name, *args, **kwargs):
            fd = original_open(name, *args, **kwargs)
            if name == "a.md":
                note.rename(note.with_name("old.txt"))
                note.write_text("replacement")
            return fd

        with patch.object(module.os, "open", side_effect=racing_open):
            snapshot = self.snapshot(module)
        module.receive(snapshot, self.target)
        self.assertEqual((self.target / "current/learnings/a.md").read_text(), "original")
        self.assertEqual(note.read_text(), "replacement")

    def test_receiver_accepts_exact_file_and_total_size_boundaries(self):
        module = self.module()
        for index in range(8):
            with (self.root / "learnings" / (str(index) + ".md")).open("wb") as source:
                source.truncate(8 * 1024 * 1024)
        module.receive(self.snapshot(module), self.target)
        self.assertEqual(sum(path.stat().st_size for path in
                             (self.target / "current/learnings").glob("*.md")), 64 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
