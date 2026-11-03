from pathlib import Path
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORLDS = ROOT / "rs-sdk/worlds"
SCAPE = ROOT / "2004scape"
JS = shutil.which("node") or shutil.which("bun")

spec = importlib.util.spec_from_file_location("rs_sdk_worlds", WORLDS / "worlds.py")
worlds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worlds)


def compose_env(path, service):
    return yaml.safe_load(path.read_text())["services"][service]["environment"]


class WorldConfigTests(unittest.TestCase):
    def setUp(self):
        self.rows = worlds.load_config()

    def test_world_1_is_the_main_stack_and_the_test_world_is_100(self):
        self.assertEqual((self.rows[0]["id"], self.rows[0]["node"], self.rows[0]["role"]), (1, 10, "live"))
        test = worlds.world(100, self.rows)
        self.assertEqual((test["node"], test["role"]), (100, "test"))

    def test_world_1_row_matches_its_compose_service(self):
        env = compose_env(ROOT / "rs-sdk/docker-compose.yml", "rs-sdk")
        row = self.rows[0]
        self.assertEqual(int(env["NODE_ID"]), row["node"])
        self.assertEqual(int(env["WEB_PORT"]), row["web"])
        self.assertEqual(int(env["WEB_MANAGEMENT_PORT"]), row["management"])
        self.assertEqual(int(env["NODE_PORT"]), row["game"])
        self.assertEqual(int(env["AGENT_PORT"]), row["gateway"])
        self.assertEqual(int(env["GATEWAY_PUBLIC_PORT"]), row["gateway_public"])

    def test_extra_world_ports_avoid_every_known_listener(self):
        # Lost City's engine and servers, RS-SDK's internal servers, telemetry,
        # hiscores, the portal and fleet service, and the other tailnet ports.
        taken = {43594, 43500, 43501, 45099, 8888, 8898, 43510, 43511, 45109, 43512, 8889,
                 8098, 8100, 8096, 8097, 8099, 9000, 3000, 9443, 9444, 9447}
        for row in self.rows[1:]:
            for key in worlds.FIELDS[3:]:
                self.assertNotIn(row[key], taken, f"world {row['id']} {key}")

    def test_duplicate_ports_and_ids_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            conf = Path(tmp) / "worlds.conf"
            base = "1 10 live 8080 8899 43595 7780 7781 9445 9446\n"
            for extra in ("2 11 live 8080 8199 43600 7790 7791 9448 9449\n",
                          "2 10 live 8180 8199 43600 7790 7791 9448 9449\n",
                          "2 11 gold 8180 8199 43600 7790 7791 9448 9449\n"):
                conf.write_text(base + extra)
                with self.assertRaises(ValueError):
                    worlds.load_config(conf)
            conf.write_text("2 11 live 8180 8199 43600 7790 7791 9448 9449\n")
            with self.assertRaises(ValueError):
                worlds.load_config(conf)

    def test_tailnet_routes_exist_for_every_extra_world(self):
        serve = (ROOT / "serve.conf").read_text()
        for row in self.rows[1:]:
            self.assertIn(f'"{row["https_web"]} / http://127.0.0.1:{row["web"]}"', serve)
            self.assertIn(f'"{row["https_gateway"]} / http://127.0.0.1:{row["gateway_public"]}"', serve)
        self.assertIn("/rs-sdk-worlds.json", serve)


