import datetime
import json
import os
import re
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
        _, out, err, sent = self.run_helper(COUNTDOWN_TICK_MS="600", COUNTDOWN_WITH_UPDATE="1")
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

    def test_restart_without_update_says_so(self):
        _, _, _, sent = self.run_helper(COUNTDOWN_TICK_MS="600")
        self.assertIn("for a backup and restart in 12 seconds", sent[2]["broadcast"])

    def test_checkpoints_broadcast_the_time_left(self):
        _, _, err, sent = self.run_helper(run_for=2.8, COUNTDOWN_TICK_MS="600")
        broadcasts = [m["broadcast"] for m in sent[1:] if m["type"] == 13]
        self.assertEqual(len(broadcasts), 2, err)
        self.assertIn("in 10 seconds.", broadcasts[1])

    def test_minutes_wording(self):
        _, _, _, sent = self.run_helper(seconds_ahead=125, COUNTDOWN_TICK_MS="600")
        self.assertIn("in 2 minutes.", sent[2]["broadcast"])

    def test_deadline_too_close_is_refused(self):
        rc, out, err, sent = self.run_helper(seconds_ahead=3)
        self.assertEqual(rc, 2)
        self.assertEqual(sent, [])


DOCKER_STUB = r"""#!/usr/bin/env bash
S="$STUB_STATE"
printf 'docker %s\n' "$(printf '%s ' "$@" | tr '\n' ' ' | cut -c1-1000)" >>"$S/calls"
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
    elif [[ "$fmt" == *.Image* ]]; then
      echo "sha256:running-$c"
    else
      echo "$running"
    fi ;;
  update) : ;;
  exec)
    c=""; for a in "$@"; do [[ "$a" == bun ]] && break; c="$a"; done
    if [[ -e "$S/announce-fail.$c" ]]; then echo "countdown: cannot reach the friend server"; exit 3; fi
    echo announced
    # The engine shuts itself down at the deadline, unless it never got the countdown.
    [[ -e "$S/no-shutdown.$c" ]] || echo false >"$S/running.$c" ;;
  logs) echo "Server shutdown complete" ;;
  image|tag|rm) : ;;
  run)
    # rs_sdk_data_op: run its script against the real directory behind /parent.
    parent=""; name=""; script=""; prev=""
    for a in "$@"; do
      case "$prev" in
        -v) parent="${a%%:*}" ;;
        -e) [[ "$a" == NAME=* ]] && name="${a#NAME=}" ;;
        -c) script="$a" ;;
      esac
      prev="$a"
    done
    [[ ! -e "$S/run-rc" ]] || exit "$(cat "$S/run-rc")"
    [[ -z "$script" ]] || NAME="$name" sh -c "${script//\/parent/$parent}" ;;
  compose)
    dir=""; prev=""; for a in "$@"; do [[ "$prev" == --project-directory ]] && dir="$a"; prev="$a"; done
    c="$(service_container "$(basename "$dir")")"
    if [[ " $* " == *" up "* ]]; then
      echo true >"$S/running.$c"
      echo $(( $(cat "$S/ups.$c" 2>/dev/null || echo 0) + 1 )) >"$S/ups.$c"
    elif [[ " $* " == *" stop "* ]]; then
      echo false >"$S/running.$c"
    elif [[ " $* " == *" run "* ]]; then
      if [[ -e "$S/kill-on-rebuild" ]]; then rm "$S/kill-on-rebuild"; kill -TERM "$PPID"; exit 1; fi
      if [[ "$*" == *sqlite:migrate* ]]; then
        echo migrated-db >"$MIGRATE_DB"
        echo partial >"$MIGRATE_DB-journal"
        # The new code's saves, which a rollback must not keep.
        echo new-save >"$PLAYERS_DIR/main/alice.sav"
        echo new-save >"$PLAYERS_DIR/main/new.sav"
        exit "$(cat "$S/migrate-rc" 2>/dev/null || echo 0)"
      fi
    elif [[ " $* " == *" build "* ]]; then
      echo new-rs-data >"$RS_DATA/db.sqlite"
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
stamp() { date -d "@$1" '+%a %Y-%m-%d %H:%M:%S %Z'; }
case "$*" in
  "show game-backup.timer -p NextElapseUSecRealtime --value") stamp "$(cat "$S/next-epoch")" ;;
  "show game-backup.service -p Environment --value") cat "$S/backup-env" ;;
  "show game-backup-restore-check.service -p ExecStart --value") cat "$S/verify-exec" ;;
  "show "*" -p LoadState --value") if [[ -e "$S/missing.$2" ]]; then echo not-found; else echo loaded; fi ;;
  "show "*" -p ActiveState --value") cat "$S/active.$2" 2>/dev/null || echo inactive ;;
  "show "*" -p Result --value") cat "$S/result.$2" 2>/dev/null || echo success ;;
  "show "*" -p ExecMainStartTimestamp --value") cat "$S/started.$2" 2>/dev/null || echo n/a ;;
  "--no-ask-password start --wait "*)
    u="$4"
    if [[ -e "$S/stale-start.$u" ]]; then rm "$S/stale-start.$u"; stamp $(( $(date +%s) - 600 )) >"$S/started.$u"
    else stamp "$(date +%s)" >"$S/started.$u"; fi
    exit "$(cat "$S/rc.$u" 2>/dev/null || echo 0)" ;;
  *) exit 1 ;;
esac
"""

