import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


SOURCE = Path(__file__).resolve().parents[1]


def reset_child_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.tmp.name)
        self.host = self.root / "macos-server"
        self.host.mkdir()
        for name in ("lib.sh", "agents.sh", "backup/run.sh", "power/power.sh"):
            dest = self.host / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE / name, dest)
        for template in SOURCE.glob("*/*.plist.template"):
            dest = self.host / template.relative_to(SOURCE)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(template, dest)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.root / "home"),
                        PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                        CALLS=str(self.root / "calls"))
        self.stub("brew", 'printf "/opt/testbrew\\n"')
        self.stub("python3", f'exec "{sys.executable}" "$@"')
        self.stub("launchctl", 'printf "%s\\n" "$*" >> "$CALLS"\n'
                  'if [[ "$1" == list ]]; then printf "%s\\n" "${AGENT_STATE:-123 0 net.computer-setup.mac-backup}"; fi')

    def tearDown(self):
        self.tmp.cleanup()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def bash(self, code):
        return subprocess.run(["/bin/bash", "-c", code], env=self.env,
                              text=True, capture_output=True, timeout=10)

    def test_active_backup_reload_is_deferred(self):
        result = self.bash(f'source "{self.host}/lib.sh"; agent_load net.computer-setup.mac-backup')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertNotIn("bootout", calls)
        self.assertNotIn("bootstrap", calls)
        self.assertIn("after", result.stdout.lower())
        self.assertIn("agents.sh install", result.stdout)


    def power_stubs(self, freeze):
        self.stub("pmset", 'printf " sleep 0\\n disksleep 0\\n displaysleep 10\\n standby 0\\n autorestart 1\\n womp 1\\n tcpkeepalive 1\\n"')
        self.stub("systemsetup", freeze)
        self.stub("sudo", 'printf "unexpected sudo\\n" >&2; exit 99')

    def test_plist_paths_are_literal_xml_text(self):
        special = 'spaces & <tag> "quote" | back\\slash @HOME@ café'
        self.env["HOME"] = str(self.root / special)
        self.env["SPECIAL"] = special
        result = self.bash(f'''set -e; source "{self.host}/lib.sh"
REPO_ROOT="$HOME/repo"; BREW_PREFIX="$HOME/brew"
render_plist "{self.host}/glances/net.computer-setup.glances.plist.template" net.test "CONF=$HOME/conf"
''')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        dest = Path(self.env["HOME"]) / "Library/LaunchAgents/net.test.plist"
        data = plistlib.loads(dest.read_bytes())
        self.assertEqual(data["ProgramArguments"][0], f'{self.env["HOME"]}/brew/bin/glances')
        self.assertEqual(data["ProgramArguments"][2], f'{self.env["HOME"]}/conf')
        self.assertEqual(data["StandardOutPath"], f'{self.env["HOME"]}/Library/Logs/computer-setup/glances.log')

    def test_plist_dry_run_has_no_installed_files(self):
        result = self.bash(f'''set -e; source "{self.host}/lib.sh"; DRY_RUN=true
render_plist "{self.host}/status/net.computer-setup.host-status.plist.template" net.test''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[dry-run]", result.stdout)
        self.assertFalse((Path(self.env["HOME"]) / "Library/LaunchAgents").exists())
        self.assertFalse((Path(self.env["HOME"]) / "Library/Logs/computer-setup").exists())

    def test_restart_freeze_off_is_drift(self):
        self.power_stubs('printf "Restart After Freeze: Off\\n"')
        result = self.bash(f'/bin/bash "{self.host}/power/power.sh" --check')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("change", result.stdout)

    def test_restart_freeze_privilege_warning_is_not_drift(self):
        self.power_stubs('printf "You need administrator access to run this tool... exiting!\\n"; exit 1')
        result = self.bash(f'/bin/bash "{self.host}/power/power.sh" --check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning", result.stderr)
        self.assertIn("sudo", result.stderr)

    def backup_fixture(self, body, notifier_body=""):
        script = self.host / "backup/backup.sh"
        script.write_text('''#!/bin/bash
if [[ "${1:-}" == notify-failure ]]; then
''' + notifier_body + '''
  printf 'failed\\n' > "$CALLS.status"
  printf 'notified\\n' >> "$CALLS"
  exit "${NOTIFIER_EXIT:-0}"
fi
''' + body)

    def test_backup_child_failure_notifies_once(self):
        self.backup_fixture('/bin/bash -c "exit 7"\n')
        self.env["NOTIFIER_EXIT"] = "9"
        result = self.bash(f'/bin/bash "{self.host}/backup/run.sh"')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / "calls").read_text(), "notified\n")
        self.assertEqual((self.root / "calls.status").read_text(), "failed\n")

    def check_backup_cancellation(self, sig):
        self.backup_fixture('''trap 'printf "cleaned\\n" >> "$CALLS"' EXIT
/bin/sleep 30 &
pid=$!
printf '%s\\n' "$pid" > "$CALLS.child"
printf 'running\\n' > "$CALLS.status"
wait "$pid"
''')
        proc = subprocess.Popen(["/bin/bash", str(self.host / "backup/run.sh")],
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True,
                                preexec_fn=reset_child_signals)
        child = None
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "calls.child").exists():
                if time.monotonic() > deadline:
                    self.fail("backup did not start")
                time.sleep(0.02)
            child = int((self.root / "calls.child").read_text())
            proc.send_signal(sig)
            try:
                stdout, stderr = proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                self.fail("termination left the backup child running instead of notifying")
            self.assertNotEqual(proc.returncode, 0, stdout + stderr)
            self.assertEqual((self.root / "calls.status").read_text(), "failed\n")
            self.assertEqual((self.root / "calls").read_text(), "cleaned\nnotified\n")
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
            child = None
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            if child is not None:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.communicate(timeout=5)

    def test_backup_term_notifies_after_child_cleanup(self):
        self.check_backup_cancellation(signal.SIGTERM)

    def test_backup_int_notifies_after_child_cleanup(self):
        self.check_backup_cancellation(signal.SIGINT)

    def check_engine_cleanup_restart(self, sig=None, fail_rm=False, hang=False):
        shutil.copyfile(SOURCE.parent / "server-base/backup/backup.sh",
                        self.host / "backup/backup.sh")
        (self.host / "backup/sources.sh").write_text(
            "BACKUP_NAME=fixture\nBACKUP_LABEL=Fixture\nBACKUP_UNIT=fixture.service\n"
            "resolve_sources() { :; }\n")
        self.stub("bash", 'exec /bin/bash "$@"')
        self.stub("jq", f'exec "{shutil.which("jq")}" "$@"')
        self.stub("hostname", 'printf "fixture\\n"')
        self.stub("restic", 'printf "unexpected restic\\n" >&2; exit 99')
        self.stub("curl", 'printf "%s\\n" "$*" >> "$CALLS.notifications"')
        if fail_rm:
            self.stub("rm", '[[ -e "$FIXTURE/stopped-once" ]] && exit 1; exec /bin/rm "$@"')
        docker = self.bin / "docker"
        docker.write_text(f"#!{sys.executable}\n" + '''import os
from pathlib import Path
import subprocess
import sys
import time
root = Path(os.environ["FIXTURE"])
with (root / "pids").open("a") as stream:
    stream.write(str(os.getpid()) + "\\n")
command = sys.argv[1]
if command == "inspect":
    print("true")
elif command == "stop":
    (root / "state").write_text("stopped")
    (root / "stopped-once").touch()
elif command == "run":
    print("fixture archive")
elif command == "start":
    if not (root / "first-start").exists():
        (root / "first-start").touch()
        sys.exit(1)
    (root / "cleanup-start.tmp").write_text(str(os.getppid()))
    (root / "cleanup-start.tmp").replace(root / "cleanup-start")
    if os.environ.get("HANG"):
        helper = subprocess.Popen(["sleep", "60"])
        (root / "pids").open("a").write(str(helper.pid) + "\\n")
        time.sleep(60)
    time.sleep(1)
    (root / "state").write_text("running")
else:
    sys.exit("unexpected Docker invocation")
''')
        docker.chmod(0o755)
        env = {key: self.env[key] for key in ("HOME", "PATH", "CALLS")}
        env.update(FIXTURE=str(self.root), RESTIC_REPOSITORY="sftp:fixture:/primary",
                   RESTIC_PASSWORD="fixture", STAGING_DIR=str(self.root / "staging"),
                   STATUS_JSON=str(self.root / "status.json"),
                   NTFY_URL="https://ntfy.example", KUMA_PUSH_URL="")
        if hang:
            env.update(HANG="1", BACKUP_RECOVERY_TIMEOUT_SECONDS="2")
        proc = subprocess.Popen(["/bin/bash", str(self.host / "backup/run.sh")],
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True,
                                preexec_fn=reset_child_signals)
        engine = None
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "cleanup-start").exists():
                if proc.poll() is not None or time.monotonic() > deadline:
                    self.fail("actual engine did not reach cleanup restart")
                time.sleep(0.01)
            engine = int((self.root / "cleanup-start").read_text())
            if sig is not None:
                proc.send_signal(sig)
            stdout, stderr = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 1 if sig is None else 128 + sig,
                             stdout + stderr)
            if hang:
                self.assertEqual((self.root / "state").read_text(), "stopped")
                self.assertIn("did not finish within 2s", stdout + stderr)
                self.assertIn("could not restart container portainer", stdout + stderr)
            else:
                self.assertEqual((self.root / "state").read_text(), "running",
                                 "cleanup did not restart the quiesced container")
            if fail_rm:
                self.assertIn("could not remove staging", stdout + stderr)
            status = json.loads((self.root / "status.json").read_text())
            self.assertEqual(status["status"], "failed")
            self.assertFalse(status["notifier_pending"])
            notifications = (self.root / "calls.notifications").read_text().splitlines()
            self.assertEqual(len(notifications), 1, notifications)
            self.assertIn("Fixture backup FAILED", notifications[0])
            for pid in [engine, *map(int, (self.root / "pids").read_text().splitlines())]:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    if Path(f"/proc/{pid}/stat").exists() and \
                            Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] == "Z":
                        break
                    time.sleep(0.05)
                else:
                    self.fail(f"leaked process {pid}")
        finally:
            for pgid in (engine, proc.pid):
                if pgid is not None:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            proc.communicate(timeout=5)

    def test_actual_engine_cleanup_restart_survives_wrapper_term(self):
        self.check_engine_cleanup_restart(signal.SIGTERM)

    def test_actual_engine_cleanup_restart_survives_wrapper_int(self):
        self.check_engine_cleanup_restart(signal.SIGINT)

    def test_actual_engine_cleanup_restart_without_cancellation(self):
        self.check_engine_cleanup_restart()

    def test_failed_staging_removal_does_not_skip_restart(self):
        self.check_engine_cleanup_restart(fail_rm=True)

    def test_hung_recovery_is_bounded_and_still_notifies(self):
        self.check_engine_cleanup_restart(hang=True)

    def test_hung_recovery_is_bounded_under_wrapper_term(self):
        self.check_engine_cleanup_restart(signal.SIGTERM, hang=True)

    def check_served_status_on_failure(self, case):
        shutil.copyfile(SOURCE.parent / "server-base/backup/backup.sh", self.host / "backup/backup.sh")
        if case != "missing-sources":
            shutil.copyfile(SOURCE / "backup/sources.sh", self.host / "backup/sources.sh")
        served = self.host / "status/www/backup-status.json"
        served.parent.mkdir(parents=True)
        served.write_text('{"status":"success","last_run":"2026-01-01T00:00:00Z"}')
        self.stub("bash", 'exec /bin/bash "$@"')
        self.stub("jq", f'exec "{shutil.which("jq")}" "$@"')
        self.stub("hostname", 'printf "fixture\\n"')
        self.stub("curl", 'printf "%s\\n" "$*" >> "$CALLS.notifications"')
        env = {key: self.env[key] for key in ("HOME", "PATH", "CALLS")}
        env.update(NTFY_URL="https://ntfy.example", KUMA_PUSH_URL="")
        if case == "early":
            env["BACKUP_RECOVERY_TIMEOUT_SECONDS"] = "0"
        result = subprocess.run(["/bin/bash", str(self.host / "backup/run.sh")], env=env,
                                text=True, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        status = json.loads(served.read_text())
        self.assertEqual(status["status"], "failed", result.stderr)
        self.assertFalse(status["notifier_pending"])
        self.assertFalse((self.host / "backup/status").exists(), "status written outside the served path")
        notifications = (self.root / "calls.notifications").read_text().splitlines()
        self.assertEqual(len(notifications), 1, notifications)

    def test_early_failure_updates_the_served_status(self):
        self.check_served_status_on_failure("early")

    def test_ordinary_failure_updates_the_served_status(self):
        self.check_served_status_on_failure("ordinary")

    def test_missing_sources_still_updates_the_served_status(self):
        self.check_served_status_on_failure("missing-sources")

    def test_recovery_timeout_must_be_a_bounded_integer(self):
        shutil.copyfile(SOURCE.parent / "server-base/backup/backup.sh", self.host / "backup/backup.sh")
        (self.host / "backup/sources.sh").write_text(
            "BACKUP_NAME=fixture\nBACKUP_LABEL=Fixture\nBACKUP_UNIT=fixture.service\nresolve_sources() { :; }\n")
        for value in ("0", "-1", "1.5", "10000", "9223372036854775807"):
            with self.subTest(value=value):
                env = dict(self.env, BACKUP_RECOVERY_TIMEOUT_SECONDS=value, STATUS_JSON=str(self.root / "s.json"))
                result = subprocess.run(["/bin/bash", str(self.host / "backup/backup.sh")], env=env,
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("from 1 to 9999", result.stderr)

    def test_idle_backup_can_reload(self):
        self.env["AGENT_STATE"] = "- 0 net.computer-setup.mac-backup"
        result = self.bash(f'source "{self.host}/lib.sh"; agent_load net.computer-setup.mac-backup')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = (self.root / "calls").read_text()
        self.assertIn("bootout", calls)
        self.assertIn("bootstrap", calls)

    def test_agent_install_preserves_running_backup(self):
        shutil.copyfile(SOURCE / "glances/glances.conf.in", self.host / "glances/glances.conf.in")
        (self.host / "backup/.env").write_text("# isolated fixture, no secrets\n")
        self.stub("tailscale", "exit 1")
        self.stub("jq", "exit 0")
        result = self.bash(f'/bin/bash "{self.host}/agents.sh" install')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("defer mac-backup reload", result.stdout)
        calls = (self.root / "calls").read_text().splitlines()
        self.assertFalse(any("mac-backup" in line for line in calls))
        dest = Path(self.env["HOME"]) / "Library/LaunchAgents/net.computer-setup.mac-backup.plist"
        data = plistlib.loads(dest.read_bytes())
        self.assertEqual(data["StartCalendarInterval"], {"Hour": 3, "Minute": 0})
        self.assertIn("<!-- 03:00 local", dest.read_text())

    def test_backup_success_does_not_notify(self):
        self.backup_fixture("exit 0\n")
        result = self.bash(f'/bin/bash "{self.host}/backup/run.sh"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "calls").exists())

    def test_termination_during_notifier_preserves_bookkeeping(self):
        self.backup_fixture("exit 7\n", 'printf "%s\\n" "$$" > "$CALLS.notifier"; /bin/sleep 0.4\n')
        proc = subprocess.Popen(["/bin/bash", str(self.host / "backup/run.sh")],
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True,
                                preexec_fn=reset_child_signals)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / "calls.notifier").exists():
                if time.monotonic() > deadline:
                    self.fail("failure notifier did not start")
                time.sleep(0.02)
            notifier = int((self.root / "calls.notifier").read_text())
            proc.send_signal(signal.SIGTERM)
            os.kill(notifier, signal.SIGTERM)
            proc.send_signal(signal.SIGINT)
            stdout, stderr = proc.communicate(timeout=5)
            self.assertNotEqual(proc.returncode, 0, stdout + stderr)
            self.assertTrue((self.root / "calls.status").exists(), "failure bookkeeping was interrupted")
            self.assertEqual((self.root / "calls.status").read_text(), "failed\n")
            self.assertEqual((self.root / "calls").read_text(), "notified\n")
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate(timeout=5)

    def test_restart_freeze_on_is_compliant(self):
        self.power_stubs('printf "Restart After Freeze: On\\n"')
        result = self.bash(f'/bin/bash "{self.host}/power/power.sh" --check')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("On", result.stdout)
        self.assertNotIn("change", result.stdout)


if __name__ == "__main__":
    unittest.main()