class WorldComposeTests(unittest.TestCase):
    def setUp(self):
        self.main = compose_env(ROOT / "rs-sdk/docker-compose.yml", "rs-sdk")
        self.world = compose_env(WORLDS / "world-compose.yml", "world")

    def test_gameplay_matches_world_1(self):
        for key in ("NODE_MEMBERS", "NODE_XPRATE", "NODE_INFINITE_RUN", "NODE_RANDOM_EVENTS", "NODE_TICKRATE",
                    "WEBSITE_REGISTRATION", "DB_BACKEND", "GE_DATABASE"):
            self.assertEqual(self.world[key], self.main[key], key)

    def test_uses_world_1s_login_friend_and_logger_servers(self):
        for key in ("LOGIN_HOST", "LOGIN_PORT", "FRIEND_HOST", "FRIEND_PORT", "LOGGER_HOST", "LOGGER_PORT"):
            self.assertEqual(self.world[key], self.main[key], key)
        self.assertEqual(self.world["EASY_STARTUP"], "false")
        self.assertEqual(self.world["LOGIN_SERVER"], "true")
        self.assertEqual(self.world["FRIEND_SERVER"], "true")

    def test_one_exchange_engine_and_guards_on(self):
        self.assertEqual(self.world["GE_ENABLED"], "false")
        self.assertEqual(self.world["WORLD_EXCLUSIVE_LOGIN"], "true")
        self.assertEqual(self.world["WORLD_TAKEOVER_WATCH"], "true")
        self.assertTrue(self.world["WORLD_SAVE_BACKUP_DIR"].startswith("/opt/world-state/"))

    def test_isolated_like_world_1(self):
        service = yaml.safe_load((WORLDS / "world-compose.yml").read_text())["services"]["world"]
        self.assertEqual(service["network_mode"], "host")
        self.assertNotIn("ports", service)
        self.assertEqual(service["cap_drop"], ["ALL"])
        self.assertIn("no-new-privileges:true", service["security_opt"])
        self.assertIn("com.centurylinklabs.watchtower.enable=false", service["labels"])
        self.assertEqual(service["container_name"], "rs-sdk-world-${WORLD_ID:?set by world.sh}")