CURL_STUB = r"""#!/usr/bin/env bash
title=""; body=""; priority=""; prev=""
for a in "$@"; do
  [[ "$prev" == -H && "$a" == Title:* ]] && title="${a#Title: }"
  [[ "$prev" == -H && "$a" == Priority:* ]] && priority="${a#Priority: }"
  [[ "$prev" == -d ]] && body="$a"
  prev="$a"
done
printf '%s [%s] | %s\n' "$title" "$priority" "$body" >>"$STUB_STATE/notify"
"""


class MaintenanceFlowTests(unittest.TestCase):
    OLD = "a" * 40
    NEW = "b" * 40

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.state = self.tmp / "stub"
        (self.state / "git").mkdir(parents=True)
        game = self.tmp / "linux-game-server"
        (game / "2004scape").mkdir(parents=True)
        for name in ("maintenance.sh", "countdown.js"):
            shutil.copy(SCAPE / name, game / "2004scape" / name)
        self.script = game / "2004scape" / "maintenance.sh"
        self.runtime = self.tmp / "games/lost-city/runtime"
        self.rs_src = self.tmp / "rs-sdk-src"
        self.rs_data = self.tmp / "games/rs-sdk/data"
        for repo in self.lostcity_repos():
            repo.mkdir(parents=True)
        self.rs_src.mkdir()
        (self.rs_data / "players").mkdir(parents=True)
        (self.rs_data / "db.sqlite").write_text("old-rs-data")
        (self.rs_data / ".hidden").write_text("kept")
        (self.runtime / "engine/db.sqlite").write_text("old-db")
        (self.runtime / "engine/.env").write_text("NODE_ID=10\n")
        self.players = self.runtime / "engine/data/players"
        (self.players / "main").mkdir(parents=True)
        (self.players / "main/alice.sav").write_text("old-save")
        (game / "lostcity").mkdir()
        (game / "rs-sdk").mkdir()
        (game / "lostcity/.env").write_text(f"LOSTCITY_RUNTIME_DIR={self.runtime}\nLOSTCITY_REVISION=254\n")
        (game / "rs-sdk/.env").write_text(f"RS_SDK_SOURCE_DIR={self.rs_src}\nRS_SDK_DATA_DIR={self.rs_data}\n")
        self.next_epoch = int(time.time()) + 3600
        self.stub("next-epoch", self.next_epoch)
        self.backup_day = datetime.datetime.fromtimestamp(self.next_epoch).strftime("%a")
        other_day = next(d for d in ("Mon", "Tue") if d != self.backup_day)
        self.scape_env = game / "2004scape/.env"
        self.base_env = f"COUNTDOWN_MINUTES=1\nNTFY_URL=https://ntfy.example\nNTFY_TOPIC=t\nMAINTENANCE_DAY={other_day}\n"
        self.scape_env.write_text(self.base_env)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("docker", DOCKER_STUB), ("git", GIT_STUB), ("systemctl", SYSTEMCTL_STUB),
                           ("curl", CURL_STUB), ("sleep", "#!/usr/bin/env bash\n"),
                           ("flock", "#!/usr/bin/env bash\n")):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "STUB_STATE": str(self.state),
                    "XDG_STATE_HOME": str(self.tmp / "xdg"), "PLAYERS_DIR": str(self.players),
                    "MIGRATE_DB": str(self.runtime / "engine/db.sqlite"), "RS_DATA": str(self.rs_data)}
        self.state_dir = self.tmp / "xdg/computer-setup/2004scape-maintenance"
        self.set_backup_env(lostcity=True, rs_sdk=True)
        compare = " ".join(f"--compare-live {self.runtime}/{state}" for state in
                           ("server.json", "engine/data/players"))
        compare += f" --compare-lostcity-config {self.runtime}"
        self.stub("verify-exec", f"{{ argv[]=/usr/bin/env bash /bundle/restore-check.sh /repo/linux-game-server {compare} --compare-live {self.rs_data} --compare-sqlite {self.runtime}/engine/db.sqlite lostcity/db.sqlite.sqlitebak ; }}")
        for repo in self.lostcity_repos():
            self.set_repo(repo, "254", self.OLD, self.OLD)
        self.set_repo(self.rs_src, "main", self.OLD, self.OLD)

    def lostcity_repos(self):
        return [self.runtime / "engine", self.runtime / "content"]

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

    def maintenance_night(self):
        self.scape_env.write_text(self.base_env + f"MAINTENANCE_DAY={self.backup_day}\n")

    def running(self, *containers):
        for c in containers:
            (self.state / f"running.{c}").write_text("true\n")

    def stub(self, name, value):
        (self.state / name).write_text(f"{value}\n")

    def run_maintenance(self, *args):
        (self.state / "calls").write_text("")
        result = subprocess.run(["bash", str(self.script), *args], env=self.env, capture_output=True, text=True)
        calls = (self.state / "calls").read_text().splitlines()
        notify = (self.state / "notify").read_text() if (self.state / "notify").exists() else ""
        return result, calls, notify

    def index(self, calls, needle, after=-1):
        return next(i for i, line in enumerate(calls) if i > after and needle in line)

    def count(self, calls, needle):
        return sum(needle in line for line in calls)

    def assert_no_call(self, calls, needle):
        self.assertFalse(any(needle in line for line in calls), f"unexpected {needle!r} in {calls}")

    # --- when maintenance happens -------------------------------------------------

    def test_stopped_stacks_are_left_alone(self):
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not running; left alone", result.stdout)
        self.assert_no_call(calls, "git ")
        self.assert_no_call(calls, "docker exec")

    def test_quiet_night_does_nothing(self):
        self.running("lostcity", "rs-sdk-server")
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("up to date"), 2)
        self.assertIn("nothing to do", result.stdout)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "start --wait")
        self.assertEqual(notify, "")

    def test_weekly_restart_backs_up_and_verifies_the_stopped_games(self):
        self.running("lostcity", "rs-sdk-server")
        self.maintenance_night()
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for container in ("lostcity", "rs-sdk-server"):
            self.assertLess(self.index(calls, f"docker update --restart=no {container}"),
                            next(i for i, line in enumerate(calls) if line.startswith("docker exec") and f" {container} bun " in line))
        exec_calls = [line for line in calls if line.startswith("docker exec")]
        self.assertEqual(len(exec_calls), 2)
        self.assertFalse(any("COUNTDOWN_WITH_UPDATE" in line for line in exec_calls))
        timer = self.index(calls, "show game-backup.timer")
        backup = self.index(calls, "start --wait game-backup.service")
        verify = self.index(calls, "start --wait game-backup-restore-check.service")
        self.assertLess(timer, backup)
        self.assertLess(backup, verify)
        self.assertLess(verify, self.index(calls, "up -d --no-build --force-recreate"))
        self.assertEqual(self.count(calls, "up -d --no-build --force-recreate"), 2)
        self.assert_no_call(calls, "merge --ff-only")
        self.assertIn("2004Scape maintenance done", notify)

    def test_now_skips_the_schedule(self):
        self.running("lostcity")
        result, calls, _ = self.run_maintenance("--now")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_call(calls, "game-backup.timer")
        self.assertEqual(self.count(calls, "start --wait game-backup.service"), 1)

    def test_check_only_reports(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "content", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_maintenance("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lostcity: update available (content@bbbbbbbbbbbb)", result.stdout)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "merge --ff-only")

    def test_webclient_is_not_an_update_source(self):
        self.running("lostcity")
        result, calls, _ = self.run_maintenance("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_call(calls, "webclient")

    # --- updates ------------------------------------------------------------------------

    def test_pending_update_waits_for_weekly_maintenance(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_call(calls, "docker exec")
        self.assert_no_call(calls, "merge --ff-only")

    def test_full_update_order(self):
        self.maintenance_night()
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        no_restart = self.index(calls, "docker update --restart=no lostcity")
        announce = self.index(calls, "docker exec -e COUNTDOWN_DEADLINE_MS=")
        self.assertIn("COUNTDOWN_WITH_UPDATE=1", calls[announce])
        backup = self.index(calls, "start --wait game-backup.service")
        verify = self.index(calls, "start --wait game-backup-restore-check.service")
        merge = self.index(calls, f"git {self.runtime}/engine merge --ff-only --quiet {self.NEW}")
        rebuild = self.index(calls, "run --rm --no-deps -T --name lostcity-update lostcity bash -c cd engine && bun install && bun run sqlite:migrate && bun run build")
        up = self.index(calls, "up -d --no-build --force-recreate lostcity")
        for earlier, later in ((no_restart, announce), (announce, backup), (backup, verify), (verify, merge),
                               (merge, rebuild), (rebuild, up)):
            self.assertLess(earlier, later)
        tag = self.index(calls, "docker tag sha256:running-rs-sdk-server computer-setup/rs-sdk:rollback")
        snapshot = self.index(calls, "docker run --rm --network none --entrypoint sh")
        rs_merge = self.index(calls, f"git {self.rs_src} merge --ff-only --quiet {self.NEW}")
        build = self.index(calls, " build rs-sdk", after=rs_merge)
        for earlier, later in ((verify, tag), (tag, snapshot), (snapshot, rs_merge),
                               (build, self.index(calls, "up -d --no-build --force-recreate rs-sdk"))):
            self.assertLess(earlier, later)
        self.assert_no_call(calls, f"git {self.runtime}/content merge")
        self.assertEqual(self.head(self.runtime / "engine"), self.NEW)
        self.assertEqual((self.runtime.parent / "runtime.pre-update/db.sqlite").read_text(), "old-db")
        self.assertEqual((self.runtime.parent / "runtime.pre-update/players/main/alice.sav").read_text(), "old-save")
        self.assertEqual((self.rs_data.parent / "data.pre-update/db.sqlite").read_text(), "old-rs-data")
        self.assertTrue((self.rs_data.parent / "data.pre-update.complete").exists())
        self.assertEqual(notify.count("2004Scape updated"), 2)
        self.assert_no_call(calls, "reset --hard")
        self.assertFalse((self.state_dir / "lostcity.inprogress").exists())

    def test_stack_without_update_is_back_before_the_updates(self):
        self.maintenance_night()
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        rs_exec = next(line for line in calls if line.startswith("docker exec") and "rs-sdk-server" in line)
        self.assertNotIn("COUNTDOWN_WITH_UPDATE", rs_exec)
        self.assertLess(self.index(calls, "up -d --no-build --force-recreate rs-sdk"),
                        self.index(calls, "merge --ff-only"))

    def test_unhealthy_update_rolls_back_and_is_not_retried(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("healthy-from-up.lostcity", 2)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        # The migration rewrote the database and the new code saved players; the
        # rollback put the pre-update copies back.
        self.assertEqual((self.runtime / "engine/db.sqlite").read_text(), "old-db")
        self.assertFalse((self.runtime / "engine/db.sqlite-journal").exists())
        self.assertEqual((self.players / "main/alice.sav").read_text(), "old-save")
        self.assertFalse((self.players / "main/new.sav").exists())
        reset = self.index(calls, f"git {self.runtime}/engine reset --hard --quiet {self.OLD}")
        self.assertGreater(reset, self.index(calls, f"merge --ff-only --quiet {self.NEW}"))
        self.assertTrue(any("bun install && bun run build" in line for line in calls[reset:]))
        self.assertEqual(self.head(self.runtime / "engine"), self.OLD)
        self.assertIn("back up on its previous code", notify)
        self.assertEqual((self.state_dir / "lostcity.failed").read_text().strip(), f"engine@{self.NEW[:12]}")
        self.assertFalse((self.state_dir / "lostcity.inprogress").exists())

        self.maintenance_night()
        self.scape_env.write_text(self.base_env)
        self.running("lostcity")
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("failed before", result.stdout)
        self.assert_no_call(calls, "docker exec")

    def test_failed_migration_rolls_back_database_and_journal(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("migrate-rc", 1)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.runtime / "engine/db.sqlite").read_text(), "old-db")
        self.assertFalse((self.runtime / "engine/db.sqlite-journal").exists())
        # Only the rollback starts the stack: the failed update never did.
        self.assertEqual(self.count(calls, "up -d --no-build --force-recreate lostcity"), 1)
        self.assertIn("2004Scape update FAILED", notify)

    def test_rs_sdk_rollback_restores_image_and_data(self):
        self.maintenance_night()
        self.running("rs-sdk-server")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        self.stub("healthy-from-up.rs-sdk-server", 2)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.rs_data / "db.sqlite").read_text(), "old-rs-data")
        self.assertEqual((self.rs_data / ".hidden").read_text(), "kept")
        retag = self.index(calls, "docker tag computer-setup/rs-sdk:rollback computer-setup/rs-sdk:local")
        self.assertGreater(retag, self.index(calls, f"git {self.rs_src} reset --hard --quiet {self.OLD}"))
        self.assertEqual(self.head(self.rs_src), self.OLD)
        self.assertIn("back up on its previous code", notify)

    def test_lostcity_snapshot_failure_only_restarts_untouched_code(self):
        self.running("lostcity")
        self.maintenance_night()
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        (self.runtime / "engine/db.sqlite").unlink()
        (self.runtime / "engine/db.sqlite").mkdir()
        cp = self.tmp / "bin/cp"
        cp.write_text("#!/usr/bin/env bash\nexit 1\n")
        cp.chmod(0o755)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_no_call(calls, "merge --ff-only")
        self.assert_no_call(calls, "reset --hard")
        self.assertEqual(self.count(calls, "up -d --no-build --force-recreate lostcity"), 1)
        self.assertFalse((self.state_dir / "lostcity.inprogress").exists())

    def test_failure_before_any_change_only_restarts(self):
        self.maintenance_night()
        self.running("rs-sdk-server")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        self.stub("run-rc", 1)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assert_no_call(calls, "merge --ff-only")
        self.assert_no_call(calls, "reset --hard")
        self.assertEqual(self.count(calls, "up -d --no-build --force-recreate rs-sdk"), 1)
        self.assertIn("back up on its previous code", notify)
        self.assertNotIn("DOWN", notify)

    def test_failed_rollback_reports_the_stack_down_and_retries_next_run(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("healthy-from-up.lostcity", 99)
        result, _, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not be put back; the stack is down", result.stdout)
        self.assertIn("server DOWN [urgent]", notify)
        self.assertTrue((self.state_dir / "lostcity.inprogress").exists())

        self.stub("healthy-from-up.lostcity", 1)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("rolled back and healthy", result.stdout)
        self.assertFalse((self.state_dir / "lostcity.inprogress").exists())

    def test_interrupted_update_is_rolled_back_by_resume(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        (self.state / "kill-on-rebuild").touch()
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        self.assertIn("exit 143", notify)
        self.assertIn("lostcity is DOWN mid-update", notify)
        self.assertIn("[urgent]", notify)
        self.assertEqual(self.head(self.runtime / "engine"), self.NEW)
        self.assertEqual(self.count(calls, "up -d --no-build --force-recreate"), 0)

        result, calls, notify = self.run_maintenance("--resume")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.head(self.runtime / "engine"), self.OLD)
        self.assertEqual((self.runtime / "engine/db.sqlite").read_text(), "old-db")
        self.assertIn("2004Scape interrupted update rolled back", notify)
        self.assertEqual((self.state_dir / "lostcity.failed").read_text().strip(), f"engine@{self.NEW[:12]}")
        self.assert_no_call(calls, "docker exec")

    # --- refusals and aborts ------------------------------------------------------------

    def test_backup_failure_restarts_without_updating(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("rc.game-backup.service", 1)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assert_no_call(calls, "merge --ff-only")
        self.assert_no_call(calls, "start --wait game-backup-restore-check.service")
        backup = self.index(calls, "start --wait game-backup.service")
        self.assertTrue(any("up -d --no-build --force-recreate" in line for line in calls[backup:]))
        self.assertEqual(self.head(self.runtime / "engine"), self.OLD)
        self.assertIn("2004Scape maintenance aborted", notify)

    def test_failed_restore_check_restarts_without_updating(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("rc.game-backup-restore-check.service", 1)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assert_no_call(calls, "merge --ff-only")
        verify = self.index(calls, "start --wait game-backup-restore-check.service")
        self.assertTrue(any("up -d --no-build --force-recreate" in line for line in calls[verify:]))
        self.assertIn("stopped phase", notify)

    def test_completed_scheduled_backup_is_not_run_twice(self):
        self.running("lostcity")
        self.maintenance_night()
        stamp = datetime.datetime.fromtimestamp(int(time.time()) + 3600, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        self.stub("started.game-backup.service", stamp)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_no_call(calls, "start --wait game-backup.service")
        self.assertEqual(self.count(calls, "start --wait game-backup-restore-check.service"), 1)

    def test_backup_that_began_before_the_shutdown_runs_again(self):
        self.maintenance_night()
        self.running("lostcity")
        self.maintenance_night()
        (self.state / "stale-start.game-backup.service").touch()
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.count(calls, "start --wait game-backup.service"), 2)

    def test_last_failed_backup_or_check_keeps_the_games_up(self):
        self.maintenance_night()
        self.running("lostcity")
        self.maintenance_night()
        for unit in ("game-backup.service", "game-backup-restore-check.service"):
            with self.subTest(unit=unit):
                (self.state / "notify").unlink(missing_ok=True)
                self.stub(f"result.{unit}", "exit-code")
                result, calls, notify = self.run_maintenance()
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"the last {unit} run failed", result.stdout + result.stderr)
                self.assert_no_call(calls, "docker update")
                self.assert_no_call(calls, "docker exec")
                self.assertIn("preflight phase", notify)
                (self.state / f"result.{unit}").unlink()

    def test_refuses_when_backup_does_not_cover_the_stack(self):
        self.maintenance_night()
        self.running("rs-sdk-server")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        self.set_backup_env(lostcity=True, rs_sdk=False)
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not cover rs-sdk", result.stdout + result.stderr)
        self.assert_no_call(calls, "docker update")
        self.assert_no_call(calls, "docker exec")
        self.assertIn("aborted", notify)

    def test_refuses_restore_check_without_stopped_data_comparisons(self):
        self.running("lostcity", "rs-sdk-server")
        self.maintenance_night()
        complete = (self.state / "verify-exec").read_text()
        for missing in (*(f"--compare-live {self.runtime}/{state}" for state in
                          ("server.json", "engine/data/players")),
                        f"--compare-lostcity-config {self.runtime}",
                        f"--compare-live {self.rs_data}",
                        f"--compare-sqlite {self.runtime}/engine/db.sqlite lostcity/db.sqlite.sqlitebak"):
            with self.subTest(missing=missing):
                self.stub("verify-exec", complete.replace(missing, ""))
                result, calls, _ = self.run_maintenance()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("does not compare", result.stdout + result.stderr)
                self.assert_no_call(calls, "docker exec")

    def test_world_json_only_configuration_is_supported(self):
        self.running("lostcity")
        self.maintenance_night()
        (self.runtime / "engine/.env").unlink()
        config = self.runtime / "engine/data/config"
        config.mkdir()
        (config / "world.json").write_text('{"nodeId":10}')
        result, _, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_configuration_refuses_before_countdown(self):
        self.running("lostcity")
        self.maintenance_night()
        (self.runtime / "engine/.env").unlink()
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("neither .env nor world.json", result.stdout + result.stderr)
        self.assert_no_call(calls, "docker exec")

    def test_refuses_without_the_restore_check_unit(self):
        self.maintenance_night()
        self.running("lostcity")
        self.maintenance_night()
        (self.state / "missing.game-backup-restore-check.service").touch()
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("game-backup-restore-check.service is not installed", result.stdout + result.stderr)
        self.assert_no_call(calls, "docker exec")

    def test_active_backup_is_never_interrupted(self):
        self.running("lostcity")
        self.maintenance_night()
        self.stub("active.game-backup.service", "activating")
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assert_no_call(calls, "docker exec")
        self.assert_no_call(calls, " stop ")
        self.assert_no_call(calls, "up -d")

    def test_backup_time_must_leave_room_for_the_countdown(self):
        self.maintenance_night()
        self.running("lostcity")
        self.maintenance_night()
        for offset, message in ((60, "too close"), (8 * 3600, "more than 6 h away")):
            with self.subTest(offset=offset):
                self.stub("next-epoch", int(time.time()) + offset)
                day = datetime.datetime.fromtimestamp(int(time.time()) + offset).strftime("%a")
                self.scape_env.write_text(self.base_env + f"MAINTENANCE_DAY={day}\n")
                result, calls, _ = self.run_maintenance()
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stdout + result.stderr)
                self.assert_no_call(calls, "docker exec")

    def test_failed_announcement_cancels_before_any_shutdown(self):
        self.maintenance_night()
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        (self.state / "announce-fail.rs-sdk-server").touch()
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("rs-sdk: could not announce the countdown", result.stdout + result.stderr)
        self.assert_no_call(calls, "start --wait")
        self.assert_no_call(calls, "merge --ff-only")
        self.assertTrue(any("docker update --restart=unless-stopped rs-sdk-server" in line for line in calls))
        self.assertIn("aborted", notify)

    def test_engine_that_never_got_the_countdown_is_left_running(self):
        self.maintenance_night()
        self.running("lostcity")
        self.maintenance_night()
        (self.state / "no-shutdown.lostcity").touch()
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not shut down on its countdown", result.stdout + result.stderr)
        self.assert_no_call(calls, " stop ")
        self.assert_no_call(calls, "start --wait")
        self.assertTrue(any("docker update --restart=unless-stopped lostcity" in line for line in calls))
        self.assertIn("countdown phase", notify)

    def test_unclean_shutdown_does_not_back_up_or_update(self):
        self.maintenance_night()
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.stub("exit.lostcity", "false 137 false")
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 1)
        self.assertIn("did not shut down cleanly", result.stdout + result.stderr)
        self.assert_no_call(calls, "start --wait")
        self.assert_no_call(calls, "merge --ff-only")

    def test_diverged_or_dirty_checkouts_are_skipped_and_reported_once(self):
        self.running("lostcity", "rs-sdk-server")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        (self.repo_dir(self.runtime / "engine") / "ancestor-rc").write_text("1\n")
        self.set_repo(self.rs_src, "main", self.OLD, self.NEW)
        (self.repo_dir(self.rs_src) / "dirty").write_text(" M server/x.ts\n")
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("has diverged", result.stdout)
        self.assertIn("has local changes", result.stdout)
        self.assert_no_call(calls, "docker exec")
        self.assertEqual(notify.count("2004Scape updates skipped"), 2)
        _, _, notify = self.run_maintenance()
        self.assertEqual(notify.count("2004Scape updates skipped"), 2)

    def test_wrong_branch_is_skipped(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "main", self.OLD, self.NEW)
        result, calls, _ = self.run_maintenance()
        self.assertEqual(result.returncode, 0)
        self.assertIn("is on main, not 254", result.stdout)
        self.assert_no_call(calls, "docker exec")

    def test_auto_update_off_notifies_once(self):
        self.running("lostcity")
        self.set_repo(self.runtime / "engine", "254", self.OLD, self.NEW)
        self.scape_env.write_text(self.base_env + "AUTO_UPDATE=false\n")
        result, calls, notify = self.run_maintenance()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_call(calls, "docker exec")
        self.assertEqual(notify.count("2004Scape update available"), 1)
        self.run_maintenance()
        notify = (self.state / "notify").read_text()
        self.assertEqual(notify.count("2004Scape update available"), 1)

    def test_rejects_bad_settings_and_paths(self):
        for setting, name in (("COUNTDOWN_MINUTES=0", "COUNTDOWN_MINUTES"), ("COUNTDOWN_MINUTES=61", "COUNTDOWN_MINUTES"),
                              ("MAINTENANCE_DAY=Monday", "MAINTENANCE_DAY")):
            with self.subTest(setting=setting):
                self.scape_env.write_text(setting + "\n")
                result, _, _ = self.run_maintenance()
                self.assertEqual(result.returncode, 1)
                self.assertIn(name, result.stdout + result.stderr)
        self.scape_env.write_text("")
        for bad in ("relative", "/x/..", "/x/.", "/.", "/.."):
            with self.subTest(path=bad):
                (self.tmp / "linux-game-server/rs-sdk/.env").write_text(f"RS_SDK_SOURCE_DIR={bad}\nRS_SDK_DATA_DIR=/x/y\n")
                result, _, _ = self.run_maintenance()
                self.assertEqual(result.returncode, 1)
                self.assertIn("unsupported path", result.stdout + result.stderr)


