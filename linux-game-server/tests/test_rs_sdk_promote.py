"""world.sh promote --now hooks and candidate build --source-ref, against a stub docker.

The stub keeps a tiny model of the host (tags, rs-sdk-server's image and state) in a
JSON file and logs every call, so the tests check what world.sh asks docker to do and
in which order, without a daemon. Needs GNU date and flock (the game host has both).
"""
from pathlib import Path
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
FIX_IMAGE = "sha256:" + "f" * 64

STUB = textwrap.dedent(r'''
    #!/usr/bin/env python3
    import json, os, sys
    state_file = os.environ["STUB_STATE"]
    state = json.load(open(state_file))
    args = sys.argv[1:]
    with open(os.environ["STUB_LOG"], "a") as log:
        log.write(json.dumps({"args": args, "running": state["running"],
                              "env": {k: os.environ.get(k) for k in ("CANDIDATE_UPSTREAM", "CANDIDATE_TAG")}}) + "\n")
    def save():
        json.dump(state, open(state_file, "w"))
    def resolve(name):
        return name if name.startswith("sha256:") else state["tags"].get(name)
    def fmt():
        return args[args.index("-f") + 1] if "-f" in args else ""
    cmd = args[0]
    if cmd == "image" and args[1] == "inspect":
        image = resolve(args[-1])
        if not image:
            sys.exit(1)
        print(image)
    elif cmd == "inspect":
        if args[-1] != "rs-sdk-server":
            sys.exit(1)
        f = fmt()
        if ".State.Running" in f:
            print("true" if state["running"] else "false")
        elif ".State.Status" in f:
            print("running healthy" if state["running"] else "exited ")
        elif ".Image" in f:
            print(state["image"])
    elif cmd == "tag":
        state["tags"][args[2]] = resolve(args[1]); save()
    elif cmd == "exec":
        print("announced", flush=True)
        state["running"] = False; save()
    elif cmd == "run":
        if "bun" in args and "-e" in args:
            print(json.dumps({"xp": "level/7"}))
        elif os.environ.get("STUB_FIX_IMAGE") in args:
            sys.exit(int(os.environ.get("STUB_FIX_RC", "0")))
    elif cmd == "compose":
        if "up" in args:
            state["running"] = True
            state["image"] = state["tags"]["computer-setup/rs-sdk:local"]
            save()
            if state["image"] in os.environ.get("STUB_UNHEALTHY", ""):
                state["running"] = False; save()
        elif "build" in args:
            state["tags"][os.environ["CANDIDATE_TAG"]] = "sha256:" + "c" * 64; save()
    elif cmd == "stop":
        state["running"] = False; save()
''').lstrip()


