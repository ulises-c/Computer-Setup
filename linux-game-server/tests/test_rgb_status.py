#!/usr/bin/env python3
import calendar
import fcntl
import importlib.util
import json
import os
import subprocess
import sys
import threading
import time
import unittest
from pathlib import Path

import rgb_testlib as lib

SCRIPT = lib.RGB / "rgb-status.py"
spec = importlib.util.spec_from_file_location("rgb", SCRIPT)
rgb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rgb)

SAMPLE = """0: HP Omen 30L
  Type:           Motherboard
  Description:    HP Omen 30L Device
  Location:       HID: /dev/hidraw0
  Modes: Direct [Static] Breathing 'Color Cycle'
  Zones: Logo Bar 'Front Fan' 'Bottom Fan LED' 'Middle Fan LED' 'Top Fan LED'
  LEDs: Logo Bar

1: Other
  Modes: [Direct]
"""

# 2026-10-05 08:02 in America/Los_Angeles (PDT, UTC-7).
APPLIED_AT = calendar.timegm((2026, 10, 5, 15, 2, 0))


def omen_devices():
    return rgb.parse(lib.OMEN)


def policy(result, applied_at=APPLIED_AT, trigger="boot", devices=None):
    return {"name": "off", "color": "000000", "applied_at": applied_at, "trigger": trigger,
            "result": result,
            "devices": devices if devices is not None else
            [{"name": "HP Omen 30L", "mode_used": "Off" if result == "applied" else None, "result": result}]}


NEVER = {"name": "off", "color": "000000", "applied_at": None, "trigger": None,
         "result": "never", "devices": []}


class ParseTests(unittest.TestCase):
    def test_devices_modes_and_zones(self):
        devices = rgb.parse("<h2>warning</h2>\n" + SAMPLE)
        self.assertEqual(devices[0]["name"], "HP Omen 30L")
        self.assertEqual(devices[0]["type"], "Motherboard")
        self.assertEqual(devices[0]["mode"], "Static")
        self.assertEqual(devices[0]["zones"], 6)
        self.assertEqual(devices[0].get("zone_details"), [
            {"name": name, "status": "detected", "color": None, "readback": False}
            for name in ["Logo", "Bar", "Front Fan", "Bottom Fan LED", "Middle Fan LED", "Top Fan LED"]
        ])
        self.assertEqual(devices[0]["available_modes"], ["Direct", "Static", "Breathing", "Color Cycle"])
        self.assertEqual(devices[0]["mode_source"], "last-set / device-wide; not hardware readback")
        self.assertEqual(devices[0]["led_names"], ["Logo", "Bar"])
        self.assertEqual(devices[1]["mode"], "Direct")

    def test_empty_output(self):
        self.assertEqual(rgb.parse(""), [])

    def test_the_output_schema_has_no_enumeration_index(self):
        self.assertNotIn("index", rgb.parse(SAMPLE)[0])