class UnitTemplateTests(unittest.TestCase):
    def test_service_runs_unprivileged_with_room_for_the_whole_run(self):
        service = (SCAPE / "2004scape-maintenance.service.template").read_text()
        self.assertIn("User=@USER@", service)
        self.assertIn("ExecStart=/usr/bin/env bash @MAINTENANCE_SCRIPT@", service)
        self.assertIn("TimeoutStartSec=8h", service)
        self.assertNotIn("ExecStart=+", service)

    def test_timer_fires_early_enough_for_the_longest_countdown(self):
        # maintenance.sh brings the games down 2 minutes before the backup and
        # allows countdowns up to 60 minutes, plus 30 s to announce.
        def minutes(text):
            hh, mm = re.search(r"OnCalendar=\*-\*-\* (\d\d):(\d\d):00", text).groups()
            return int(hh) * 60 + int(mm)
        timer = (SCAPE / "2004scape-maintenance.timer").read_text()
        backup = (ROOT / "backup/game-backup.timer").read_text()
        self.assertLessEqual(minutes(timer) + 60 + 2 + 1, minutes(backup))
        self.assertGreater(minutes(timer), minutes(backup) - 6 * 60)
        self.assertNotIn("Persistent=true", timer)

    def test_polkit_rule_allows_only_starting_the_backup_and_its_check(self):
        rule = (SCAPE / "2004scape-maintenance.rules.template").read_text()
        self.assertIn('subject.user == "@USER@"', rule)
        self.assertIn('action.lookup("unit") == "game-backup.service"', rule)
        self.assertIn('action.lookup("unit") == "game-backup-restore-check.service"', rule)
        self.assertIn('action.lookup("verb") == "start"', rule)
        self.assertEqual(rule.count("action.lookup(\"unit\")"), 2)
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
        result = subprocess.run(["bash", str(SCAPE / "install-maintenance-timer.sh"), "--dry-run"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[dry-run] systemctl enable --now 2004scape-maintenance.timer", result.stdout)
        self.assertIn("User=tester", result.stdout)
        self.assertIn("disable --now 2004scape-update.timer", result.stdout)
        self.assertNotIn("stop 2004scape-update.service", result.stdout)


if __name__ == "__main__":
    unittest.main()
