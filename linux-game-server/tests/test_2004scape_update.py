import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCAPE = ROOT / "2004scape"
NODE = shutil.which("node")

REAL_ENUM = """
export const enum FriendsClientOpcodes {
    WORLD_CONNECT,
    FRIENDLIST_ADD,
    FRIENDLIST_DEL,
    IGNORELIST_ADD,
    IGNORELIST_DEL,
    PLAYER_LOGIN,
    PLAYER_LOGOUT,
    PLAYER_CHAT_SETMODE,
    PRIVATE_MESSAGE,
    PUBLIC_CHAT_LOG,
    // temporarily in the friend server (it has a constant connection established)
    RELAY_MUTE,
    RELAY_KICK,
    RELAY_SHUTDOWN,
    RELAY_BROADCAST,
    RELAY_TRACK,
}

export const enum FriendsServerOpcodes {
    UPDATE_FRIENDLIST,
    RELAY_SHUTDOWN,
}
"""

FAKE_WEBSOCKET = """
const fs = require('fs');
globalThis.WebSocket = class {
    constructor(url) {
        fs.appendFileSync(process.env.FAKE_WS_LOG, JSON.stringify({ url }) + '\\n');
        setTimeout(() => this.onopen && this.onopen(), 10);
    }
    send(data) { fs.appendFileSync(process.env.FAKE_WS_LOG, data + '\\n'); }
    close() {}
};
"""


