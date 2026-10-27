"""The promote gate on acceptance reports (rs-sdk/worlds/acceptance.py + world.sh) against a stub docker.

The bot host's post-update suite writes one JSON report per run; world.sh records it next to the
candidate list and refuses to promote an image without a passing, complete report for that exact
image id that finished after the image was built. Needs GNU date and flock (the game host has both).
"""
from pathlib import Path
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORLDS = ROOT / "rs-sdk/worlds"
OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
BUILT = "2026-10-26T13:45:52.925034851-07:00"  # docker's Created format (nanoseconds, offset)
AFTER = "2026-10-27T03:00:00.000Z"
BEFORE = "2026-10-26T20:00:00.000Z"

spec = importlib.util.spec_from_file_location("acceptance", WORLDS / "acceptance.py")
acceptance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acceptance)


def report(image=NEW, passed=True, finished=AFTER, complete=True, run="20261027T030000Z-w100-x"):
    return {
        "version": 1, "kind": "rs-sdk-acceptance", "runId": run, "startedAt": "2026-10-27T02:00:00.000Z",
        "finishedAt": finished, "durationS": 3600, "world": {"id": 100, "role": "test", "mode": "isolated"},
        "image": image, "sdk": {"commit": "6d88e67a6aaa"}, "bots": ["bot_a", "bot_b"], "complete": complete,
        "checks": [{"id": "login", "status": "pass"}, {"id": "event:swarm", "status": "pass" if passed else "fail"}],
        "summary": {"pass": 2 if passed else 1, "fail": 0 if passed else 1, "skipped": 0, "not-reached": 0},
        "passed": passed,
    }


class ReportStoreTests(unittest.TestCase):
    def setUp(self):
        self.state = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.state)

    def record(self, r, image=NEW):
        f = self.state / "in.json"
        f.write_text(json.dumps(r))
        return acceptance.main(["record", str(self.state), image, str(f)])

    def test_docker_and_report_times_parse(self):
        self.assertAlmostEqual(acceptance.parse_time(BUILT), acceptance.parse_time("2026-10-26T20:45:52Z") + 0.925034, places=3)
        with self.assertRaises(ValueError):
            acceptance.parse_time("yesterday")

    def test_a_passing_complete_newer_report_opens_the_gate(self):
        self.assertEqual(self.record(report()), 0)
        ok, why = acceptance.gate(self.state, NEW, BUILT)
        self.assertTrue(ok, why)
        stored = list((self.state / "acceptance" / NEW[7:19]).glob("*.json"))
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0].stat().st_mode & 0o777, 0o600)

    def test_no_report_failed_partial_older_or_other_image_keep_it_closed(self):
        self.assertFalse(acceptance.gate(self.state, NEW, BUILT)[0])
        self.assertEqual(self.record(report(passed=False)), 0)
        ok, why = acceptance.gate(self.state, NEW, BUILT)
        self.assertFalse(ok)
        self.assertIn("FAILED", why)

        other = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, other)
        self.state = other
        self.record(report(complete=False))
        self.assertIn("partial", acceptance.gate(other, NEW, BUILT)[1])

        older = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, older)
        self.state = older
        self.record(report(finished=BEFORE))
        self.assertIn("older than the image", acceptance.gate(older, NEW, BUILT)[1])
        self.assertEqual(self.record(report(image=OLD), image=OLD), 0)
        self.assertTrue(acceptance.gate(older, OLD, BUILT)[0])
        self.assertFalse(acceptance.gate(older, NEW, BUILT)[0])  # OLD's pass never opens NEW

    def test_the_newest_report_decides(self):
        self.record(report(run="r1", finished="2026-10-27T03:00:00Z"))
        self.record(report(run="r2", passed=False, finished="2026-10-27T04:00:00Z"))
        self.assertFalse(acceptance.gate(self.state, NEW, BUILT)[0])
        self.record(report(run="r3", finished="2026-10-27T05:00:00Z"))
        self.assertTrue(acceptance.gate(self.state, NEW, BUILT)[0])

    def test_a_report_for_another_image_or_malformed_is_refused(self):
        self.assertEqual(self.record(report(image=OLD)), 2)
        bad = report(); del bad["checks"]
        self.assertEqual(self.record(bad), 2)
        self.assertEqual(self.record({"kind": "something else"}), 2)
        self.assertFalse((self.state / acceptance.INDEX).exists())


