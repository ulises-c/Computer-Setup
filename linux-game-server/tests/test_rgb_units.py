#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import rgb_testlib as lib
import rgb_common

RGB = lib.RGB
SLEEP_TARGETS = {"suspend.target", "hibernate.target", "hybrid-sleep.target", "suspend-then-hibernate.target"}
SANDBOX = {"ProtectHome": "yes", "ProtectSystem": "strict", "PrivateTmp": "yes",
           "RuntimeDirectory": "rgb-lock", "RuntimeDirectoryPreserve": "yes"}


def unit(name):
    """{section: {key: [values]}} for a systemd unit file (repeated keys keep every value)."""
    out, section = {}, None
    for raw in (RGB / name).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("["):
            section = line.strip("[]")
            out[section] = {}
        else:
            key, _, value = line.partition("=")
            out[section].setdefault(key, []).append(value)
    return out


def first(u, section, key):
    return u[section][key][0]


class OffUnitTests(unittest.TestCase):
    def test_boot_unit_is_a_hardened_root_oneshot_running_the_installed_script(self):
        u = unit("rgb-off.service")
        svc = u["Service"]
        self.assertEqual(first(u, "Service", "Type"), "oneshot")
        self.assertEqual(first(u, "Service", "ExecStart"), "/usr/local/libexec/rgb-off --trigger auto")
        self.assertNotIn("User", svc)  # root: the HID/i2c nodes are root-only
        for key, value in SANDBOX.items():
            self.assertEqual(first(u, "Service", key), value, key)
        self.assertEqual(first(u, "Service", "StateDirectory"), "rgb-off")
        self.assertIn("HOME=/var/lib/rgb-off", svc["Environment"])
        self.assertIn("/var/lib/host-status", first(u, "Service", "ReadWritePaths"))
        self.assertEqual(first(u, "Service", "NoNewPrivileges"), "yes")
        self.assertEqual(u["Install"]["WantedBy"], ["multi-user.target"])

    def test_the_sandbox_still_lets_openrgb_reach_the_devices(self):
        for name in ("rgb-off.service", "rgb-off-resume.service", "rgb-status.service"):
            svc = unit(name)["Service"]
            for key in ("PrivateDevices", "DeviceAllow", "ProtectKernelModules", "RestrictAddressFamilies"):
                self.assertNotIn(key, svc, f"{name}: {key} could hide /dev/hidraw* or /dev/i2c-*")

    def test_runs_the_script_from_libexec_never_from_the_checkout(self):
        for name in ("rgb-off.service", "rgb-off-resume.service", "rgb-status.service"):
            for command in unit(name)["Service"]["ExecStart"]:
                self.assertTrue(command.startswith("/usr/local/libexec/"), command)

    def test_no_restart_and_no_rgb_off_timer_by_default(self):
        self.assertNotIn("Restart", unit("rgb-off.service")["Service"])
        self.assertFalse(list(RGB.glob("rgb-off*.timer")), "a periodic re-assert is an opt-in, see README")

    def test_dashboard_refresh_after_each_run_is_non_blocking_and_non_fatal(self):
        for name in ("rgb-off.service", "rgb-off-resume.service"):
            self.assertEqual(first(unit(name), "Service", "ExecStopPost"),
                             "-/usr/bin/systemctl start --no-block rgb-status.service")


class ResumeUnitTests(unittest.TestCase):
    def test_sleep_target_pattern(self):
        u = unit("rgb-off-resume.service")
        self.assertEqual(set(first(u, "Unit", "After").split()), SLEEP_TARGETS)
        self.assertEqual(set(first(u, "Install", "WantedBy").split()), SLEEP_TARGETS)
        self.assertEqual(first(u, "Service", "ExecStart"), "/usr/local/libexec/rgb-off --trigger resume")
        self.assertEqual(first(u, "Service", "Type"), "oneshot")

    def test_same_sandbox_and_state_as_the_boot_unit(self):
        boot, resume = unit("rgb-off.service")["Service"], unit("rgb-off-resume.service")["Service"]
        for key in set(boot) - {"ExecStart"}:
            self.assertEqual(boot[key], resume.get(key), key)


class ExporterUnitTests(unittest.TestCase):
    def test_exporter_shares_the_lock_directory_and_keeps_its_own_state_dir(self):
        u = unit("rgb-status.service")
        for key, value in SANDBOX.items():
            self.assertEqual(first(u, "Service", key), value, key)
        self.assertEqual(first(u, "Service", "StateDirectory"), "rgb-status")
        self.assertEqual(first(u, "Service", "Nice"), "10")

    def test_timer_is_unchanged(self):
        timer = (RGB / "rgb-status.timer").read_text()
        self.assertIn("OnBootSec=2min", timer)
        self.assertIn("OnUnitActiveSec=10min", timer)