class IsolatedWorldTests(unittest.TestCase):
    """The test world on its own servers and a copy of world 1's data (world.sh test up --isolated)."""

    def setUp(self):
        self.text = (WORLDS / "isolated-compose.yml").read_text()
        self.service = yaml.safe_load(self.text)["services"]["world"]
        self.env = self.service["environment"]
        self.main = compose_env(ROOT / "rs-sdk/docker-compose.yml", "rs-sdk")
        self.world_sh = (SCAPE / "world.sh").read_text()

    def isolated_ports(self):
        return {key: int(re.search(rf'"\$\{{{key}:=(\d+)\}}"', self.world_sh).group(1))
                for key in ("ISOLATED_LOGIN_PORT", "ISOLATED_FRIEND_PORT", "ISOLATED_LOGGER_PORT")}

    def test_never_mounts_world_1s_data(self):
        body = "\n".join(line for line in self.text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("RS_SDK_DATA_DIR", body)
        data = [v for v in self.service["volumes"] if v["target"] == "/opt/server/data"]
        self.assertEqual([v["source"] for v in data], ["${WORLD_ISOLATED_DATA_DIR:?set by world.sh}"])
        self.assertIn('[[ "$(realpath "$data")" != "$(realpath "$RS_SDK_DATA_DIR")" ]]', self.world_sh)

    def test_runs_its_own_login_friend_and_logger_servers(self):
        self.assertEqual(self.env["EASY_STARTUP"], "true")
        self.assertEqual(self.env["LOGIN_SERVER"], "true")
        for key in ("LOGIN_PORT", "FRIEND_PORT", "LOGGER_PORT"):
            self.assertEqual(self.env[key], f"${{WORLD_ISOLATED_{key}:?set by world.sh}}")
        ports = self.isolated_ports()
        world_1 = {int(self.main[key]) for key in ("LOGIN_PORT", "FRIEND_PORT", "LOGGER_PORT")}
        taken = {43594, 43500, 43501, 45099, 8888, 8898, 43510, 43511, 45109, 43512, 8889,
                 8098, 8100, 8096, 8097, 8099, 9000, 3000, 9443, 9444, 9447}
        configured = {row[key] for row in worlds.load_config() for key in worlds.FIELDS[3:]}
        for name, port in ports.items():
            self.assertNotIn(port, world_1 | taken | configured, name)
        self.assertEqual(len(set(ports.values())), 3)

    def test_gameplay_matches_world_1_and_the_exchange_is_its_own(self):
        for key in ("NODE_MEMBERS", "NODE_XPRATE", "NODE_INFINITE_RUN", "NODE_RANDOM_EVENTS", "NODE_TICKRATE",
                    "WEBSITE_REGISTRATION", "DB_BACKEND", "GE_DATABASE"):
            self.assertEqual(self.env[key], self.main[key], key)
        self.assertEqual(self.env["GE_ENABLED"], "true")

    def test_always_a_guarded_test_world_that_never_restarts_itself(self):
        self.assertEqual(self.env["WORLD_ISOLATED"], "true")
        self.assertEqual(self.env["WORLD_ALLOWLIST_ENABLED"], "true")
        self.assertEqual(self.service["restart"], "no")
        self.assertIn("computer-setup.rs-sdk.world-mode=isolated", self.service["labels"])
        self.assertEqual(self.service["cap_drop"], ["ALL"])
        self.assertIn("no-new-privileges:true", self.service["security_opt"])
        self.assertEqual(self.service["container_name"], "rs-sdk-world-${WORLD_ID:?set by world.sh}")
        self.assertIn('[[ "$W_ROLE" == test ]] || die', self.world_sh)

    def test_entrypoint_runs_the_images_own_start_only_on_a_marked_copy(self):
        text = (WORLDS / "world-entrypoint.sh").read_text()
        branch = text.split('if [[ "${WORLD_ISOLATED:-}" == true ]]; then', 1)[1].split("\nfi\n", 1)[0]
        self.assertIn("[[ -f /opt/server/data/ISOLATED-COPY ]]", branch)
        self.assertIn('"${LOGIN_PORT:-43510}" != 43510', branch)
        self.assertLess(branch.index("ISOLATED-COPY"), branch.index("bun /opt/world/world-node.js /opt"))
        self.assertLess(branch.index("world-node.js /opt"), branch.index("exec /opt/server/entrypoint.sh"))

    def test_down_skips_world_1s_login_table_and_keeps_the_copy_unless_wiped(self):
        down = self.world_sh.split("cmd_down() {", 1)[1].split("\ncmd_role()", 1)[0]
        isolated = down.index('[[ "$mode" == isolated ]] && { log')
        self.assertLess(isolated, down.index("login-release.js"))
        self.assertIn("--wipe) wipe=true", down)
        self.assertIn("isolated_wipe", down)
        self.assertIn('"$RS_SDK_DATA_DIR":/src:ro', self.world_sh)

    def test_world_list_marks_it_isolated_and_never_hoppable(self):
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        (tmp / "100.role").write_text("live\n")
        def inspect(name):
            labels = {"computer-setup.rs-sdk.world-mode": "isolated"} if name == "rs-sdk-world-100" else {}
            return {"Image": "sha256:x", "Config": {"Labels": labels},
                    "State": {"Status": "running", "Health": {"Status": "healthy"}}}
        saved = worlds.inspect, worlds.http_json, worlds.image_tags, worlds.image_labels
        self.addCleanup(lambda: setattr(worlds, "inspect", saved[0]) or setattr(worlds, "http_json", saved[1])
                        or setattr(worlds, "image_tags", saved[2]) or setattr(worlds, "image_labels", saved[3]))
        worlds.inspect = inspect
        worlds.http_json = lambda url: {"count": 1}
        worlds.image_tags = lambda image: []
        worlds.image_labels = lambda image: {}
        by_id = {w["id"]: w for w in worlds.world_list(tmp, host="game.example.ts.net")["worlds"]}
        self.assertEqual(by_id[100]["mode"], "isolated")
        self.assertFalse(by_id[100]["hoppable"])
        self.assertIn("thrown away", by_id[100]["note"])
        self.assertEqual(by_id[1]["mode"], "shared")
        self.assertTrue(by_id[1]["hoppable"])


@unittest.skipUnless(shutil.which("sqlite3"), "needs the sqlite3 command line")
class IsolatedCopyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.src = self.tmp / "world1"
        (self.src / "players/main").mkdir(parents=True)
        (self.src / "players/main/player_one.sav").write_bytes(b"\x20\x04save")
        db = sqlite3_connect(self.src / "db.sqlite")
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript("""
            CREATE TABLE account (id INTEGER PRIMARY KEY, username TEXT);
            CREATE TABLE account_login (account_id INT, profile TEXT, logged_in INT, login_time TEXT,
                                        logged_out INT, logout_time TEXT);
            INSERT INTO account VALUES (1, 'player_one'), (2, 'player_two');
            INSERT INTO account_login VALUES (1, 'main', 10, '2026-10-26 20:00:00', 0, NULL),
                                             (2, 'main', 0, NULL, 10, '2026-10-26 19:00:00');
        """)
        db.commit()
        self.writer = db  # kept open: the copy must read a live WAL database
        self.addCleanup(db.close)
        market = sqlite3_connect(self.src / "market.sqlite")
        market.executescript("CREATE TABLE offers (id INTEGER PRIMARY KEY); INSERT INTO offers VALUES (7);")
        market.commit()
        market.close()
        self.dst = self.tmp / "100.isolated"
        self.dst.mkdir()

    def copy(self):
        return subprocess.run(["sh", str(WORLDS / "isolated-copy.sh"), str(self.src), str(self.dst)],
                              capture_output=True, text=True)

    def test_copies_dbs_and_saves_and_logs_nobody_in(self):
        result = self.copy()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 accounts, 1 saves", result.stdout)
        data = self.dst / "data"
        self.assertTrue((data / "ISOLATED-COPY").is_file())
        self.assertFalse((self.dst / "data.new").exists())
        self.assertEqual((data / "players/main/player_one.sav").read_bytes(), b"\x20\x04save")
        copy = sqlite3_connect(data / "db.sqlite")
        self.assertEqual(copy.execute("SELECT count(*) FROM account_login WHERE logged_in != 0").fetchone()[0], 0)
        self.assertEqual(copy.execute("SELECT logged_out FROM account_login WHERE account_id = 2").fetchone()[0], 10)
        copy.close()
        self.assertEqual(sqlite3_connect(data / "market.sqlite").execute("SELECT id FROM offers").fetchone()[0], 7)
        # world 1's own database is untouched
        self.assertEqual(self.writer.execute("SELECT logged_in FROM account_login WHERE account_id = 1").fetchone()[0], 10)

    def test_a_new_copy_replaces_the_old_one(self):
        self.assertEqual(self.copy().returncode, 0)
        (self.dst / "data/players/main/stale.sav").write_bytes(b"old")
        self.assertEqual(self.copy().returncode, 0)
        self.assertFalse((self.dst / "data/players/main/stale.sav").exists())

    def test_refuses_a_source_without_a_database(self):
        (self.src / "db.sqlite").rename(self.src / "elsewhere.sqlite")
        result = self.copy()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.dst / "data").exists())