STUB = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    state_file = os.environ["STUB_STATE"]
    state = json.load(open(state_file))
    args = sys.argv[1:]
    with open(os.environ["STUB_LOG"], "a") as log:
        log.write(json.dumps({"args": args}) + "\n")
    def save():
        json.dump(state, open(state_file, "w"))
    def resolve(name):
        return name if name.startswith("sha256:") else state["tags"].get(name)
    def fmt():
        return args[args.index("-f") + 1] if "-f" in args else ""
    containers = state["containers"]
    cmd = args[0]
    if cmd == "image" and args[1] == "inspect":
        image = resolve(args[-1])
        if not image:
            sys.exit(1)
        print(state["created"] if "Created" in fmt() else image)
    elif cmd == "inspect":
        c = containers.get(args[-1])
        if c is None:
            sys.exit(1)
        f = fmt()
        if ".State.Running" in f:
            print("true" if c["running"] else "false")
        elif ".State.Status" in f:
            print("running healthy" if c["running"] else "exited ")
        elif ".Config.Labels" in f:
            print(c.get("mode", ""))
        elif ".Image" in f:
            print(c["image"])
    elif cmd == "tag":
        state["tags"][args[2]] = resolve(args[1]); save()
    elif cmd == "exec":
        print("announced", flush=True)
        containers["rs-sdk-server"]["running"] = False; save()
    elif cmd == "run":
        if "bun" in args and "-e" in args:
            print(json.dumps({"xp": "level/7"}))
    elif cmd == "compose":
        if "-p" in args and args[args.index("-p") + 1] == "rs-sdk-world-100":
            if "up" in args:
                containers["rs-sdk-world-100"] = {"running": True, "image": os.environ["WORLD_IMAGE"], "mode": "isolated"}
            elif "down" in args:
                containers.pop("rs-sdk-world-100", None)
            save()
        elif "up" in args:
            containers["rs-sdk-server"] = {"running": True, "image": state["tags"]["computer-setup/rs-sdk:local"]}; save()
    elif cmd == "stop":
        containers[args[-1]]["running"] = False; save()
    elif cmd == "logs":
        print("Server shutdown complete")