@unittest.skipUnless(NODE, "node is required to run the countdown helper")
class CountdownHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.engine = self.tmp / "engine"
        (self.engine / "src/server/friend").mkdir(parents=True)
        self.write_enum(REAL_ENUM)
        (self.tmp / "fake.js").write_text(FAKE_WEBSOCKET)
        self.log = self.tmp / "ws.log"

    def write_enum(self, text):
        (self.engine / "src/server/friend/FriendServer.ts").write_text(text)

    def run_helper(self, seconds_ahead=12, run_for=0.6, **env):
        deadline = int(time.time() * 1000) + seconds_ahead * 1000
        full_env = {**os.environ, "COUNTDOWN_ENGINE_DIR": str(self.engine), "FAKE_WS_LOG": str(self.log),
                    "COUNTDOWN_DEADLINE_MS": str(deadline), **env}
        proc = subprocess.Popen([str(NODE), "--require", str(self.tmp / "fake.js"), str(SCAPE / "countdown.js")],
                                env=full_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            out, err = proc.communicate(timeout=run_for)
        except subprocess.TimeoutExpired:
            proc.terminate()
            out, err = proc.communicate()
        sent = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return proc.returncode, out, err, sent

    def test_announces_with_opcodes_resolved_by_name(self):
        _, out, err, sent = self.run_helper(COUNTDOWN_TICK_MS="600")
        self.assertIn("announced", out, err)
        self.assertEqual(sent[0], {"url": "ws://127.0.0.1:45099"})
        shutdown, broadcast = sent[1], sent[2]
        self.assertEqual(shutdown["type"], 12)
        self.assertEqual(shutdown["nodeId"], 10)
        self.assertIn(shutdown["duration"], (19, 20))
        self.assertEqual(broadcast["type"], 13)
        self.assertIn("backup and update in 12 seconds", broadcast["broadcast"])

    def test_reordered_enum_follows_the_source(self):
        self.write_enum("export const enum FriendsClientOpcodes { WORLD_CONNECT, RELAY_BROADCAST, /* x, y */ RELAY_SHUTDOWN }")
        _, out, err, sent = self.run_helper(COUNTDOWN_TICK_MS="600")
        self.assertIn("announced", out, err)
        self.assertEqual([m["type"] for m in sent[1:3]], [2, 1])

    def test_explicit_enum_values_fail_closed(self):
        self.write_enum("export const enum FriendsClientOpcodes { WORLD_CONNECT = 0, RELAY_SHUTDOWN = 12, RELAY_BROADCAST }")
        rc, out, err, sent = self.run_helper()
        self.assertEqual(rc, 2, err)
        self.assertNotIn("announced", out)
        self.assertEqual(sent, [])

    def test_missing_opcode_fails_closed(self):
        self.write_enum("export const enum FriendsClientOpcodes { WORLD_CONNECT, RELAY_SHUTDOWN }")
        rc, _, err, _ = self.run_helper()
        self.assertEqual(rc, 2)
        self.assertIn("RELAY_BROADCAST not found", err)

    def test_settings_come_from_env_then_engine_dotenv(self):
        (self.engine / ".env").write_text("NODE_ID=7\nexport FRIEND_PORT='4321'\n")
        _, out, _, sent = self.run_helper(COUNTDOWN_TICK_MS="600")
        self.assertEqual(sent[0]["url"], "ws://127.0.0.1:4321")
        self.assertEqual(sent[1]["nodeId"], 7)
        self.log.unlink()
        _, out, _, sent = self.run_helper(COUNTDOWN_TICK_MS="600", FRIEND_PORT="5555")
        self.assertEqual(sent[0]["url"], "ws://127.0.0.1:5555")

    def test_fast_engine_keeps_display_ticks_and_resyncs(self):
        # RS-SDK ticks at 400 ms but the client counts 600 ms ticks: the timer is
        # sent in display ticks and resent every 2 s so the engine stays in step.
        _, out, err, sent = self.run_helper(run_for=2.6, NODE_TICKRATE="400")
        shutdowns = [m for m in sent[1:] if m["type"] == 12]
        self.assertIn(shutdowns[0]["duration"], (19, 20), err)
        self.assertEqual(len(shutdowns), 2, sent)

    def test_slow_engine_uses_engine_ticks(self):
        _, out, err, sent = self.run_helper(COUNTDOWN_TICK_MS="1200")
        self.assertIn(sent[1]["duration"], (10, 11), err)

    def test_minutes_wording(self):
        _, _, _, sent = self.run_helper(seconds_ahead=125, COUNTDOWN_TICK_MS="600")
        self.assertIn("in 2 minutes.", sent[2]["broadcast"])

    def test_deadline_too_close_is_refused(self):
        rc, out, err, sent = self.run_helper(seconds_ahead=3)
        self.assertEqual(rc, 2)
        self.assertEqual(sent, [])


DOCKER_STUB = r"""#!/usr/bin/env bash
S="$STUB_STATE"
printf 'docker %s\n' "$(printf '%s ' "$@" | cut -c1-1000)" >>"$S/calls"
service_container() { case "$1" in lostcity) echo lostcity ;; rs-sdk) echo rs-sdk-server ;; esac; }
case "$1" in
  inspect)
    fmt="$3"; c="$4"
    running="$(cat "$S/running.$c" 2>/dev/null || echo false)"
    if [[ "$fmt" == *Health* ]]; then
      ups="$(cat "$S/ups.$c" 2>/dev/null || echo 0)"
      healthy_from="$(cat "$S/healthy-from-up.$c" 2>/dev/null || echo 1)"
      if [[ "$running" == true ]] && (( ups >= healthy_from )); then echo "running healthy"; else echo "running starting"; fi
    elif [[ "$fmt" == *ExitCode* ]]; then
      cat "$S/exit.$c" 2>/dev/null || echo "false 0 false"
    else
      echo "$running"
    fi ;;
  update) : ;;
  exec)
    c=""; for a in "$@"; do [[ "$a" == bun ]] && break; c="$a"; done
    if [[ -e "$S/announce-fail.$c" ]]; then echo "countdown: cannot reach the friend server"; exit 3; fi
    echo announced
    echo false >"$S/running.$c" ;;
  logs) echo "Server shutdown complete" ;;
  image|tag|rm) : ;;
  run) : ;;
  compose)
    dir=""; prev=""; for a in "$@"; do [[ "$prev" == --project-directory ]] && dir="$a"; prev="$a"; done
    c="$(service_container "$(basename "$dir")")"
    if [[ " $* " == *" up "* ]]; then
      echo true >"$S/running.$c"
      echo $(( $(cat "$S/ups.$c" 2>/dev/null || echo 0) + 1 )) >"$S/ups.$c"
    elif [[ " $* " == *" stop "* ]]; then
      echo false >"$S/running.$c"
    elif [[ " $* " == *" run "* ]]; then
      if [[ "$*" == *sqlite:migrate* ]]; then
        echo migrated-db >"$MIGRATE_DB"
        echo partial >"$MIGRATE_DB-journal"
        exit "$(cat "$S/migrate-rc" 2>/dev/null || echo 0)"
      fi
    elif [[ " $* " == *" build "* ]]; then
      exit "$(cat "$S/build-rc" 2>/dev/null || echo 0)"
    fi ;;
  *) exit 1 ;;
esac
"""

GIT_STUB = r"""#!/usr/bin/env bash
S="$STUB_STATE"
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) shift 2 ;;
    -C) repo="$2"; shift 2 ;;
    *) break ;;
  esac
done
printf 'git %s %s\n' "$repo" "$*" >>"$S/calls"
d="$S/git/$(printf '%s' "$repo" | tr '/' '_')"
case "$1" in
  symbolic-ref) cat "$d/branch" ;;
  status) cat "$d/dirty" 2>/dev/null || true ;;
  fetch) exit "$(cat "$d/fetch-rc" 2>/dev/null || echo 0)" ;;
  rev-parse) if [[ "$2" == HEAD ]]; then cat "$d/head"; else cat "$d/upstream"; fi ;;
  merge-base) exit "$(cat "$d/ancestor-rc" 2>/dev/null || echo 0)" ;;
  merge) echo "${*: -1}" >"$d/head" ;;
  reset) echo "${*: -1}" >"$d/head" ;;
  *) exit 1 ;;
esac
"""

SYSTEMCTL_STUB = r"""#!/usr/bin/env bash
S="$STUB_STATE"
printf 'systemctl %s\n' "$*" >>"$S/calls"
case "$*" in
  "show game-backup.service -p LoadState --value") echo loaded ;;
  "show game-backup.service -p Environment --value") cat "$S/backup-env" ;;
  "--no-ask-password restart --wait game-backup.service") exit "$(cat "$S/backup-rc" 2>/dev/null || echo 0)" ;;
  *) exit 1 ;;
esac
"""

CURL_STUB = r"""#!/usr/bin/env bash
title=""; body=""; prev=""
for a in "$@"; do
  [[ "$prev" == -H && "$a" == Title:* ]] && title="${a#Title: }"
  [[ "$prev" == -d ]] && body="$a"
  prev="$a"
done
printf '%s | %s\n' "$title" "$body" >>"$STUB_STATE/notify"
"""


class UpdateFlowTests(unittest.TestCase):
    OLD = "a" * 40
    NEW = "b" * 40

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.state = self.tmp / "stub"
        (self.state / "git").mkdir(parents=True)
        game = self.tmp / "linux-game-server"
        (game / "2004scape").mkdir(parents=True)
        for name in ("update.sh", "countdown.js"):
            shutil.copy(SCAPE / name, game / "2004scape" / name)
        self.script = game / "2004scape" / "update.sh"
        self.runtime = self.tmp / "games/lost-city/runtime"
        self.rs_src = self.tmp / "rs-sdk-src"
        self.rs_data = self.tmp / "games/rs-sdk/data"
        for repo in self.lostcity_repos():
            repo.mkdir(parents=True)
        self.rs_src.mkdir()
        self.rs_data.mkdir(parents=True)
        (self.runtime / "engine/db.sqlite").write_text("old-db")
        (game / "lostcity").mkdir()
        (game / "rs-sdk").mkdir()
        (game / "lostcity/.env").write_text(f"LOSTCITY_RUNTIME_DIR={self.runtime}\nLOSTCITY_REVISION=254\n")
        (game / "rs-sdk/.env").write_text(f"RS_SDK_SOURCE_DIR={self.rs_src}\nRS_SDK_DATA_DIR={self.rs_data}\n")
        self.scape_env = game / "2004scape/.env"
        self.scape_env.write_text("UPDATE_COUNTDOWN_MINUTES=1\nNTFY_URL=https://ntfy.example\nNTFY_TOPIC=t\n")
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("docker", DOCKER_STUB), ("git", GIT_STUB), ("systemctl", SYSTEMCTL_STUB),
                           ("curl", CURL_STUB), ("sleep", "#!/usr/bin/env bash\n"),
                           ("flock", "#!/usr/bin/env bash\n")):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "STUB_STATE": str(self.state),
                    "XDG_STATE_HOME": str(self.tmp / "xdg"),
                    "MIGRATE_DB": str(self.runtime / "engine/db.sqlite")}
        self.set_backup_env(lostcity=True, rs_sdk=True)
        for repo in self.lostcity_repos():
            self.set_repo(repo, "254", self.OLD, self.OLD)
        self.set_repo(self.rs_src, "main", self.OLD, self.OLD)

    def lostcity_repos(self):
        return [self.runtime / "engine", self.runtime / "content", self.runtime / "webclient"]

    def repo_dir(self, repo):
        return self.state / "git" / str(repo).replace("/", "_")

    def set_repo(self, repo, branch, head, upstream):
        d = self.repo_dir(repo)
        d.mkdir(exist_ok=True)
        (d / "branch").write_text(branch + "\n")
        (d / "head").write_text(head + "\n")
        (d / "upstream").write_text(upstream + "\n")

    def head(self, repo):
        return (self.repo_dir(repo) / "head").read_text().strip()

    def set_backup_env(self, lostcity, rs_sdk):
        parts = ["BACKUP_HOST_DIR=/x"]
        if lostcity:
            parts.append(f"BACKUP_LOSTCITY_RUNTIME_DIR={self.runtime}")
        if rs_sdk:
            parts.append(f"BACKUP_RS_SDK_DATA_DIR={self.rs_data}")
        (self.state / "backup-env").write_text(" ".join(parts) + "\n")

    def running(self, *containers):
        for c in containers:
            (self.state / f"running.{c}").write_text("true\n")

    def stub(self, name, value):
        (self.state / name).write_text(f"{value}\n")

    def run_update(self, *args):
        (self.state / "calls").write_text("")
        result = subprocess.run(["bash", str(self.script), *args], env=self.env, capture_output=True, text=True)
        calls = (self.state / "calls").read_text().splitlines()
        notify = (self.state / "notify").read_text() if (self.state / "notify").exists() else ""
        return result, calls, notify

    def index(self, calls, needle):
        return next(i for i, line in enumerate(calls) if needle in line)

    def assert_no_call(self, calls, needle):
        self.assertFalse(any(needle in line for line in calls), f"unexpected {needle!r} in {calls}")

    def test_stopped_stacks_are_left_alone(self):
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not running; left alone", result.stdout)
        self.assert_no_call(calls, "git ")
        self.assert_no_call(calls, "docker exec")

    def test_up_to_date_does_nothing(self):
        self.running("lostcity", "rs-sdk-server")
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("up to date"), 2)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "restart --wait")

    def test_check_only_reports(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "content", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_update("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lostcity: update available (content@bbbbbbbbbbbb)", result.stdout)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "merge --ff-only")

    def test_full_update_order(self):
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        no_restart = self.index(calls, "docker update --restart=no lostcity")
        announce = self.index(calls, "docker exec -e COUNTDOWN_DEADLINE_MS=")
        backup = self.index(calls, "--no-ask-password restart --wait game-backup.service")
        merge = self.index(calls, f"git {self.runtime}/engine merge --ff-only --quiet {self.NEW}")
        rebuild = self.index(calls, "run --rm --no-deps -T --name lostcity-update lostcity bash -c cd engine && bun install && bun run sqlite:migrate && bun run build")
        up = self.index(calls, "up -d --no-build --force-recreate lostcity")
        self.assertLess(no_restart, announce)
        self.assertLess(announce, backup)
        self.assertLess(backup, merge)
        self.assertLess(merge, rebuild)
        self.assertLess(rebuild, up)
        tag = self.index(calls, "docker tag computer-setup/rs-sdk:local computer-setup/rs-sdk:rollback")
        snapshot = self.index(calls, "docker run --rm --network none --entrypoint sh")
        rs_merge = self.index(calls, f"git {self.rs_src} merge --ff-only --quiet {self.NEW}")
        self.assertLess(backup, tag)
        self.assertLess(tag, snapshot)
        self.assertLess(snapshot, rs_merge)
        build = next(i for i, line in enumerate(calls) if i > rs_merge and " build rs-sdk" in line)
        self.assertLess(build, self.index(calls, "up -d --no-build --force-recreate rs-sdk"))
        self.assert_no_call(calls, f"git {self.runtime}/content merge")
        self.assertEqual(self.head(self.runtime / "engine"), self.NEW)
        self.assertEqual((self.runtime.parent / "runtime.pre-update/db.sqlite").read_text(), "old-db")
        self.assertIn("2004Scape updated", notify)
        self.assert_no_call(calls, "reset --hard")

    def test_backup_failure_restarts_without_updating(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("backup-rc", 1)
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assert_no_call(calls, "merge --ff-only")
        backup = self.index(calls, "restart --wait game-backup.service")
        self.assertTrue(any("up -d --no-build --force-recreate" in line for line in calls[backup:]))
        self.assertEqual(self.head(self.runtime / "engine"), self.OLD)
        self.assertIn("2004Scape update aborted", notify)

    def test_failed_announcement_cancels_before_any_shutdown(self):
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        (self.state / "announce-fail.rs-sdk-server").touch()
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("rs-sdk: could not announce the countdown", result.stdout + result.stderr)
        self.assert_no_call(calls, "restart --wait")
        self.assert_no_call(calls, "merge --ff-only")
        self.assertTrue(any("docker update --restart=unless-stopped rs-sdk-server" in line for line in calls))
        self.assertIn("aborted", notify)

    def test_unclean_shutdown_does_not_update(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("exit.lostcity", "false 137 false")
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not shut down cleanly", result.stdout + result.stderr)
        self.assert_no_call(calls, "restart --wait")
        self.assert_no_call(calls, "merge --ff-only")

    def test_unhealthy_update_rolls_back_and_is_not_retried(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("healthy-from-up.lostcity", 2)
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        # The migration rewrote the database; the rollback put the pre-update copy back.
        self.assertEqual((self.runtime / "engine/db.sqlite").read_text(), "old-db")
        reset = self.index(calls, f"git {self.runtime}/engine reset --hard --quiet {self.OLD}")
        self.assertGreater(reset, self.index(calls, f"merge --ff-only --quiet {self.NEW}"))
        self.assertTrue(any("bun install && bun run build" in line for line in calls[reset:]))
        self.assertEqual(self.head(self.runtime / "engine"), self.OLD)
        self.assertIn("rolled back", notify)
        failed = Path(self.env["XDG_STATE_HOME"]) / "computer-setup/2004scape-update/lostcity.failed"
        self.assertEqual(failed.read_text().strip(), f"engine@{self.NEW[:12]}")

        self.running("lostcity")
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("failed before", result.stdout)
        self.assert_no_call(calls, "docker exec")

    def test_failed_migration_rolls_back_database_and_journal(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("migrate-rc", 1)
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.runtime / "engine/db.sqlite").read_text(), "old-db")
        self.assertFalse((self.runtime / "engine/db.sqlite-journal").exists())
        # Only the rollback starts the stack: the failed update never did.
        self.assertEqual(sum("up -d --no-build --force-recreate lostcity" in line for line in calls), 1)
        self.assertIn("rolled back", notify)

    def test_stale_journal_is_dropped_before_the_restore(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("healthy-from-up.lostcity", 2)
        journal = self.runtime / "engine/db.sqlite-journal"

        result, _, _ = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(journal.exists())

    def test_failed_rollback_reports_the_stack_down(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("healthy-from-up.lostcity", 99)
        result, _, notify = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("rollback failed; the stack is down", result.stdout)
        self.assertIn("server DOWN", notify)

    def test_refuses_when_backup_does_not_cover_the_stack(self):
        self.running("rs-sdk-server")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        self.set_backup_env(lostcity=True, rs_sdk=False)
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not cover rs-sdk", result.stdout + result.stderr)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "docker exec")

    def test_diverged_or_dirty_checkouts_are_skipped(self):
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        (self.repo_dir(self.runtime / "engine") / "ancestor-rc").write_text("1\n")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        (self.repo_dir(self.rs_src) / "dirty").write_text(" M server/x.ts\n")
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has diverged", result.stdout)
        self.assertIn("has local changes", result.stdout)
        self.assert_no_call(calls, "docker exec")

    def test_wrong_branch_is_skipped(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "main", self.OLD, self.NEW)
        result, calls, _ = self.run_update()
        self.assertEqual(result.returncode, 0)
        self.assertIn("not on branch 254", result.stdout)
        self.assert_no_call(calls, "docker exec")

    def test_auto_update_off_notifies_once(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.scape_env.write_text(self.scape_env.read_text() + "AUTO_UPDATE=false\n")
        result, calls, notify = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_call(calls, "docker exec")
        self.assertEqual(notify.count("2004Scape update available"), 1)
        self.run_update()
        notify = (self.state / "notify").read_text()
        self.assertEqual(notify.count("2004Scape update available"), 1)

    def test_rejects_bad_countdown_and_paths(self):
        self.scape_env.write_text("UPDATE_COUNTDOWN_MINUTES=0\n")
        result, _, _ = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("UPDATE_COUNTDOWN_MINUTES", result.stdout + result.stderr)
        self.scape_env.write_text("")
        (self.tmp / "linux-game-server/rs-sdk/.env").write_text("RS_SDK_SOURCE_DIR=relative\nRS_SDK_DATA_DIR=/x/y\n")
        result, _, _ = self.run_update()
        self.assertEqual(result.returncode, 1)
        self.assertIn("unsupported path", result.stdout + result.stderr)


class UnitTemplateTests(unittest.TestCase):
    def test_service_runs_unprivileged_with_room_for_the_whole_run(self):
        service = (SCAPE / "2004scape-update.service.template").read_text()
        self.assertIn("User=@USER@", service)
        self.assertIn("ExecStart=/usr/bin/env bash @UPDATE_SCRIPT@", service)
        self.assertIn("TimeoutStartSec=6h", service)
        self.assertNotIn("ExecStart=+", service)
        timer = (SCAPE / "2004scape-update.timer").read_text()
        self.assertIn("OnCalendar=*-*-* 04:30:00", timer)
        self.assertNotIn("Persistent=true", timer)

    def test_polkit_rule_allows_only_restarting_the_game_backup(self):
        rule = (SCAPE / "2004scape-update.rules.template").read_text()
        self.assertIn('subject.user == "@USER@"', rule)
        self.assertIn('action.lookup("unit") == "game-backup.service"', rule)
        self.assertIn('action.lookup("verb") == "restart"', rule)
        self.assertEqual(rule.count("polkit.Result.YES"), 1)

    def test_rs_sdk_tick_and_node_are_pinned_for_the_countdown(self):
        compose = (ROOT / "rs-sdk/docker-compose.yml").read_text()
        self.assertIn('NODE_TICKRATE: "400"', compose)
        self.assertIn('NODE_ID: "10"', compose)
        self.assertIn('FRIEND_PORT: "45109"', compose)

    def test_installer_dry_run_renders_without_root(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        for name, body in (
            ("id", '#!/usr/bin/env bash\ncase "$1" in -u) echo 1000;; -gn) echo tester;; -nG) echo "tester docker";; -un) echo tester;; *) echo 1000;; esac\n'),
            ("systemctl", "#!/usr/bin/env bash\necho loaded\n"),
            ("systemd-analyze", "#!/usr/bin/env bash\n"),
        ):
            (tmp / name).write_text(body)
            (tmp / name).chmod(0o755)
        env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "SERVICE_USER": "tester"}
        result = subprocess.run(["bash", str(SCAPE / "install-update-timer.sh"), "--dry-run"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[dry-run] systemctl enable --now 2004scape-update.timer", result.stdout)
        self.assertIn("User=tester", result.stdout)


if __name__ == "__main__":
    unittest.main()