@unittest.skipUnless(shutil.which("flock") and shutil.which("git"), "needs flock and git (the game host)")
class PromoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        game = self.tmp / "linux-game-server"
        shutil.copytree(ROOT / "2004scape", game / "2004scape")
        (game / "rs-sdk").mkdir()
        for path in (ROOT / "rs-sdk").iterdir():
            if path.is_file():
                shutil.copy2(path, game / "rs-sdk" / path.name)
        shutil.copytree(ROOT / "rs-sdk/worlds", game / "rs-sdk/worlds")
        self.world_sh = game / "2004scape/world.sh"
        self.data = self.tmp / "data"
        self.data.mkdir()
        self.make_db(self.data / "db.sqlite")
        self.source = self.tmp / "rs-sdk-src"
        (game / "2004scape/.env").write_text("NTFY_URL=\n")
        (game / "rs-sdk/.env").write_text(f"RS_SDK_SOURCE_DIR={self.source}\nRS_SDK_DATA_DIR={self.data}\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text(STUB)
        (bin_dir / "docker").chmod(0o755)
        self.state = self.tmp / "stub.json"
        self.log = self.tmp / "calls.jsonl"
        self.state.write_text(json.dumps({
            "running": True, "image": OLD,
            "tags": {"computer-setup/rs-sdk:local": OLD, "cand": NEW, "python:3.14-alpine": FIX_IMAGE},
        }))
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", HOME=str(self.tmp),
                        XDG_STATE_HOME=str(self.tmp / "state"), WORLDS_STATE_DIR=str(self.tmp / "state/worlds"),
                        WORLD_COUNTDOWN_SECONDS="1", STUB_STATE=str(self.state), STUB_LOG=str(self.log),
                        STUB_FIX_IMAGE="python:3.14-alpine")

    @staticmethod
    def make_db(path):
        con = sqlite3.connect(path)
        con.executescript("""
            CREATE TABLE account (id INTEGER PRIMARY KEY, username TEXT);
            CREATE TABLE hiscore (account_id INT, profile TEXT, type INT, level INT, value INT, playtime INT);
            CREATE TABLE hiscore_large (account_id INT, profile TEXT, type INT, level INT, value INT, playtime INT);
            INSERT INTO account VALUES (1, 'tester');
            INSERT INTO hiscore VALUES (1, 'main', 10, 45, 227740, 0);
        """)
        con.commit()
        con.close()

    def run_sh(self, *args, **env):
        return subprocess.run(["bash", str(self.world_sh), *args], capture_output=True, text=True,
                              env=dict(self.env, **env), timeout=120)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def final(self):
        return json.loads(self.state.read_text())

    def pin(self):
        return (self.tmp / "state/computer-setup/2004scape-maintenance/rs-sdk.image").read_text().strip()

    def index(self, calls, pred):
        return next(i for i, c in enumerate(calls) if pred(c["args"]))

    def test_pre_start_runs_once_with_the_engine_stopped_between_the_copy_and_the_start(self):
        marker = self.tmp / "marker"
        result = self.run_sh("promote", "cand", "--now", "--yes", "--pre-start",
                             f'docker hookmark; echo "$RS_SDK_DATA_DIR $(docker inspect -f "{{{{.State.Running}}}}" rs-sdk-server)" >>{marker}')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(marker.read_text(), f"{self.data} false\n")
        calls = self.calls()
        copy = self.index(calls, lambda a: a[0] == "run" and any("pre-promote" in x for x in a))
        hook = self.index(calls, lambda a: a == ["hookmark"])
        self.assertEqual(sum(c["args"] == ["hookmark"] for c in calls), 1)
        up = self.index(calls, lambda a: a[0] == "compose" and "up" in a)
        self.assertLess(copy, hook)
        self.assertLess(hook, up)
        self.assertEqual(self.final()["image"], NEW)
        self.assertEqual(self.final()["tags"]["computer-setup/rs-sdk:local"], NEW)
        self.assertEqual(self.pin(), NEW)

    def test_a_failed_pre_start_restores_the_data_and_the_previous_image(self):
        result = self.run_sh("promote", "cand", "--now", "--yes", "--pre-start", "exit 3")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("the pre-start step failed; rolling back", result.stdout + result.stderr)
        calls = self.calls()
        self.assertTrue(any(c["args"][0] == "run" and any("pre-promote/." in x for x in c["args"]) for c in calls))
        ups = [c for c in calls if c["args"][0] == "compose" and "up" in c["args"]]
        self.assertEqual(len(ups), 1)  # only the restart on the previous image
        self.assertEqual(self.final()["image"], OLD)
        self.assertTrue(self.final()["running"])
        self.assertEqual(self.final()["tags"]["computer-setup/rs-sdk:local"], OLD)
        self.assertEqual(self.pin(), OLD)

    def test_fix_hiscores_dry_runs_first_then_applies_as_root_in_a_container_while_stopped(self):
        result = self.run_sh("promote", "cand", "--now", "--yes", "--fix-hiscores")
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, out)
        self.assertIn("off_curve_rows=1", out)  # the dry run on the live file, before the countdown
        calls = self.calls()
        fix = [c for c in calls if c["args"][0] == "run" and "python:3.14-alpine" in c["args"]]
        self.assertEqual(len(fix), 1)
        args = fix[0]["args"]
        self.assertFalse(fix[0]["running"])
        self.assertIn("--network", args)
        self.assertIn(f"{self.data}:/data", args)
        self.assertTrue(any(a.endswith("fix-hiscore-levels.py:/fix-hiscore-levels.py:ro") for a in args))
        self.assertIn("--apply", args[-1])
        countdown = self.index(calls, lambda a: a[0] == "exec")
        self.assertLess(countdown, calls.index(fix[0]))
        self.assertLess(calls.index(fix[0]), self.index(calls, lambda a: a[0] == "compose" and "up" in a))
        self.assertEqual(self.final()["image"], NEW)
        # The dry run changed nothing.
        con = sqlite3.connect(self.data / "db.sqlite")
        self.assertEqual(con.execute("SELECT level FROM hiscore").fetchone()[0], 45)
        con.close()

    def test_fix_hiscores_fails_before_the_countdown_without_its_image(self):
        state = self.final()
        del state["tags"]["python:3.14-alpine"]
        self.state.write_text(json.dumps(state))
        result = self.run_sh("promote", "cand", "--now", "--yes", "--fix-hiscores")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c["args"][0] in ("exec", "update", "tag") for c in self.calls()))
        self.assertTrue(self.final()["running"])

    def test_hooks_need_now(self):
        result = self.run_sh("promote", "cand", "--next-window", "--yes", "--fix-hiscores")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("only with --now", result.stderr)

    def test_source_ref_builds_that_commit_without_fetching_or_moving_the_checkout(self):
        git = ["git", "-C", str(self.source), "-c", "user.email=t@example.invalid", "-c", "user.name=t"]
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "one"], check=True)
        first = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "two"], check=True)
        head = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        # No remote: a fetch would fail the build.
        result = self.run_sh("candidate", "build", "--source-ref", first[:9])
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        build = [c for c in self.calls() if c["args"][0] == "compose" and "build" in c["args"]]
        self.assertEqual(build[0]["env"]["CANDIDATE_UPSTREAM"], first)
        self.assertTrue(build[0]["env"]["CANDIDATE_TAG"].startswith(f"computer-setup/rs-sdk:candidate-{first[:12]}-"))
        self.assertEqual(subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(), head)
        self.assertEqual(subprocess.run([*git, "worktree", "list"], capture_output=True, text=True).stdout.count("\n"), 1)
        bad = self.run_sh("candidate", "build", "--source-ref", "no-such-commit")
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("is not a commit", bad.stderr)


if __name__ == "__main__":
    unittest.main()