class PathConsistencyTests(unittest.TestCase):
    def test_default_paths_match_what_the_units_make_writable(self):
        runtime = first(unit("rgb-off.service"), "Service", "RuntimeDirectory")
        self.assertEqual(rgb_common.DEFAULT_LOCK, f"/run/{runtime}/openrgb.lock")
        self.assertEqual(Path(rgb_common.DEFAULT_POLICY).parent.as_posix(), "/var/lib/host-status")
        self.assertEqual(Path(rgb_common.DEFAULT_POLICY).name, "rgb-policy.json")
        for name in ("rgb-off.service", "rgb-off-resume.service", "rgb-status.service"):
            self.assertIn("/var/lib/host-status", first(unit(name), "Service", "ReadWritePaths"))
        import importlib.util
        spec = importlib.util.spec_from_file_location("rgb_status", RGB / "rgb-status.py")
        status = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(status)
        self.assertEqual(status.DEFAULT_CACHE, "/var/lib/rgb-status/devices.json")


@unittest.skipUnless(shutil.which("systemd-analyze"), "systemd-analyze not installed")
class SystemdVerifyTests(unittest.TestCase):
    def test_units_verify_in_a_temp_dir(self):
        with tempfile.TemporaryDirectory(prefix="rgb-verify-") as tmp:
            tmp = Path(tmp)
            fake = tmp / "libexec"
            fake.mkdir()
            for name in ("rgb-off", "rgb-status"):
                (fake / name).write_text("#!/bin/sh\n")
                (fake / name).chmod(0o755)
            files = []
            for name in ("rgb-off.service", "rgb-off-resume.service", "rgb-status.service", "rgb-status.timer"):
                text = (RGB / name).read_text().replace("/usr/local/libexec", str(fake))
                (tmp / name).write_text(text)
                files.append(str(tmp / name))
            run = subprocess.run(["systemd-analyze", "verify", *files], capture_output=True, text=True,
                                 timeout=60)
            problems = [ln for ln in (run.stdout + run.stderr).splitlines()
                        if re.search(r"rgb-(off|status)", ln)
                        and not re.search(r"Failed to (?:create|connect|load credentials)", ln)]
            self.assertEqual(problems, [], run.stdout + run.stderr)


class SetupScriptTests(unittest.TestCase):
    SETUP = RGB / "setup.sh"

    def dry_run(self):
        return subprocess.run(["bash", str(self.SETUP), "--dry-run"], capture_output=True, text=True,
                              timeout=60, env={"PATH": os.environ["PATH"], "HOME": "/nonexistent"})

    def test_dry_run_installs_every_file_and_enables_both_services(self):
        run = self.dry_run()
        self.assertEqual(run.returncode, 0, run.stderr)
        out = run.stdout
        for needle in (
            "install -o root -g root -m 755 " + str(RGB / "rgb-off.py") + " /usr/local/libexec/rgb-off",
            "install -o root -g root -m 755 " + str(RGB / "rgb-status.py") + " /usr/local/libexec/rgb-status",
            "install -o root -g root -m 644 " + str(RGB / "rgb_common.py") + " /usr/local/libexec/rgb_common.py",
            "rgb-off.service", "rgb-off-resume.service", "rgb-status.service", "rgb-status.timer",
            "/etc/systemd/system/",
            "systemctl daemon-reload",
            "systemctl enable rgb-off.service rgb-off-resume.service",
            "systemctl enable --now rgb-status.timer",
            "systemctl start rgb-off.service",
            "systemctl start rgb-status.service",
        ):
            self.assertIn(needle, out)
        self.assertTrue(all(line.startswith("[dry-run] ") for line in out.splitlines()), out)

    def test_off_service_is_started_before_the_exporter_so_the_card_sees_the_result(self):
        out = self.dry_run().stdout
        self.assertLess(out.index("systemctl start rgb-off.service"), out.index("systemctl start rgb-status.service"))

    def test_dry_run_is_repeatable_and_does_not_need_root_or_openrgb(self):
        self.assertEqual(self.dry_run().stdout, self.dry_run().stdout)

    @unittest.skipIf(os.geteuid() == 0, "would really install when run as root")
    def test_refuses_to_run_without_root(self):
        run = subprocess.run(["bash", str(self.SETUP)], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 1)
        self.assertIn("run with sudo", run.stderr)

    def test_rejects_unknown_arguments(self):
        run = subprocess.run(["bash", str(self.SETUP), "--now"], capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, 1)

    def test_installed_files_are_all_in_the_checkout(self):
        for name in ("rgb-off.py", "rgb-status.py", "rgb_common.py", "rgb-off.service",
                     "rgb-off-resume.service", "rgb-status.service", "rgb-status.timer"):
            self.assertTrue((RGB / name).is_file(), name)
        self.assertTrue(os.access(RGB / "rgb-off.py", os.X_OK))
        self.assertTrue(os.access(RGB / "rgb-status.py", os.X_OK))


if __name__ == "__main__":
    unittest.main()