''').lstrip()


@unittest.skipUnless(shutil.which("flock") and shutil.which("git"), "needs flock and git (the game host)")
class PromoteGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        game = self.tmp / "linux-game-server"
        shutil.copytree(ROOT / "2004scape", game / "2004scape", ignore=shutil.ignore_patterns(".env", "__pycache__"))
        (game / "rs-sdk").mkdir()
        for path in (ROOT / "rs-sdk").iterdir():
            if path.is_file() and path.name != ".env":
                shutil.copy2(path, game / "rs-sdk" / path.name)
        shutil.copytree(ROOT / "rs-sdk/worlds", game / "rs-sdk/worlds", ignore=shutil.ignore_patterns("__pycache__"))
        self.world_sh = game / "2004scape/world.sh"
        self.data = self.tmp / "data"
        self.data.mkdir()
        self.ntfy = self.tmp / "ntfy.log"
        (game / "2004scape/.env").write_text("NTFY_URL=http://ntfy.invalid\nNTFY_TOPIC=t\n")
        (game / "rs-sdk/.env").write_text(f"RS_SDK_SOURCE_DIR={self.tmp / 'src'}\nRS_SDK_DATA_DIR={self.data}\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text(STUB)
        # ntfy (curl -d BODY URL) and the world's /playercount; ss: nothing listens; tailscale: no serve config.
        (bin_dir / "curl").write_text(textwrap.dedent(f'''\
            #!/usr/bin/env bash
            for a in "$@"; do case "$a" in *playercount) echo '{{"count": 0}}'; exit 0 ;; esac; done
            printf '%s\\n' "$*" >>{self.ntfy}
        '''))
        (bin_dir / "ss").write_text("#!/usr/bin/env bash\n")
        (bin_dir / "tailscale").write_text("#!/usr/bin/env bash\n[[ \"$*\" == *--json* ]] && echo '{}'\nexit 0\n")
        for name in ("docker", "curl", "ss", "tailscale"):
            (bin_dir / name).chmod(0o755)
        self.state = self.tmp / "stub.json"
        self.log = self.tmp / "calls.jsonl"
        self.state.write_text(json.dumps({
            "created": BUILT,
            "tags": {"computer-setup/rs-sdk:local": OLD, "cand": NEW},
            "containers": {"rs-sdk-server": {"running": True, "image": OLD}},
        }))
        self.worlds_state = self.tmp / "state/worlds"
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", HOME=str(self.tmp),
                        XDG_STATE_HOME=str(self.tmp / "state"), WORLDS_STATE_DIR=str(self.worlds_state),
                        WORLD_COUNTDOWN_SECONDS="1", STUB_STATE=str(self.state), STUB_LOG=str(self.log))

    def run_sh(self, *args, **env):
        return subprocess.run(["bash", str(self.world_sh), *args], capture_output=True, text=True,
                              env=dict(self.env, **env), timeout=120)

    def calls(self):
        return [json.loads(line)["args"] for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def final(self):
        return json.loads(self.state.read_text())

    def write_report(self, **kw):
        f = self.tmp / "report.json"
        f.write_text(json.dumps(report(**kw)))
        return f

    def test_promote_without_a_report_changes_nothing(self):
        result = self.run_sh("promote", "cand", "--now", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to promote: no acceptance report", result.stderr)
        self.assertFalse(any(c[0] in ("exec", "tag", "update", "stop") for c in self.calls()))
        self.assertEqual(self.final()["containers"]["rs-sdk-server"]["image"], OLD)
        scheduled = self.run_sh("promote", "cand", "--next-window", "--yes")
        self.assertNotEqual(scheduled.returncode, 0)
        self.assertFalse((self.tmp / "state/computer-setup/2004scape-maintenance/rs-sdk.promote").exists())

    def test_a_failed_newest_report_refuses_and_a_passing_one_promotes(self):
        self.assertEqual(self.run_sh("acceptance", "record", "cand", str(self.write_report(passed=False))).returncode, 0)
        refused = self.run_sh("promote", "cand", "--now", "--yes")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("FAILED", refused.stderr)
        self.assertIn("RS-SDK acceptance FAILED", self.ntfy.read_text())
        rec = self.run_sh("acceptance", "record", "cand", str(self.write_report(run="later", finished="2026-10-27T05:00:00Z")))
        self.assertEqual(rec.returncode, 0, rec.stderr)
        result = self.run_sh("promote", "cand", "--now", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("acceptance: acceptance report later passed", result.stdout)
        self.assertEqual(self.final()["containers"]["rs-sdk-server"]["image"], NEW)

    def test_a_report_older_than_the_image_or_partial_refuses(self):
        self.run_sh("acceptance", "record", "cand", str(self.write_report(finished=BEFORE)))
        self.assertIn("older than the image", self.run_sh("promote", "cand", "--next-window", "--yes").stderr)
        self.run_sh("acceptance", "record", "cand", str(self.write_report(run="p", complete=False, finished="2026-10-27T06:00:00Z")))
        self.assertIn("partial run", self.run_sh("promote", "cand", "--next-window", "--yes").stderr)

    def test_record_refuses_a_report_for_another_image(self):
        result = self.run_sh("acceptance", "record", "cand", str(self.write_report(image=OLD)))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("report refused", result.stderr)

    def test_skip_acceptance_needs_a_reason_and_is_logged_and_notified(self):
        self.assertNotEqual(self.run_sh("promote", "cand", "--next-window", "--yes", "--skip-acceptance").returncode, 0)
        self.assertNotEqual(self.run_sh("promote", "cand", "--next-window", "--yes", "--skip-acceptance", " ").returncode, 0)
        result = self.run_sh("promote", "cand", "--next-window", "--yes", "--skip-acceptance", "hotfix, owner OK")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SKIPPED by --skip-acceptance: hotfix, owner OK", result.stdout)
        skips = (self.worlds_state / "acceptance/skips.log").read_text()
        self.assertIn(NEW, skips)
        self.assertIn("hotfix, owner OK", skips)
        self.assertIn("RS-SDK promotion WITHOUT acceptance", self.ntfy.read_text())
        self.assertEqual((self.tmp / "state/computer-setup/2004scape-maintenance/rs-sdk.promote").read_text().strip(), NEW)

    def test_acceptance_run_brings_the_test_world_up_isolated_records_and_wipes(self):
        runner = self.tmp / "runner.sh"
        runner.write_text(textwrap.dedent(f'''\
            #!/usr/bin/env bash
            echo "runner saw $ACCEPTANCE_IMAGE world $ACCEPTANCE_WORLD up=$(docker inspect -f '{{{{.State.Running}}}}' rs-sdk-world-100)" >>{self.tmp / 'runner.log'}
            cat {self.write_report()}
        '''))
        result = self.run_sh("acceptance", "cand", ACCEPTANCE_RUNNER=f"bash {runner}")
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, out)
        self.assertEqual((self.tmp / "runner.log").read_text().strip(), f"runner saw {NEW} world 100 up=true")
        calls = self.calls()
        up = next(i for i, c in enumerate(calls) if c[0] == "compose" and "rs-sdk-world-100" in c and "up" in c)
        down = next(i for i, c in enumerate(calls) if c[0] == "compose" and "rs-sdk-world-100" in c and "down" in c)
        self.assertLess(up, down)
        self.assertTrue(any("isolated-compose.yml" in a for a in calls[up]))
        self.assertNotIn("rs-sdk-world-100", self.final()["containers"])
        self.assertTrue(any(c[0] == "run" and "rm -rf /dst/data /dst/data.new" in c[-1] for c in calls[down:]))  # --wipe
        self.assertIn("acceptance report recorded: PASSED", out)
        self.assertTrue(acceptance.gate(self.worlds_state, NEW, BUILT)[0])

    def test_acceptance_run_without_a_runner_or_report_fails_and_leaves_the_world_down(self):
        no_runner = self.run_sh("acceptance", "cand")
        self.assertEqual(no_runner.returncode, 2)
        self.assertIn("ACCEPTANCE_RUNNER is not set", no_runner.stderr)
        # The documented flow instead: the bot host's --manage for this exact image id.
        self.assertIn(f"scripts/acceptance.sh --manage {NEW}", no_runner.stderr)
        self.assertIn("Nothing was started", no_runner.stderr)
        self.assertFalse(any(c[0] == "compose" for c in self.calls()))
        broken = self.run_sh("acceptance", "cand", ACCEPTANCE_RUNNER="echo not-json; exit 3")
        self.assertNotEqual(broken.returncode, 0)
        self.assertNotIn("rs-sdk-world-100", self.final()["containers"])
        self.assertIn("did not produce a report", self.ntfy.read_text())


if __name__ == "__main__":
    unittest.main()