def sqlite3_connect(path):
    import sqlite3
    return sqlite3.connect(path)


class CandidateComposeTests(unittest.TestCase):
    def test_candidates_never_move_world_1s_tags(self):
        text = (WORLDS / "candidate-compose.yml").read_text()
        services = yaml.safe_load(text)["services"]
        self.assertEqual(services["candidate"]["image"], "${CANDIDATE_TAG:?set by world.sh}")
        self.assertEqual(services["upstream"]["image"], "${CANDIDATE_UPSTREAM_TAG:?set by world.sh}")
        body = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        self.assertNotIn("rs-sdk:local", body)
        self.assertNotIn("rs-sdk:upstream", body)
        self.assertEqual(services["candidate"]["build"]["additional_contexts"], {"rs_sdk_upstream": "service:upstream"})
        main = yaml.safe_load((ROOT / "rs-sdk/docker-compose.yml").read_text())["services"]
        self.assertEqual(services["upstream"]["build"]["dockerfile"], main["rs-sdk-upstream"]["build"]["dockerfile"])
        self.assertEqual(main["rs-sdk"]["build"]["dockerfile"], services["candidate"]["build"]["dockerfile"])

    def test_world_sh_builds_through_the_candidate_compose_file(self):
        text = (SCAPE / "world.sh").read_text()
        self.assertIn('docker compose -f "$WORLDS_DIR/candidate-compose.yml" build candidate', text)
        self.assertNotIn("docker build ", text)


class WorldStateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.row = worlds.world(100)

    def test_names_normalise_like_the_login_server(self):
        self.assertEqual(worlds.norm_name("Some Player"), "some_player")
        self.assertEqual(worlds.norm_name("  bot_x  "), "bot_x")

    def test_allowlist_ignores_comments_and_duplicates(self):
        (self.tmp / "100.allowlist").write_text("Some Player\n# a comment\nsome_player\nbot_x # tester\n\n")
        self.assertEqual(worlds.allowlist(100, self.tmp), ["bot_x", "some_player"])

    def test_test_role_turns_the_allowlist_on_and_never_restarts_itself(self):
        (self.tmp / "100.allowlist").write_text("bot_x\n")
        env = worlds.compose_env(self.row, self.tmp, "/data")
        self.assertEqual(env["WORLD_ALLOWLIST_ENABLED"], "true")
        self.assertEqual(env["WORLD_LOGIN_ALLOWLIST"], "bot_x")
        self.assertEqual(env["WORLD_RESTART"], "no")
        self.assertEqual(env["WORLD_NODE_ID"], 100)

    def test_live_role_opens_the_world(self):
        (self.tmp / "100.role").write_text("live\n")
        env = worlds.compose_env(self.row, self.tmp, "/data")
        self.assertEqual(env["WORLD_ALLOWLIST_ENABLED"], "false")
        self.assertEqual(env["WORLD_RESTART"], "unless-stopped")

    def test_world_list_never_offers_a_test_world_to_hop_to(self):
        def inspect(name):
            return {"Image": "sha256:x", "State": {"Status": "running", "Health": {"Status": "healthy"}}}
        saved = worlds.inspect, worlds.http_json, worlds.image_tags, worlds.image_labels
        self.addCleanup(lambda: setattr(worlds, "inspect", saved[0]) or setattr(worlds, "http_json", saved[1])
                        or setattr(worlds, "image_tags", saved[2]) or setattr(worlds, "image_labels", saved[3]))
        worlds.inspect = inspect
        worlds.http_json = lambda url: {"count": 3}
        worlds.image_tags = lambda image: []
        worlds.image_labels = lambda image: {}
        document = worlds.world_list(self.tmp, host="game.example.ts.net")
        by_id = {w["id"]: w for w in document["worlds"]}
        self.assertTrue(by_id[1]["hoppable"])
        self.assertFalse(by_id[100]["hoppable"])
        self.assertEqual(by_id[100]["bot_env"],
                         {"SERVER": "game.example.ts.net:9448", "GATEWAY_URL": "wss://game.example.ts.net:9449"})
        (self.tmp / "1.countdown").write_text(str(10 ** 10))
        document = worlds.world_list(self.tmp, host="game.example.ts.net")
        self.assertFalse(document["worlds"][0]["hoppable"])
        self.assertIsNotNone(document["worlds"][0]["countdown_until"])
        json.dumps(document)

    def test_compat_refuses_another_curve_save_format_or_migrations(self):
        base = {"xp": "a", "save": "0x2004/v9/x/y", "migrations": ["m1"], "content": {"obj": "1"}, "entrypoint": "e"}
        self.assertEqual(worlds.compat(base, dict(base)), ([], []))
        for key, value in (("xp", "b"), ("save", "0x2004/v10/x/y"), ("migrations", ["m1", "m2"])):
            problems, _ = worlds.compat(base, {**base, key: value})
            self.assertEqual(len(problems), 1, key)
        problems, _ = worlds.compat(base, {**base, "xp": "error: levelExperience block not found"})
        self.assertTrue(problems)

    def test_content_changes_need_an_explicit_allow(self):
        base = {"xp": "a", "save": "s", "migrations": [], "content": {"obj": "1", "npc": "2"}, "entrypoint": "e"}
        changed = {**base, "content": {"obj": "9", "npc": "2"}}
        problems, _ = worlds.compat(base, changed)
        self.assertIn("obj", problems[0])
        problems, warnings = worlds.compat(base, changed, allow_content_change=True)
        self.assertEqual(problems, [])
        self.assertTrue(warnings)


ANCHORS = {
    "web/websocket.ts": "            const agentWs = new WebSocket(`ws://localhost:7780/${ws.data.agentLabel ?? ''}`);\n",
    "server/login/LoginThread.ts": ("import Environment from '#/util/Environment.js';\n"
                                    "        case 'player_login': {\n"
                                    "            const { socket, remoteAddress, username, password, uid, lowMemory, reconnecting, hasSave } = msg;\n"
                                    "            break;\n        }\n"),
    "engine/World.ts": ("import fs from 'fs';\n    private processLogouts(): void {\n    }\n"
                        "            const { username, lowMemory, reconnecting, staffmodlevel, muted_until, members, messageCount } = msg;\n"
                        "            const save = msg.save ?? new Uint8Array();\n"),
}


