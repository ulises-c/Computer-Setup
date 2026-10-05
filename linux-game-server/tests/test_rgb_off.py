#!/usr/bin/env python3
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
import unittest
import fcntl
from pathlib import Path

import rgb_testlib as lib

SCRIPT = lib.RGB / "rgb-off.py"
ALLOWED_FLAGS = {"--noautoconnect", "--list-devices", "--device", "--mode", "--color"}


def load_module():
    spec = importlib.util.spec_from_file_location("rgb_off", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RgbOffCase(unittest.TestCase):
    def setUp(self):
        self._tmp = lib.tempdir()
        self.root = Path(self._tmp.name)
        self.stub = lib.Stub(self.root)
        self.env = lib.make_env(self.root, self.stub)
        self.policy_path = Path(self.env["RGB_POLICY_FILE"])

    def tearDown(self):
        self._tmp.cleanup()

    def run_off(self, *args, **env_extra):
        env = {**self.env, **{k: str(v) for k, v in env_extra.items()}}
        argv = list(args) if args else ["--trigger", "manual"]
        return subprocess.run([sys.executable, str(SCRIPT), *argv], env=env,
                              capture_output=True, text=True, timeout=120)

    def policy(self):
        return json.loads(self.policy_path.read_text())


class CommandConstructionTests(RgbOffCase):
    def test_prefers_the_off_mode_when_the_device_lists_one(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        run = self.run_off()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(self.stub.argvs(), [
            ["--noautoconnect", "--list-devices"],
            ["--noautoconnect", "--device", "0", "--mode", "Off"],
        ])
        self.assertEqual(self.policy()["devices"],
                         [{"name": "HP Omen 30L", "mode_used": "Off", "result": "applied"}])

    def test_direct_with_black_when_there_is_no_off_mode(self):
        self.stub.configure(list_outputs=[lib.NO_OFF.replace("1: Strip", "0: Strip")])
        self.assertEqual(self.run_off().returncode, 0)
        self.assertEqual(self.stub.set_calls(),
                         [["--noautoconnect", "--device", "0", "--mode", "Direct", "--color", "000000"]])
        self.assertEqual(self.policy()["devices"][0]["mode_used"], "Direct")

    def test_static_with_black_when_it_is_the_only_safe_mode(self):
        self.stub.configure(list_outputs=[lib.STATIC_ONLY.replace("2: Static", "0: Static")])
        self.assertEqual(self.run_off().returncode, 0)
        self.assertEqual(self.stub.set_calls(),
                         [["--noautoconnect", "--device", "0", "--mode", "Static", "--color", "000000"]])

    def test_mode_name_is_the_one_the_device_lists_not_a_guess(self):
        text = "0: Odd\n  Modes: [direct] 'static'\n  Zones: Z\n"
        self.stub.configure(list_outputs=[text])
        self.assertEqual(self.run_off().returncode, 0)
        self.assertEqual(self.stub.set_calls()[0][4], "direct")

    def test_every_device_gets_its_own_index_and_mode_and_unlisted_modes_are_never_sent(self):
        listing = lib.OMEN + lib.NO_OFF + lib.STATIC_ONLY + lib.NO_SAFE_MODE
        self.stub.configure(list_outputs=[listing])
        run = self.run_off()
        self.assertEqual(run.returncode, 0, run.stderr)
        modes = {d["index"]: d["available_modes"]
                 for d in __import__("rgb_common").parse_devices(listing)}
        sent = {}
        for argv in self.stub.set_calls():
            index = int(argv[argv.index("--device") + 1])
            mode = argv[argv.index("--mode") + 1]
            self.assertIn(mode, modes[index])
            sent[index] = mode
        self.assertEqual(sent, {0: "Off", 1: "Direct", 2: "Static"})
        self.assertEqual([d["result"] for d in self.policy()["devices"]],
                         ["applied", "applied", "applied", "skipped"])
        self.assertIsNone(self.policy()["devices"][3]["mode_used"])
        self.assertEqual(self.policy()["result"], "applied")

    def test_off_that_fails_falls_back_to_a_listed_software_mode(self):
        self.stub.configure(list_outputs=[lib.OMEN], fail_modes=["Off"])
        run = self.run_off()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual([a[a.index("--mode") + 1] for a in self.stub.set_calls()], ["Off", "Direct"])
        self.assertEqual(self.policy()["devices"][0]["mode_used"], "Direct")

    def test_error_text_with_exit_zero_counts_as_a_failure(self):
        self.stub.configure(list_outputs=[lib.OMEN], quiet_error_modes=["Off", "Direct", "Static"])
        run = self.run_off()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.policy()["devices"][0]["result"], "failed")

    def test_only_all_skipped_devices_is_a_failed_policy(self):
        self.stub.configure(list_outputs=[lib.NO_SAFE_MODE.replace("3: ", "0: ")])
        run = self.run_off()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.stub.set_calls(), [])
        self.assertEqual(self.policy()["result"], "failed")

    def test_no_subcommand_other_than_list_and_lighting_is_ever_invoked(self):
        scenarios = [
            dict(list_outputs=[lib.OMEN + lib.NO_OFF + lib.STATIC_ONLY + lib.NO_SAFE_MODE]),
            dict(list_outputs=[lib.OMEN], fail_modes=["Off", "Direct", "Static"]),
            dict(list_outputs=["", lib.OMEN]),
            dict(list_outputs=[""], list_rcs=[1]),
        ]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                self.stub.configure(**scenario)
                self.run_off()
                flags = {a for argv in self.stub.argvs() for a in argv if a.startswith("-")}
                self.assertLessEqual(flags, ALLOWED_FLAGS)
                for argv in self.stub.argvs():
                    self.assertEqual(argv[0], "--noautoconnect")


