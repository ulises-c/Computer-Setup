"""Tests for scripts/check-privacy.py: what it flags, what it lets through, and
that it never prints a matched value."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "check-privacy.py"

# Assembled from parts so this file does not trip the check (or other scanners) itself.
TS = "." + "ts" + ".net"
LEAKS = {
    "tailnet hostname": f"ssh admin@" + f"box.tail{'0abc12'}{TS}",
    "private IPv4": "server at 192.168." + "1.42",
    "tailnet IPv4": "tailscale ip 100.101." + "102.103",
    "email": "contact person@" + "gmail.com",
    "home path": "cd /home/" + "alice/projects",
    "MAC": "mac 3c:22:fb:" + "01:02:03",
    "private key": "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
    "token": "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789",
    "webhook": "https://discord.com/api/" + "webhooks/123456789/abcdefghijklmnopqrstuvwxyz012345",
}
CLEAN = [
    f"ssh <username>@<hostname>.<tailnet>{TS}",
    f"https://example{TS} and user@example.com, ops@acme.example, a@b.test",
    "pools 172.16.0.0/12 192.168.0.0 gateway 172.17.0.1 MagicDNS 100.100.100.100",
    "documentation addresses 192.0.2.10 and 198.51.100.7",
    "brew install python@3.12; systemctl status nut-monitor@cyberpower.service",
    "git@github.com:org/repo.git and noreply@github.com",
    "cd $HOME/projects, /home/runner/work, /Users/Shared",
    "a known LAN host 192.168." + "1.5  # privacy-check: allow",
]


class PrivacyCheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.env = {**os.environ, "PRIVACY_DENYLIST": ""}
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.git("config", "commit.gpgsign", "false")
        self.git("remote", "add", "origin", "git@github.com:owner-handle/repo.git")
        (self.root / "README").write_text("base\n")
        self.git("add", "README")
        self.git("commit", "-qm", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def check(self, *args, denylist=""):
        return subprocess.run(["python3", str(SCRIPT), *args], cwd=self.root, capture_output=True,
                              text=True, env={**self.env, "PRIVACY_DENYLIST": denylist})

    def write(self, name, lines):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n")
        return path

    def test_each_leak_is_flagged_without_printing_it(self):
        for name, line in LEAKS.items():
            with self.subTest(name=name):
                result = self.check("--file", str(self.write("draft.md", [line])))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("draft.md:1:", result.stdout)
                for token in line.split():
                    if len(token) > 6 and not token.startswith("-----"):
                        self.assertNotIn(token, result.stdout + result.stderr)

    def test_placeholders_and_well_known_values_pass(self):
        result = self.check("--file", str(self.write("draft.md", CLEAN)))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_denylist_hit_shows_only_length_and_prefix(self):
        secret_host = "zephyrbox"
        result = self.check("--file", str(self.write("draft.md", [f"backed up from {secret_host} nightly"])),
                            denylist=f"# comment\n{secret_host}\nab\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("denylist entry (9ch, zep…)", result.stdout)
        self.assertNotIn(secret_host, result.stdout + result.stderr)

    def test_denylist_file_is_read_and_short_entries_ignored(self):
        (self.root / ".privacy-denylist").write_text("zephyrbox\nab\n")
        result = self.check("--file", str(self.write("draft.md", ["zephyrbox", "ab cd"])))
        self.assertEqual(result.stdout.count("denylist entry"), 1)

    def test_repo_owner_handle_is_not_a_username_leak(self):
        result = self.check("--file", str(self.write("draft.md", [
            "see https://github.com/owner-handle/repo/issues/1"])), denylist="owner")
        self.assertEqual(result.returncode, 0, result.stdout)
        result = self.check("--file", str(self.write("draft.md", ["the owner box"])), denylist="owner")
        self.assertEqual(result.returncode, 1)

    def test_missing_denylist_is_reported(self):
        result = self.check("--file", str(self.write("draft.md", ["fine"])))
        self.assertEqual(result.returncode, 0)
        self.assertIn("were not checked", result.stderr)

    def test_staged_checks_only_added_lines(self):
        self.write("notes.md", ["old line " + LEAKS["private IPv4"]])
        self.git("add", "notes.md")
        self.git("commit", "-qm", "existing text")
        self.write("notes.md", ["old line " + LEAKS["private IPv4"], "new line", LEAKS["email"]])
        self.git("add", "notes.md")
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines()[0], "notes.md:3: email address (use example.com)")
        self.assertEqual(result.stdout.count("notes.md:"), 1)

    def test_fixture_addresses_are_allowed_in_tests_only(self):
        line = 'print("10.0.' + '0.5")'
        self.write("tests/test_x.py", [line])
        self.write("tool.py", [line])
        self.git("add", ".")
        result = self.check("--staged")
        self.assertNotIn("tests/test_x.py", result.stdout)
        self.assertIn("tool.py:1:", result.stdout)

    def test_range_checks_commit_messages(self):
        self.write("ok.md", ["fine"])
        self.git("add", "ok.md")
        self.git("commit", "-qm", "deploy to " + LEAKS["private IPv4"])
        result = self.check("--range", "HEAD~1..HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("message:1: private or tailnet IPv4", result.stdout)

    def test_commit_message_comments_are_skipped(self):
        msg = self.write("MSG", ["fix: thing", "# " + LEAKS["email"]])
        self.assertEqual(self.check("--message", str(msg)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
