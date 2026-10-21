#!/usr/bin/env python3
import fcntl
import json
import multiprocessing
import os
import stat
import time
import unittest
from pathlib import Path

import rgb_testlib as lib
import rgb_common as common


class ParseDevicesTests(unittest.TestCase):
    def test_index_name_modes_zones_and_leds(self):
        devices = common.parse_devices("noise line\n" + lib.OMEN + lib.NO_OFF)
        omen = devices[0]
        self.assertEqual((omen["index"], omen["name"], omen["type"]), (0, "HP Omen 30L", "Motherboard"))
        self.assertEqual(omen["mode"], "Direct")
        self.assertEqual(omen["available_modes"],
                         ["Direct", "Static", "Off", "Breathing", "Color Cycle", "Blinking", "Wave", "Radial"])
        self.assertEqual([z["name"] for z in omen["zone_details"]], ["Omen Logo", "Light Bar", "Front Fan"])
        self.assertEqual(omen["zones"], 3)
        self.assertEqual(omen["led_names"], ["Logo LED", "Bar LED", "Fan LED"])
        self.assertEqual((devices[1]["index"], devices[1]["mode"]), (1, "Static"))

    def test_quoted_active_mode_loses_its_quotes(self):
        text = "0: X\n  Modes: Direct ['Color Cycle']\n"
        device = common.parse_devices(text)[0]
        self.assertEqual(device["mode"], "Color Cycle")
        self.assertEqual(device["available_modes"], ["Direct", "Color Cycle"])

    def test_device_without_modes_line_has_no_mode_keys(self):
        device = common.parse_devices("0: Bare\n  Type: DRAM\n")[0]
        self.assertNotIn("available_modes", device)
        self.assertNotIn("mode", device)


class AtomicWriteTests(unittest.TestCase):
    def test_writes_json_with_mode_0644_whatever_the_umask(self):
        with lib.tempdir() as tmp:
            target = Path(tmp) / "sub" / "doc.json"
            old = os.umask(0o077)
            try:
                common.atomic_write_json(target, {"a": 1})
            finally:
                os.umask(old)
            self.assertEqual(json.loads(target.read_text()), {"a": 1})
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o644)
            self.assertEqual([p.name for p in target.parent.iterdir()], ["doc.json"])

    def test_failed_serialisation_keeps_the_old_file_and_leaves_no_temp(self):
        with lib.tempdir() as tmp:
            target = Path(tmp) / "doc.json"
            common.atomic_write_json(target, {"old": True})
            with self.assertRaises(TypeError):
                common.atomic_write_json(target, {"bad": object()})
            self.assertEqual(json.loads(target.read_text()), {"old": True})
            self.assertEqual([p.name for p in Path(tmp).iterdir()], ["doc.json"])


def _hold(path, seconds, ready):
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    ready.set()
    time.sleep(seconds)
    os.close(fd)


class LockTests(unittest.TestCase):
    def test_second_holder_waits_for_the_first(self):
        with lib.tempdir() as tmp:
            lock = Path(tmp) / "run" / "openrgb.lock"
            lock.parent.mkdir()
            ready = multiprocessing.Event()
            proc = multiprocessing.Process(target=_hold, args=(str(lock), 0.6, ready))
            proc.start()
            self.assertTrue(ready.wait(5))
            started = time.monotonic()
            with common.locked(lock, timeout=5):
                waited = time.monotonic() - started
            proc.join()
            self.assertGreaterEqual(waited, 0.4)

    def test_times_out_when_the_lock_is_never_released(self):
        with lib.tempdir() as tmp:
            lock = Path(tmp) / "openrgb.lock"
            ready = multiprocessing.Event()
            proc = multiprocessing.Process(target=_hold, args=(str(lock), 1.5, ready))
            proc.start()
            self.assertTrue(ready.wait(5))
            with self.assertRaises(common.OpenRGBError) as ctx:
                with common.locked(lock, timeout=0.2):
                    pass
            proc.join()
            self.assertIn("lock", str(ctx.exception))


class RunOpenRGBTests(unittest.TestCase):
    def test_returns_code_and_output_and_serialises_through_the_lock(self):
        with lib.tempdir() as tmp:
            stub = lib.Stub(tmp)
            stub.configure(list_outputs=[lib.OMEN])
            lock = Path(tmp) / "openrgb.lock"
            rc, out, _ = common.run_openrgb(["--noautoconnect", "--list-devices"], binary=stub.bin,
                                            lock=lock, lock_timeout=5, timeout=30)
            self.assertEqual(rc, 0)
            self.assertIn("HP Omen 30L", out)
            self.assertTrue(lock.exists())

    def test_missing_binary_is_a_short_reason(self):
        with lib.tempdir() as tmp:
            with self.assertRaises(common.OpenRGBError) as ctx:
                common.run_openrgb(["--list-devices"], binary=str(Path(tmp) / "nope"),
                                   lock=Path(tmp) / "l", lock_timeout=1, timeout=5)
            self.assertEqual(str(ctx.exception), "openrgb not installed")

    def test_timeout_is_a_short_reason(self):
        with lib.tempdir() as tmp:
            stub = lib.Stub(tmp)
            stub.configure(delay=3)
            with self.assertRaises(common.OpenRGBError) as ctx:
                common.run_openrgb(["--list-devices"], binary=stub.bin,
                                   lock=Path(tmp) / "l", lock_timeout=1, timeout=0.3)
            self.assertEqual(str(ctx.exception), "openrgb timed out")

    def test_command_failed_catches_error_text_with_exit_zero(self):
        self.assertTrue(common.command_failed(255, ""))
        self.assertTrue(common.command_failed(0, "Error: Cannot find device \"9\"\n"))
        self.assertTrue(common.command_failed(0, "Wrong number of colors specified for mode Static\n"))
        self.assertFalse(common.command_failed(0, ""))
        self.assertFalse(common.command_failed(0, "Some unrelated log line\n"))


if __name__ == "__main__":
    unittest.main()