class RetryTests(RgbOffCase):
    def test_retries_until_devices_appear(self):
        self.stub.configure(list_outputs=["", "", lib.OMEN])
        run = self.run_off()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(self.stub.list_calls()), 3)
        self.assertEqual(self.policy()["result"], "applied")
        self.assertEqual(self.policy()["attempts"], 3)

    def test_nonzero_enumeration_is_retried_too(self):
        self.stub.configure(list_outputs=["", lib.OMEN], list_rcs=[1, 0])
        self.assertEqual(self.run_off().returncode, 0)
        self.assertEqual(len(self.stub.list_calls()), 2)

    def test_never_succeeding_exits_nonzero_with_a_clear_journal_line_and_failed_status(self):
        self.stub.configure(list_outputs=[""])
        run = self.run_off()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(len(self.stub.list_calls()), 6)
        self.assertEqual(self.stub.set_calls(), [])
        self.assertRegex(run.stderr, r"rgb-off: FAILED after 6 attempts: no devices detected")
        policy = self.policy()
        self.assertEqual((policy["result"], policy["applied_at"], policy["devices"]), ("failed", None, []))

    def test_only_the_devices_that_failed_are_retried(self):
        self.stub.configure(list_outputs=[lib.OMEN + lib.NO_OFF], fail_first_sets=3)
        run = self.run_off()
        self.assertEqual(run.returncode, 0, run.stderr)
        per_device = [a[a.index("--device") + 1] for a in self.stub.set_calls()]
        self.assertEqual(per_device, ["0", "0", "0", "1", "0"])
        self.assertEqual([d["result"] for d in self.policy()["devices"]], ["applied", "applied"])

    def test_a_device_that_never_takes_the_command_fails_the_run_but_keeps_the_others(self):
        self.stub.configure(list_outputs=[lib.OMEN + lib.NO_OFF], fail_modes=["Direct", "Static"])
        run = self.run_off()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("rgb-off: FAILED", run.stderr)
        policy = self.policy()
        self.assertEqual(policy["result"], "failed")
        self.assertEqual([d["result"] for d in policy["devices"]], ["applied", "failed"])
        self.assertIsInstance(policy["applied_at"], int)

    def test_default_backoff_is_six_attempts_over_about_two_minutes(self):
        module = load_module()
        self.assertEqual(len(module.DEFAULT_DELAYS) + 1, 6)
        self.assertTrue(100 <= sum(module.DEFAULT_DELAYS) <= 140, module.DEFAULT_DELAYS)


