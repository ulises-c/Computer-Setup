import importlib.util
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

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

    def test_delivery_honours_rate_limit_then_succeeds(self):
        discord = FakeDiscord([(429, b'{"retry_after": 0.25}'), (204, b"")])
        sleeps = []
        try:
            self.assertTrue(relay.deliver(discord.url, {"content": "x"}, sleep=sleeps.append))
        finally:
            discord.close()
        self.assertEqual(sleeps, [0.5])
        self.assertEqual(len(discord.bodies), 2)

    def test_client_error_is_dropped_without_retry(self):
        discord = FakeDiscord([(400, b"{}")])
        try:
            self.assertFalse(relay.deliver(discord.url, {"content": "x"}, sleep=lambda _: None))
        finally:
            discord.close()
        self.assertEqual(len(discord.bodies), 1)

    def test_server_errors_retry_then_give_up(self):
        discord = FakeDiscord([(502, b"")] * relay.DELIVERY_ATTEMPTS)
        try:
            self.assertFalse(relay.deliver(discord.url, {"content": "x"}, sleep=lambda _: None))
        finally:
            discord.close()
        self.assertEqual(len(discord.bodies), relay.DELIVERY_ATTEMPTS)

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


if __name__ == "__main__":
    unittest.main()
