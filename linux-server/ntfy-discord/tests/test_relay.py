import importlib.util
import io
import json
import sqlite3
import tempfile
import threading
import time
import unittest
from contextlib import nullcontext
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "relay.py"
SPEC = importlib.util.spec_from_file_location("relay", MODULE_PATH)
relay = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(relay)

HOOK = "https://discord.com/api/webhooks/123/abc_DEF-1"
NOW = 1_800_000_000


def message(message_id, topic, **extra):
    return json.dumps({"event": "message", "id": message_id, "topic": topic, "time": NOW, **extra}).encode()


class FakeDiscord:
    def __init__(self, responses):
        self.responses = list(responses)
        self.bodies = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                fake.bodies.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                status, body = fake.responses.pop(0) if fake.responses else (204, b"")
                self.send_response(status)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/hook"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class RawDiscord:
    """Serves each POST with the next scripted handler, then 204."""

    def __init__(self, scripts):
        self.scripts = list(scripts)
        self.requests = 0
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                fake.requests += 1
                if fake.scripts:
                    fake.scripts.pop(0)(self)
                    return
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}/hook"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class RelayTests(unittest.TestCase):
    def config(self, directory, **webhooks):
        return {
            "base": "https://ntfy.example",
            "topics": ["server-backup", "game-dragonwilds"],
            "webhooks": webhooks or {"server": "S", "game": "G", "pi": "P"},
            "token": "",
            "state_file": Path(directory) / "last-id",
        }

    def test_routes_by_prefix_and_saves_position(self):
        sent = []
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(directory)
            lines = [
                b'{"event":"open"}',
                message("a1", "server-backup", title="Backup FAILED", priority=5),
                b'{"event":"keepalive"}',
                message("a2", "game-dragonwilds", message="Build 2 is out"),
                message("a3", "pi-backup"),
                message("a4", "other-topic"),
            ]
            last = relay.relay_events(lines, config, None, lambda url, body: sent.append((url, body)) or True,
                                      now=lambda: NOW)
            self.assertEqual(last, "a4")
            self.assertEqual(relay.read_state(config["state_file"]), "a4")
        self.assertEqual([url for url, _ in sent], ["S", "G", "P"])
        first = sent[0][1]["embeds"][0]
        self.assertEqual(first["title"], "Backup FAILED")
        self.assertEqual(first["color"], relay.COLORS[5])
        self.assertEqual(first["footer"]["text"], "server-backup")
        self.assertEqual(sent[0][1]["allowed_mentions"], {"parse": []})
        self.assertEqual(sent[1][1]["embeds"][0]["title"], "game-dragonwilds")

    def test_default_webhook_catches_unknown_prefix(self):
        self.assertEqual(relay.webhook_for("other-x", {"default": "D"}), "D")
        self.assertIsNone(relay.webhook_for("other-x", {"server": "S"}))
        self.assertEqual(relay.webhook_for("nas-backup", {"nas": "N", "default": "D"}), "N")
        self.assertEqual(relay.webhook_for("mac-backup", {"mac": "M", "default": "D"}), "M")

    def test_stale_messages_are_skipped_after_an_outage(self):
        sent = []
        with tempfile.TemporaryDirectory() as directory:
            last = relay.relay_events(
                [message("old", "server-backup")], self.config(directory), None,
                lambda url, body: sent.append(url) or True,
                now=lambda: NOW + relay.MAX_MESSAGE_AGE_SECONDS + 1,
            )
        self.assertEqual(sent, [])
        self.assertEqual(last, "old")

    def test_resume_url_carries_last_id(self):
        with tempfile.TemporaryDirectory() as directory:
            url = relay.stream_url(self.config(directory), "a4")
        self.assertEqual(url, "https://ntfy.example/server-backup,game-dragonwilds/json?since=a4")

    def test_main_reconnects_after_yield_then_error_from_latest_position(self):
        for initial in (None, "old1"):
            for save_fails in (False, True):
                with self.subTest(initial=initial, save_fails=save_fails), tempfile.TemporaryDirectory() as directory:
                    config = self.config(directory)
                    config["cache_db"] = ""
                    if initial:
                        config["state_file"].write_text(initial)

                    requests = []
                    sent = []

                    class Stream:
                        def __enter__(self):
                            return self

                        def __exit__(self, *args):
                            return False

                        def __iter__(self):
                            yield message("new2", "server-backup")
                            raise OSError("stream interrupted")

                    def open_stream(request, **kwargs):
                        requests.append(request.full_url)
                        if len(requests) == 2:
                            raise KeyboardInterrupt
                        return Stream()

                    real_events = relay.relay_events

                    def events(*args, **kwargs):
                        return real_events(*args, **kwargs, send=lambda url, body: sent.append(url) or True,
                                           now=lambda: NOW)

                    with patch.object(relay, "load_config", return_value=config), \
                            patch.object(relay.urllib.request, "urlopen", side_effect=open_stream), \
                            patch.object(relay, "relay_events", side_effect=events), \
                            patch.object(relay.time, "sleep"), patch.object(relay, "log") as logs, \
                            (patch.object(relay.os, "replace", side_effect=OSError("checkpoint failed"))
                             if save_fails else nullcontext()):
                        with self.assertRaises(KeyboardInterrupt):
                            relay.main()
                    base = "https://ntfy.example/server-backup,game-dragonwilds/json"
                    self.assertEqual(requests, [base + ("?since=old1" if initial else ""), base + "?since=new2"])
                    self.assertEqual(sent, ["S"])
                    if save_fails:
                        self.assertEqual(relay.read_state(config["state_file"]), initial)
                        self.assertTrue(any("cannot save relay position" in call.args[0] for call in logs.call_args_list))
                    else:
                        self.assertEqual(config["state_file"].read_text(), "new2\n")

    def test_delivery_honours_rate_limit_then_succeeds(self):
        discord = FakeDiscord([(429, b'{"retry_after": 0.25}'), (204, b"")])
        sleeps = []
        try:
            self.assertTrue(relay.deliver(discord.url, {"content": "x"}, sleep=sleeps.append))
        finally:
            discord.close()
        self.assertEqual(sleeps, [0.5])
        self.assertEqual(len(discord.bodies), 2)

    def test_excessive_rate_limit_drops_and_next_stream_message_proceeds(self):
        for value in (61, 600, 1e30, 1e308, "1e30"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                error = relay.urllib.error.HTTPError(
                    HOOK, 429, "limited", {},
                    io.BytesIO(json.dumps({"retry_after": value}).encode()))
                results = []
                elapsed = [100.0]

                def sleep(delay):
                    elapsed[0] += delay
                    self.fail("an excessive retry_after must be dropped, not slept or retried early")

                def send(url, payload):
                    result = relay.deliver(url, payload, sleep=sleep)
                    results.append(result)
                    return result

                config = self.config(directory, server=HOOK)
                with patch.object(relay.time, "monotonic", side_effect=lambda: elapsed[0]), \
                        patch.object(relay.urllib.request, "urlopen",
                                     side_effect=[error, nullcontext()]) as opened, \
                        patch.object(relay, "log") as logs:
                    last = relay.relay_events(
                        [message("first", "server-backup"), message("next", "server-backup")],
                        config, None, send=send, now=lambda: NOW)
                self.assertEqual(results, [False, True])
                self.assertEqual(opened.call_count, 2)
                self.assertEqual(last, "next")
                self.assertEqual(relay.read_state(config["state_file"]), "next")
                self.assertTrue(any("dropping" in call.args[0] for call in logs.call_args_list))

    def test_client_error_is_dropped_without_retry(self):
        discord = FakeDiscord([(400, b"{}")])
        try:
            self.assertFalse(relay.deliver(discord.url, {"content": "x"}, sleep=lambda _: None))
        finally:
            discord.close()
        self.assertEqual(len(discord.bodies), 1)

    def test_rate_limits_wait_full_requested_delays_before_retry(self):
        elapsed = [100.0]
        attempts = []
        sleeps = []

        def opened(request, **kwargs):
            attempts.append(elapsed[0])
            if len(attempts) <= 2:
                raise relay.urllib.error.HTTPError(
                    HOOK, 429, "limited", {}, io.BytesIO(b'{"retry_after": 20}'))
            return nullcontext()

        def sleep(delay):
            sleeps.append(delay)
            elapsed[0] += delay

        with patch.object(relay.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(relay.urllib.request, "urlopen", side_effect=opened):
            self.assertTrue(relay.deliver(HOOK, {"content": "x"}, sleep=sleep))
        self.assertEqual(sleeps, [20, 20])
        self.assertEqual(attempts, [100, 120, 140])

    def test_repeated_rate_limits_share_one_delivery_budget(self):
        elapsed = [0.0]
        sleeps = []

        def opened(request, **kwargs):
            raise relay.urllib.error.HTTPError(
                HOOK, 429, "limited", {}, io.BytesIO(b'{"retry_after": 25}'))

        def sleep(delay):
            sleeps.append(delay)
            elapsed[0] += delay

        with patch.object(relay.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(relay.urllib.request, "urlopen", side_effect=opened) as requests, \
                patch.object(relay, "log") as logs:
            self.assertFalse(relay.deliver(HOOK, {"content": "x"}, sleep=sleep))
        self.assertEqual(requests.call_count, 3)
        self.assertEqual(sleeps, [25, 25])
        self.assertLessEqual(elapsed[0], relay.DELIVERY_BUDGET_SECONDS)
        self.assertIn("delivery budget", logs.call_args.args[0])

    def test_request_time_counts_towards_budget_and_bounds_next_timeout(self):
        elapsed = [0.0]
        timeouts = []

        def opened(request, timeout):
            timeouts.append(timeout)
            elapsed[0] += timeout
            raise relay.urllib.error.HTTPError(
                HOOK, 429, "limited", {}, io.BytesIO(b'{"retry_after": 10}'))

        def sleep(delay):
            elapsed[0] += delay

        with patch.object(relay.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(relay.urllib.request, "urlopen", side_effect=opened), \
                patch.object(relay, "log"):
            self.assertFalse(relay.deliver(HOOK, {"content": "x"}, sleep=sleep))
        self.assertEqual(timeouts, [15, 15, 10])
        self.assertEqual(elapsed[0], relay.DELIVERY_BUDGET_SECONDS)

    def test_server_errors_retry_then_give_up(self):
        discord = FakeDiscord([(502, b"")] * relay.DELIVERY_ATTEMPTS)
        try:
            self.assertFalse(relay.deliver(discord.url, {"content": "x"}, sleep=lambda _: None))
        finally:
            discord.close()
        self.assertEqual(len(discord.bodies), relay.DELIVERY_ATTEMPTS)

    def test_invalid_rate_limit_deadlines_use_safe_fallback(self):
        bodies = [json.dumps({"retry_after": value}).encode()
                  for value in (None, "NaN", "Infinity", "-Infinity", {}, [], -1, "bad")]
        bodies += [b"not json", b"[]", b"null", b'{"retry_after": 1e999}']
        for body in bodies:
            with self.subTest(body=body):
                elapsed = [0.0]
                sleeps = []

                def sleep(delay):
                    sleeps.append(delay)
                    elapsed[0] += delay

                error = relay.urllib.error.HTTPError(HOOK, 429, "limited", {}, io.BytesIO(body))
                with patch.object(relay.time, "monotonic", side_effect=lambda: elapsed[0]), \
                        patch.object(relay.urllib.request, "urlopen",
                                     side_effect=[error, nullcontext()]) as requests:
                    self.assertTrue(relay.deliver(HOOK, {"content": "x"}, sleep=sleep))
                self.assertEqual(sleeps, [1.0])
                self.assertEqual(requests.call_count, 2)

    def test_slow_rate_limit_body_cannot_exceed_the_delivery_budget(self):
        def trickle(handler):
            handler.send_response(429)
            handler.send_header("Content-Length", "40")
            handler.end_headers()
            for _ in range(40):
                handler.wfile.write(b" ")
                handler.wfile.flush()
                time.sleep(0.05)

        discord = RawDiscord([trickle])
        try:
            with patch.object(relay, "DELIVERY_BUDGET_SECONDS", 0.3), patch.object(relay, "log") as logs:
                started = time.monotonic()
                self.assertFalse(relay.deliver(discord.url, {"content": "x"}, sleep=lambda _: None))
                elapsed = time.monotonic() - started
        finally:
            discord.close()
        self.assertLess(elapsed, 1.0)
        self.assertTrue(any("delivery budget" in call.args[0] for call in logs.call_args_list))

    def test_truncated_rate_limit_body_is_retried(self):
        def truncated(handler):
            handler.send_response(429)
            handler.send_header("Content-Length", "100")
            handler.end_headers()
            handler.wfile.write(b'{"retry')
            handler.close_connection = True

        discord = RawDiscord([truncated])
        sleeps = []
        try:
            with patch.object(relay, "log"):
                self.assertTrue(relay.deliver(discord.url, {"content": "x"}, sleep=sleeps.append))
        finally:
            discord.close()
        self.assertEqual(discord.requests, 2)
        self.assertEqual(sleeps, [1])

    def test_rate_limit_body_timeout_lets_the_stream_advance(self):
        class TimingOutBody(io.RawIOBase):
            def readable(self):
                return True

            def readinto(self, buffer):
                raise TimeoutError("429 body timed out")

        def limited():
            return relay.urllib.error.HTTPError(HOOK, 429, "limited", {}, io.BufferedReader(TimingOutBody()))

        with tempfile.TemporaryDirectory() as directory:
            config = self.config(directory, server=HOOK)
            with patch.object(relay.urllib.request, "urlopen",
                              side_effect=[limited(), nullcontext(), nullcontext()]) as opened, \
                    patch.object(relay.time, "sleep"), patch.object(relay, "log"):
                last = relay.relay_events(
                    [message("first", "server-backup"), message("next", "server-backup")],
                    config, None, now=lambda: NOW)
            self.assertEqual(opened.call_count, 3)
            self.assertEqual(last, "next")
            self.assertEqual(relay.read_state(config["state_file"]), "next")

    def test_config_validates_inputs(self):
        good = {"NTFY_URL": "https://ntfy.example/", "RELAY_TOPICS": "server-backup, game-backup",
                "DISCORD_WEBHOOK_GAME": HOOK}
        config = relay.load_config(good)
        self.assertEqual(config["base"], "https://ntfy.example")
        self.assertEqual(config["topics"], ["server-backup", "game-backup"])
        self.assertEqual(config["webhooks"], {"game": HOOK})
        for bad in (
            {**good, "NTFY_URL": "ntfy.example"},
            {**good, "RELAY_TOPICS": "server-backup,../x"},
            {**good, "DISCORD_WEBHOOK_GAME": "https://evil.example/api/webhooks/1/x"},
            {key: value for key, value in good.items() if key != "DISCORD_WEBHOOK_GAME"},
        ):
            with self.assertRaises(SystemExit):
                relay.load_config(bad)

    def test_unreadable_state_starts_fresh(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "last-id"
            self.assertIsNone(relay.read_state(path))
            path.write_text("../../etc\n")
            self.assertIsNone(relay.read_state(path))


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.db = Path(self.dir.name) / "cache.db"
        with sqlite3.connect(self.db) as db:
            db.execute("CREATE TABLE messages (mid TEXT, time INT, topic TEXT, message TEXT)")
            db.executemany("INSERT INTO messages VALUES (?, ?, ?, '')", [
                ("a", NOW - 10, "server-backup"), ("b", NOW - 5, "server-backup"),
                ("c", NOW, "mac-runner"), ("d", NOW, "../evil"),
            ])
        self.config = {
            "topics": ["server-backup", "ups-power"],
            "webhooks": {"server": "S", "mac": "M"},
            "cache_db": str(self.db),
            "audit_state_file": Path(self.dir.name) / "unrelayed-topics",
        }
        self.sent = []

    def tearDown(self):
        self.dir.cleanup()

    def send(self, url, payload):
        self.sent.append((url, payload))
        return True

    def test_reads_cached_topics_read_only_and_ignores_invalid_names(self):
        self.assertEqual(relay.cached_topics(str(self.db)), {"server-backup": (2, NOW - 5), "mac-runner": (1, NOW)})

    def test_flags_unlisted_and_unroutable_topics(self):
        findings = relay.run_audit(self.config, send=self.send)
        self.assertEqual(findings, {"mac-runner": "not in RELAY_TOPICS",
                                    "ups-power": "in RELAY_TOPICS but no webhook matches its prefix"})
        self.assertEqual(len(self.sent), 1)
        url, payload = self.sent[0]
        self.assertEqual(url, "S")
        text = payload["embeds"][0]["description"]
        self.assertIn("`mac-runner`: not in RELAY_TOPICS (1 message", text)
        self.assertIn("RELAY_TOPICS", text)
        self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_alerts_once_per_new_topic(self):
        relay.run_audit(self.config, send=self.send)
        relay.run_audit(self.config, send=self.send)
        self.assertEqual(len(self.sent), 1)
        with sqlite3.connect(self.db) as db:
            db.execute("INSERT INTO messages VALUES ('e', ?, 'game-new', '')", (NOW,))
        relay.run_audit(self.config, send=self.send)
        self.assertEqual(len(self.sent), 2)

    def test_failed_delivery_retries_next_time(self):
        relay.run_audit(self.config, send=lambda url, payload: False)
        relay.run_audit(self.config, send=self.send)
        self.assertEqual(len(self.sent), 1)

    def test_clean_cache_sends_nothing(self):
        self.config["topics"] = ["server-backup", "mac-runner"]
        self.assertEqual(relay.run_audit(self.config, send=self.send), {})
        self.assertEqual(self.sent, [])

    def add_large_audit(self):
        with sqlite3.connect(self.db) as db:
            db.executemany("INSERT INTO messages VALUES (?, ?, ?, '')", [
                (f"extra{i}", NOW, f"extra-{i:03d}-" + "x" * 54) for i in range(120)
            ])

    def assert_complete_report(self, findings):
        descriptions = [payload["embeds"][0]["description"] for _, payload in self.sent]
        self.assertGreater(len(descriptions), 1)
        for text in descriptions:
            self.assertLessEqual(len(text), 4000)
            self.assertIn("then `docker compose up -d`.", text)
        for topic in findings:
            self.assertEqual(sum(f"`{topic}`:" in text for text in descriptions), 1)
            self.assertTrue(any(f"`{topic}`: {findings[topic]} (" in text for text in descriptions))

    def test_large_audit_reports_every_topic_before_acknowledging(self):
        self.add_large_audit()
        with patch.object(relay, "log"):
            findings = relay.run_audit(self.config, send=self.send)
        self.assert_complete_report(findings)
        self.assertEqual(set(self.config["audit_state_file"].read_text().split()), set(findings))

    def test_partial_audit_delivery_retries_complete_report(self):
        self.add_large_audit()
        path = self.config["audit_state_file"]
        path.write_text("mac-runner\n")

        def fail_second(url, payload):
            self.sent.append((url, payload))
            return len(self.sent) < 2

        with patch.object(relay, "log"):
            relay.run_audit(self.config, send=fail_second)
            self.assertEqual(len(self.sent), 2)
            self.assertEqual(path.read_text(), "mac-runner\n")
            self.sent.clear()
            findings = relay.run_audit(self.config, send=self.send)
            self.assert_complete_report(findings)
            self.assertEqual(set(path.read_text().split()), set(findings))
            self.sent.clear()
            relay.run_audit(self.config, send=self.send)
            self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