class StatusFileTests(RgbOffCase):
    def test_policy_json_content(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        before = int(time.time())
        self.assertEqual(self.run_off("--trigger", "manual").returncode, 0)
        policy = self.policy()
        self.assertEqual((policy["name"], policy["color"], policy["trigger"], policy["result"]),
                         ("off", "000000", "manual", "applied"))
        self.assertTrue(before <= policy["applied_at"] <= int(time.time()))
        self.assertEqual(policy["boot_id"], "boot-aaaa")
        self.assertEqual(policy["attempts"], 1)

    def test_status_is_world_readable_and_written_atomically(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        old = os.umask(0o077)
        try:
            self.run_off()
        finally:
            os.umask(old)
        self.assertEqual(stat.S_IMODE(self.policy_path.stat().st_mode), 0o644)
        self.assertEqual([p.name for p in self.policy_path.parent.iterdir()], ["rgb-policy.json"])

    def test_a_pending_marker_replaces_last_boots_status_before_openrgb_is_touched(self):
        # Yesterday's 'applied' must not survive into a new run: the status is
        # reset to 'never' first, so a crash or a long retry never shows stale success.
        self.policy_path.parent.mkdir(parents=True)
        self.policy_path.write_text(json.dumps({"result": "applied", "applied_at": 1, "trigger": "boot"}))
        dump = self.root / "seen.txt"
        self.stub.configure(list_outputs=[lib.OMEN], on_call_dump=[str(self.policy_path), str(dump)])
        self.assertEqual(self.run_off("--trigger", "resume").returncode, 0)
        seen = json.loads(dump.read_text().splitlines()[0])
        self.assertEqual((seen["result"], seen["applied_at"], seen["trigger"], seen["devices"]),
                         ("never", None, "resume", []))
        self.assertEqual(self.policy()["result"], "applied")

    def test_missing_openrgb_is_reported_as_a_failure_not_a_traceback(self):
        run = self.run_off(RGB_OPENRGB=self.root / "does-not-exist")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("openrgb not installed", run.stderr)
        self.assertNotIn("Traceback", run.stderr)
        self.assertEqual(self.policy()["result"], "failed")


class TriggerTests(RgbOffCase):
    def fake_systemctl(self, state, rc=0):
        path = self.root / "systemctl"
        path.write_text(f"#!/bin/sh\necho {state}\nexit {rc}\n")
        path.chmod(0o755)
        return path

    def test_unit_trigger_is_recorded(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        for trigger in ("boot", "resume", "manual", "unknown"):
            self.run_off("--trigger", trigger)
            self.assertEqual(self.policy()["trigger"], trigger)

    def test_auto_is_boot_while_systemd_is_still_starting_and_manual_afterwards(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        for state, expected in (("starting", "boot"), ("initializing", "boot"),
                                ("running", "manual"), ("degraded", "manual")):
            with self.subTest(state=state):
                self.run_off("--trigger", "auto", RGB_SYSTEMCTL=self.fake_systemctl(state))
                self.assertEqual(self.policy()["trigger"], expected)

    def test_auto_is_unknown_when_systemctl_cannot_say(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        self.run_off("--trigger", "auto", RGB_SYSTEMCTL=self.root / "no-such-systemctl")
        self.assertEqual(self.policy()["trigger"], "unknown")

    def test_rejects_an_unknown_trigger(self):
        self.assertEqual(self.run_off("--trigger", "bogus").returncode, 2)


class LockTests(RgbOffCase):
    def test_openrgb_calls_wait_for_the_shared_lock(self):
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
        run = self.run_off()
        thread.join()
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertGreaterEqual(self.stub.calls()[0]["t"], released["t"] - 0.05)

    def test_lock_that_never_frees_is_a_retryable_failure_with_a_clear_message(self):
        self.stub.configure(list_outputs=[lib.OMEN])
        lock = Path(self.env["RGB_LOCK_FILE"])
        lock.parent.mkdir(parents=True)
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            run = self.run_off(RGB_LOCK_TIMEOUT="0.2", RGB_OFF_DELAYS="0,0")
        finally:
            os.close(fd)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("lock busy", run.stderr)
        self.assertEqual(self.stub.calls(), [])


if __name__ == "__main__":
    unittest.main()