@unittest.skipUnless(JS, "needs node or bun")
class WorldNodePatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        for rel, text in ANCHORS.items():
            path = self.tmp / "server/engine/src" / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def patch(self):
        return subprocess.run([JS, str(WORLDS / "world-node.js"), str(self.tmp)], capture_output=True, text=True)

    def read(self, rel):
        return (self.tmp / "server/engine/src" / rel).read_text()

    def test_patches_once_and_is_idempotent(self):
        result = self.patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("process.env.AGENT_PORT", self.read("web/websocket.ts"))
        login = self.read("server/login/LoginThread.ts")
        self.assertIn("await worldGuardRefusal(username)", login)
        self.assertIn("WORLD_EXCLUSIVE_LOGIN", login)
        world = self.read("engine/World.ts")
        self.assertIn("worldGuardBackup(username, save)", world)
        self.assertIn("worldGuardWatch(this)", world)
        before = {rel: self.read(rel) for rel in ANCHORS}
        result = self.patch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual({rel: self.read(rel) for rel in ANCHORS}, before)
        self.assertEqual(json.loads(result.stdout)["worldNode"]["engine/World.ts"], "already patched")

    def test_unmatched_upstream_fails_without_running_unguarded(self):
        (self.tmp / "server/engine/src/engine/World.ts").write_text("import fs from 'fs';\n")
        result = self.patch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("review upstream", result.stderr)


class ScriptTests(unittest.TestCase):
    def test_entrypoint_refuses_world_1s_node_and_local_login(self):
        text = (WORLDS / "world-entrypoint.sh").read_text()
        self.assertIn('"$NODE_ID" != 10', text)
        self.assertIn('EASY_STARTUP:-}" == false && "${LOGIN_SERVER:-}" == true', text)
        self.assertNotIn("sqlite:migrate", text)
        self.assertLess(text.index("world-node.js"), text.index("exec bun run src/app.ts"))

    def test_world_sh_never_starts_or_stops_world_1_outside_promote(self):
        text = (SCAPE / "world.sh").read_text()
        self.assertIn("world 1 is the main stack", text)
        self.assertIn("world 1 goes down only through maintenance.sh or promote", text)
        # promote --now is the only countdown on rs-sdk-server and it takes maintenance's lock.
        self.assertEqual(len(re.findall(r'"\$MAIN_CONTAINER" \\\n\s+bun -e', text)), 1)
        self.assertIn('flock -n "$LOCK_FD" || die "maintenance is running', text)

    def test_shellcheck(self):
        if not shutil.which("shellcheck"):
            self.skipTest("shellcheck not installed")
        result = subprocess.run(["shellcheck", str(SCAPE / "world.sh"), str(WORLDS / "world-entrypoint.sh"),
                                 str(WORLDS / "isolated-copy.sh")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)


HOP_LINE = ("                                const remaining = new Date(account.logout_time).getTime()"
            " - new Date(Date.now() - Environment.node.hopTime).getTime();\n")


@unittest.skipUnless(JS, "needs node or bun")
class HopTimerPatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.file = self.tmp / "server/engine/src/server/login/LoginServer.ts"
        self.file.parent.mkdir(parents=True)
        self.file.write_text(HOP_LINE)

    def patch(self):
        return subprocess.run([JS, str(ROOT / "rs-sdk/hop-timer-utc.js"), str(self.tmp)], capture_output=True, text=True)

    def test_reads_the_stored_utc_text_as_utc_and_is_idempotent(self):
        self.assertEqual(self.patch().returncode, 0)
        patched = self.file.read_text()
        self.assertIn("computer-setup: hop-timer-utc.js", patched)
        self.assertEqual(self.patch().returncode, 0)
        self.assertEqual(self.file.read_text(), patched)
        expression = patched.split("const remaining = ", 1)[1].split(" - new Date(Date.now()", 1)[0].rsplit(".getTime()", 1)[0]
        probe = ("const account = { logout_time: '2026-10-26 20:17:26' };"
                 f"console.log(JSON.stringify([{expression}.toISOString(),"
                 " (() => { account.logout_time = new Date('2026-10-26T20:17:26Z'); return " + expression + ".toISOString(); })()]));")
        result = subprocess.run([JS, "-e", probe], capture_output=True, text=True,
                                env={"TZ": "America/Los_Angeles", "PATH": "/usr/bin:/bin:" + str(Path(JS).parent)})
        self.assertEqual(json.loads(result.stdout), ["2026-10-26T20:17:26.000Z"] * 2, result.stderr)

    def test_unknown_upstream_fails_the_build(self):
        self.file.write_text("const remaining = 0;\n")
        result = self.patch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("review upstream", result.stderr)

    def test_wired_into_the_image(self):
        dockerfile = (ROOT / "rs-sdk/Dockerfile").read_text()
        self.assertIn("COPY hop-timer-utc.js", dockerfile)
        self.assertIn("bun /usr/local/lib/hop-timer-utc.js /opt", dockerfile)


if __name__ == "__main__":
    unittest.main()