class RowsContractTests(unittest.TestCase):
    def setUp(self):
        os.environ["TZ"] = "America/Los_Angeles"
        time.tzset()

    def test_applied_rows(self):
        rows = rgb.build_rows(omen_devices(), policy("applied"), None)
        self.assertEqual(rows, [
            {"name": "HP Omen 30L", "label": "Motherboard · Direct (last-set, not readback)"},
            {"name": "Omen Logo", "label": "commanded off #000000 at 08:02"},
            {"name": "Light Bar", "label": "commanded off #000000 at 08:02"},
            {"name": "Front Fan", "label": "commanded off #000000 at 08:02"},
            {"name": "Lighting policy", "label": "off (#000000) · applied 08:02 by boot"},
        ])

    def test_never_applied_rows(self):
        rows = rgb.build_rows(omen_devices(), NEVER, None)
        self.assertEqual([r["label"] for r in rows], [
            "Motherboard · Direct (last-set, not readback)",
            "detected", "detected", "detected",
            "off (#000000) · never applied"])

    def test_failed_rows(self):
        rows = rgb.build_rows(omen_devices(), policy("failed", applied_at=None, trigger="resume"), None)
        self.assertEqual([r["label"] for r in rows][1:], [
            "off command failed", "off command failed", "off command failed",
            "off (#000000) · last attempt failed"])

    def test_skipped_device_is_not_claimed_to_be_off(self):
        rows = rgb.build_rows(omen_devices(), policy("applied", devices=[
            {"name": "HP Omen 30L", "mode_used": None, "result": "skipped"}]), None)
        self.assertEqual(rows[1]["label"], "not commanded (no off-capable mode)")

    def test_each_device_follows_its_own_policy_result(self):
        devices = rgb.parse(lib.OMEN + lib.NO_OFF)
        pol = policy("failed", devices=[
            {"name": "HP Omen 30L", "mode_used": "Off", "result": "applied"},
            {"name": "Strip Controller", "mode_used": None, "result": "failed"}])
        labels = {r["name"]: r["label"] for r in rgb.build_rows(devices, pol, None)}
        self.assertEqual(labels["Omen Logo"], "commanded off #000000 at 08:02")
        self.assertEqual(labels["Strip"], "off command failed")
        self.assertEqual(labels["Lighting policy"], "off (#000000) · last attempt failed")

    def test_device_unknown_to_the_policy_stays_detected(self):
        pol = policy("applied", devices=[{"name": "Something Else", "mode_used": "Off", "result": "applied"}])
        self.assertEqual(rgb.build_rows(omen_devices(), pol, None)[1]["label"], "detected")

    def test_openrgb_error_is_a_single_row(self):
        rows = rgb.build_rows([], policy("applied"), "openrgb exited 1")
        self.assertEqual(rows, [{"name": "OpenRGB", "label": "unavailable: openrgb exited 1"}])

    def test_no_devices_without_error_still_shows_the_policy(self):
        self.assertEqual(rgb.build_rows([], NEVER, None),
                         [{"name": "Lighting policy", "label": "off (#000000) · never applied"}])

    def test_no_row_ever_claims_a_current_colour(self):
        rows = rgb.build_rows(omen_devices(), policy("applied"), None)
        for row in rows:
            self.assertNotRegex(row["label"].lower(), r"current|now|is #|color:|colour:")


class LoadPolicyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = lib.tempdir()
        self.path = Path(self._tmp.name) / "rgb-policy.json"

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, doc):
        self.path.write_text(json.dumps(doc))

    def test_absent_file_is_never_with_nulls(self):
        self.assertEqual(rgb.load_policy(self.path, "b1"), NEVER)

    def test_contract_keys_only(self):
        self.write({**policy("applied"), "boot_id": "b1", "attempts": 3, "attempted_at": 5})
        loaded = rgb.load_policy(self.path, "b1")
        self.assertEqual(loaded, policy("applied"))

    def test_status_from_an_earlier_boot_is_never(self):
        self.write({**policy("applied"), "boot_id": "old-boot"})
        self.assertEqual(rgb.load_policy(self.path, "b1"), NEVER)

    def test_pending_marker_is_never(self):
        self.write({**NEVER, "trigger": "boot", "boot_id": "b1"})
        self.assertEqual(rgb.load_policy(self.path, "b1"), NEVER)

    def test_junk_is_never(self):
        for junk in ("not json", "[1, 2]", json.dumps({"result": "fantastic"})):
            self.path.write_text(junk)
            self.assertEqual(rgb.load_policy(self.path, "b1"), NEVER)

    def test_out_of_contract_values_are_normalised(self):
        self.write({"result": "applied", "trigger": "cron", "applied_at": "yesterday",
                    "devices": [{"name": "X", "mode_used": 5, "result": "great"}, "junk"]})
        loaded = rgb.load_policy(self.path, "b1")
        self.assertEqual((loaded["trigger"], loaded["applied_at"]), ("unknown", None))
        self.assertEqual(loaded["devices"], [{"name": "X", "mode_used": None, "result": "failed"}])


class ExporterCase(unittest.TestCase):
    def setUp(self):
        self._tmp = lib.tempdir()
        self.root = Path(self._tmp.name)
        self.stub = lib.Stub(self.root)
        self.env = lib.make_env(self.root, self.stub)
        self.out = self.root / "host-status" / "rgb.json"
        self.policy_path = Path(self.env["RGB_POLICY_FILE"])
        self.cache_path = Path(self.env["RGB_CACHE_FILE"])

    def tearDown(self):
        self._tmp.cleanup()

    def run_status(self, *args, **env_extra):
        env = {**self.env, **{k: str(v) for k, v in env_extra.items()}}
        run = subprocess.run([sys.executable, str(SCRIPT), *args, str(self.out)], env=env,
                             capture_output=True, text=True, timeout=120)
        return run

    def doc(self):
        return json.loads(self.out.read_text())

    def write_policy(self, doc):
        self.policy_path.parent.mkdir(parents=True, exist_ok=True)
        self.policy_path.write_text(json.dumps(doc))


class ContractOutputTests(ExporterCase):
    def test_applied_policy_end_to_end_keeps_existing_fields_and_adds_policy_and_rows(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.write_policy({**policy("applied"), "boot_id": "boot-aaaa", "attempts": 1})
        run = self.run_status()
        self.assertEqual(run.returncode, 0, run.stderr)
        doc = self.doc()
        self.assertEqual(set(doc), {"updated", "devices", "policy", "rows"})
        device = doc["devices"][0]
        self.assertEqual({"name", "type", "mode", "zones", "mode_source", "available_modes",
                          "zone_details", "led_names"}, set(device))
        self.assertEqual(doc["policy"], policy("applied"))
        self.assertEqual(doc["rows"][0], {"name": "HP Omen 30L",
                                          "label": "Motherboard · Direct (last-set, not readback)"})
        self.assertEqual(doc["rows"][-1], {"name": "Lighting policy",
                                           "label": "off (#000000) · applied 08:02 by boot"})
        self.assertEqual(oct(self.out.stat().st_mode & 0o777), "0o644")

    def test_missing_policy_file_is_never(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.assertEqual(self.run_status().returncode, 0)
        doc = self.doc()
        self.assertEqual(doc["policy"], NEVER)
        self.assertEqual(doc["rows"][-1]["label"], "off (#000000) · never applied")
        self.assertEqual({r["label"] for r in doc["rows"][1:4]}, {"detected"})

    def test_policy_from_a_previous_boot_is_not_reported_as_applied(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.write_policy({**policy("applied"), "boot_id": "an-earlier-boot"})
        self.run_status()
        self.assertEqual(self.doc()["policy"]["result"], "never")

    def test_failed_policy(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.write_policy({**policy("failed", applied_at=None), "boot_id": "boot-aaaa"})
        self.run_status()
        doc = self.doc()
        self.assertEqual(doc["policy"]["result"], "failed")
        self.assertEqual(doc["rows"][-1]["label"], "off (#000000) · last attempt failed")

    def test_openrgb_error_keeps_error_field_and_single_row_but_still_reports_policy(self):
        self.stub.configure(list_outputs=[""], list_rcs=[1])
        self.write_policy({**policy("applied"), "boot_id": "boot-aaaa"})
        run = self.run_status()
        self.assertEqual(run.returncode, 0, run.stderr)
        doc = self.doc()
        self.assertEqual(doc["error"], "openrgb exited 1")
        self.assertEqual(doc["devices"], [])
        self.assertEqual(doc["rows"], [{"name": "OpenRGB", "label": "unavailable: openrgb exited 1"}])
        self.assertEqual(doc["policy"]["result"], "applied")

    def test_missing_openrgb_binary(self):
        run = self.run_status(RGB_OPENRGB=self.root / "nope")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.doc()["rows"],
                         [{"name": "OpenRGB", "label": "unavailable: openrgb not installed"}])

    def test_no_devices_is_not_an_error(self):
        self.stub.configure(list_outputs=[""])
        self.run_status()
        doc = self.doc()
        self.assertNotIn("error", doc)
        self.assertEqual([r["name"] for r in doc["rows"]], ["Lighting policy"])


class ProbeCacheTests(ExporterCase):
    def test_second_run_reuses_the_cache_instead_of_probing_hardware(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        first = self.doc()
        self.run_status()
        self.assertEqual(len(self.stub.list_calls()), 1)
        self.assertEqual(self.doc()["devices"], first["devices"])
        self.assertEqual(self.doc()["rows"][0], first["rows"][0])

    def test_policy_is_still_refreshed_from_the_file_on_a_cache_hit(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        self.assertEqual(self.doc()["policy"]["result"], "never")
        self.write_policy({**policy("applied"), "boot_id": "boot-aaaa"})
        self.run_status()
        self.assertEqual(len(self.stub.list_calls()), 1)
        self.assertEqual(self.doc()["policy"]["result"], "applied")

    def test_cache_hit_does_not_need_the_hardware_lock(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        lock = Path(self.env["RGB_LOCK_FILE"])
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            run = self.run_status(RGB_LOCK_TIMEOUT="0.2")
        finally:
            os.close(fd)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertNotIn("error", self.doc())

    def test_stale_cache_is_reprobed(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        cache = json.loads(self.cache_path.read_text())
        cache["probed_at"] -= 2 * 86400
        self.cache_path.write_text(json.dumps(cache))
        self.run_status()
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_max_age_is_configurable(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        cache = json.loads(self.cache_path.read_text())
        cache["probed_at"] -= 120
        self.cache_path.write_text(json.dumps(cache))
        self.run_status(RGB_PROBE_MAX_AGE="60")
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_new_boot_reprobes_once(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        Path(self.env["RGB_BOOT_ID_FILE"]).write_text("boot-bbbb\n")
        self.run_status()
        self.run_status()
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_refresh_flag_forces_a_probe(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        self.run_status("--refresh")
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_failed_and_empty_probes_are_not_cached(self):
        self.stub.configure(list_outputs=["", ""], list_rcs=[1, 0])
        self.run_status()
        self.run_status()
        self.assertFalse(self.cache_path.exists())
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_corrupt_or_foreign_cache_is_ignored(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.cache_path.parent.mkdir(parents=True)
        for junk in ("garbage", json.dumps({"schema": 99, "devices": [{"name": "x"}]}), "[]"):
            self.cache_path.write_text(junk)
            self.run_status()
        self.assertEqual(len(self.stub.list_calls()), 3)
        self.assertEqual(self.doc()["devices"][0]["name"], "HP Omen 30L")

    def test_cache_is_private(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        self.assertEqual(self.cache_path.stat().st_mode & 0o077, 0)


class ExporterLockTests(ExporterCase):
    def test_probe_waits_for_the_set_colour_lock(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        lock = Path(self.env["RGB_LOCK_FILE"])
        lock.parent.mkdir(parents=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        released = {}

        def release():
            time.sleep(1.0)
            released["t"] = time.time()
            os.close(fd)

        thread = threading.Thread(target=release)
        thread.start()
        run = self.run_status()
        thread.join()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertGreaterEqual(self.stub.calls()[0]["t"], released["t"] - 0.05)

    def test_lock_that_never_frees_is_reported_not_hung(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        lock = Path(self.env["RGB_LOCK_FILE"])
        lock.parent.mkdir(parents=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            run = self.run_status(RGB_LOCK_TIMEOUT="0.2")
        finally:
            os.close(fd)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("lock busy", self.doc()["error"])
        self.assertEqual(self.stub.calls(), [])

    def test_only_the_list_command_is_ever_invoked(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_status()
        self.assertEqual(self.stub.argvs(), [["--noautoconnect", "--list-devices"]])


if __name__ == "__main__":
    unittest.main()
