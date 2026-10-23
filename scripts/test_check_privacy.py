"""Tests for scripts/check-privacy.py: what it flags, what it lets through, and
that it never prints a matched value."""
import os
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parent / "check-privacy.py"
SPEC = importlib.util.spec_from_file_location("privacy_check", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)

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
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True).stdout.decode()

    def check(self, *args, denylist="", stdin=None):
        return subprocess.run(["python3", str(SCRIPT), *args], cwd=self.root, capture_output=True,
                              text=True, input=stdin, env={**self.env, "PRIVACY_DENYLIST": denylist})

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

    def test_denylist_diagnostics_reveal_no_prefix_or_length(self):
        secret_host = "zephyrbox"
        result = self.check("--file", str(self.write("draft.md", [f"backed up from {secret_host} nightly"])),
                            denylist=f"# comment\n{secret_host}\nab\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("denylist entry", result.stdout)
        self.assertNotIn(secret_host[:3], result.stdout + result.stderr)
        self.assertNotIn("9ch", result.stdout + result.stderr)
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

    def test_owner_exemption_is_scoped_to_origin_repo_links(self):
        for text in ["owner-handle", "https://github.com/owner-handle/other",
                     "https://example.com/owner-handle/repo",
                     "https://github.com/owner-handle/repository"]:
            with self.subTest(text=text):
                result = self.check("--file", str(self.write("draft.md", [text])),
                                    denylist="owner-handle")
                self.assertEqual(result.returncode, 1)
        result = self.check("--file", str(self.write("draft.md", [
            "https://github.com/owner-handle/repo/issues/1"])), denylist="owner-handle")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_owner_exemption_rejects_repo_name_suffixes(self):
        result = self.check("--file", str(self.write("draft.md", [
            "https://github.com/owner-handle/repo.evil/issues"])), denylist="owner-handle")
        self.assertEqual(result.returncode, 1)

    def test_denylisted_ips_use_canonical_exact_addresses(self):
        for text, entry, expected in [
            ("192.0.2.100", "192.0.2.10", False),
            ("[2001:0DB8:0:0:0:0:0:1]:443", "2001:db8::1", True),
            ("2001:db8::1/64", "2001:0db8:0:0:0:0:0:1", True),
            ("2001:db8::10", "2001:db8::1", False),
        ]:
            with self.subTest(text=text):
                self.assertEqual(bool(SCANNER.check_line(text, [entry])), expected)

    def test_denylisted_ip_addresses_in_urls_and_sentences(self):
        for text in ["https://192.0.2.10:443/", "connect 192.0.2.10.",
                     "connect 2001:db8::1."]:
            with self.subTest(text=text):
                self.assertTrue(SCANNER.check_line(text, ["192.0.2.10", "2001:db8::1"]))

    def test_ipv4_mapped_ipv6_matches_canonical_inventory(self):
        self.assertTrue(SCANNER.check_line('[::ffff:192.0.2.10]:443', ['192.0.2.10']))
        self.assertTrue(SCANNER.check_line('192.0.2.10', ['::ffff:192.0.2.10']))
        self.assertTrue(SCANNER.check_line('[::FFFF:C000:020A]:443', ['192.0.2.10']))
        self.assertTrue(SCANNER.check_line('192.0.2.10', ['::ffff:c000:20a']))

    def test_identifier_boundaries_preserve_tailnet_suffix_matching(self):
        for text in ["zephyrboxish", "prefixzephyrbox", "zephyrbox-backup", "zephyrbox_name"]:
            with self.subTest(text=text):
                self.assertEqual(SCANNER.check_line(text, ["zephyrbox"]), [])
        self.assertTrue(SCANNER.check_line("ssh zephyrbox.local", ["zephyrbox"]))
        self.assertTrue(SCANNER.check_line("ssh box.example" + TS, ["example" + TS]))

    def test_reported_paths_redact_private_identifiers(self):
        for name, denylist in [("zephyrbox/draft.md", "zephyrbox"),
                               ("person@" + "gmail.com.md", ""),
                               ("zephyrbox.md", "zephyrbox")]:
            with self.subTest(kind=bool(denylist)):
                result = self.check("--file", str(self.write(name, [LEAKS["email"]])),
                                    denylist=denylist)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("zephyrbox", result.stdout + result.stderr)
                self.assertNotIn("person@", result.stdout + result.stderr)
                if name.endswith("draft.md"):
                    self.assertIn("draft.md:1:", result.stdout)

    def test_no_allow_disables_fixture_marker(self):
        path = self.write("draft.md", [CLEAN[-1]])
        self.assertEqual(self.check("--file", str(path)).returncode, 0)
        result = self.check("--no-allow", "--file", str(path))
        self.assertEqual(result.returncode, 1)
        self.assertIn("IPv4", result.stdout)

    def test_require_denylist_fails_closed_for_absent_or_empty_values(self):
        path = self.write("draft.md", ["fine"])
        for value in ["", "# only comments\nab\n", "zephyrbox"]:
            with self.subTest(has_entries=value == "zephyrbox"):
                result = self.check("--require-denylist", "--file", str(path), denylist=value)
                self.assertEqual(result.returncode, 0 if value == "zephyrbox" else 1)
        (self.root / ".privacy-denylist").write_text("# empty\n")
        result = self.check("--require-denylist", "--file", str(path))
        self.assertEqual(result.returncode, 1)
        self.assertIn("usable denylist", result.stderr)

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

    def test_range_detects_leaks_removed_in_later_commits(self):
        self.write("notes.md", [LEAKS["email"]])
        self.git("add", "notes.md")
        self.git("commit", "-qm", "add note")
        self.git("rm", "-q", "notes.md")
        self.git("commit", "-qm", "remove note")
        result = self.check("--range", "HEAD~2..HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("notes.md:1: email", result.stdout)

    def test_range_checks_author_and_committer_metadata(self):
        for field, value, denylist in [("user.name", "zephyrbox", "zephyrbox"),
                                        ("user.email", "person@" + "gmail.com", "")]:
            with self.subTest(field=field):
                self.git("config", field, value)
                self.git("commit", "--allow-empty", "-qm", "fine")
                result = self.check("--range", "HEAD~1..HEAD", denylist=denylist)
                self.assertEqual(result.returncode, 1)
                self.assertIn("metadata", result.stdout)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.git("config", "user.name", "Test")
                self.git("config", "user.email", "test@example.com")
        self.git("config", "user.email", "public@users.noreply.github.com")
        self.git("commit", "--allow-empty", "-qm", "fine")
        self.assertEqual(self.check("--range", "HEAD~1..HEAD").returncode, 0)

    def test_approved_public_identity_passes_generic_and_denylist_rules(self):
        name = "Ulises Chavarria"
        emails = ["ulises.engineer@gmail.com", "uchavarria@scu.edu"]
        denylist = "\n".join([name, *name.lower().split(), *emails])
        for email in emails:
            with self.subTest(email=email):
                self.git("config", "user.name", name)
                self.git("config", "user.email", email)
                self.git("commit", "--allow-empty", "-qm", "fine")
                result = self.check("--range", "HEAD~1..HEAD", denylist=denylist)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for text in [name, email, f"Contact {name} <{email}>"]:
                    self.assertEqual(SCANNER.check_line(text, denylist.splitlines(),
                                                       no_allow=True), [])

    def test_public_identity_exception_does_not_allow_lookalikes(self):
        name = "Ulises Chavarria"
        emails = ["ulises.engineer@gmail.com", "uchavarria@scu.edu"]
        for value in [name, *emails]:
            for text in [f"prefix{value}", f"{value}.evil", f"{value}-private",
                         f"{value}@example.com", f"{value}+private"]:
                with self.subTest(text=text):
                    self.assertTrue(SCANNER.check_line(text, [*name.lower().split(), value],
                                                       no_allow=True))

    def test_public_identity_exception_preserves_other_privacy_checks(self):
        name = "Ulises Chavarria"
        email = "ulises.engineer@gmail.com"
        identity = "Ulises Chavarria <ulises.engineer@gmail.com>"
        for leak in LEAKS.values():
            with self.subTest(leak=leak):
                self.assertTrue(SCANNER.check_line(f"{identity} {leak}", [], no_allow=True))
        for text in [f"{identity} zephyrbox", f"/home/{name}/projects",
                     f"/Users/{email}/projects", name.lower().split()[0]]:
            with self.subTest(text=text):
                self.assertTrue(SCANNER.check_line(text, ["zephyrbox", *name.lower().split()],
                                                   no_allow=True))

    def test_public_identity_exception_rejects_unicode_lookalikes(self):
        for text in ["Ul\u0131ses Chavarria", "uli\u017fes.engineer@" + "gmail.com",
                     "uchavarr\u0131a@" + "scu.edu"]:
            with self.subTest(text=text):
                self.assertIn("denylist entry", SCANNER.check_line(text, [text], no_allow=True))
        for text in ["\u00e9Ulises Chavarria", "Ulises Chavarria\u00e9"]:
            with self.subTest(text=text):
                self.assertIn("denylist entry", SCANNER.check_line(text, [text], no_allow=True))

    def test_modes_scan_identifying_filenames_even_without_text_hunks(self):
        for name in ["zephyrbox empty.bin", "zephyrbox\tquoted.bin"]:
            (self.root / name).write_bytes(b"\x00\x01")
        self.git("add", ".")
        staged = self.check("--staged", denylist="zephyrbox")
        with self.subTest(mode="staged"):
            self.assertEqual(staged.returncode, 1)
            self.assertNotIn("zephyrbox", staged.stdout + staged.stderr)
        self.git("commit", "-qm", "add assets")
        ranged = self.check("--range", "HEAD~1..HEAD", denylist="zephyrbox")
        with self.subTest(mode="range"):
            self.assertEqual(ranged.returncode, 1)
            self.assertNotIn("zephyrbox", ranged.stdout + ranged.stderr)
        path = self.write("zephyrbox.md", ["fine"])
        result = self.check("--file", str(path), denylist="zephyrbox")
        with self.subTest(mode="file"):
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_range_scans_literal_comment_lines_in_committed_messages(self):
        self.git("-c", "core.commentChar=;", "commit", "--allow-empty", "--cleanup=verbatim",
                 "-qm", "fine\n\n# " + LEAKS["email"])
        result = self.check("--range", "HEAD~1..HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("message:3: email", result.stdout)

    def test_quoted_filenames_do_not_hide_added_content(self):
        self.write("safe\tname.md", [LEAKS["email"]])
        self.git("add", ".")
        for mode, revision in [("--staged", None), ("--range", "HEAD~1..HEAD")]:
            if revision:
                self.git("commit", "-qm", "add note")
            result = self.check(mode, *([revision] if revision else []))
            with self.subTest(mode=mode):
                self.assertEqual(result.returncode, 1)
                self.assertIn("email address", result.stdout)

    def test_git_fsmonitor_is_never_executed(self):
        self.write("safe.md", [LEAKS["email"]])
        self.git("add", "safe.md")
        marker = self.root / "executed"
        hook = self.write("monitor", ["#!/bin/sh", f'touch "{marker}"'])
        hook.chmod(0o700)
        self.git("config", "core.fsmonitor", str(hook))
        result = self.check("--staged")
        self.assertFalse(marker.exists(), "scanner executed repository fsmonitor")
        self.assertEqual(result.returncode, 1)
        self.assertIn("safe.md:1: email", result.stdout)

    def test_git_wrapper_disables_execution_capable_configuration(self):
        for key, expected in [("core.hooksPath", os.devnull), ("core.fsmonitor", "false"),
                              ("core.attributesFile", os.devnull), ("diff.external", ""),
                              ("credential.helper", ""), ("protocol.allow", "never")]:
            with self.subTest(key=key):
                self.git("config", key, "unsafe")
                self.assertEqual(SCANNER.git("-C", str(self.root), "config", "--get", key).strip(),
                                 expected)

    def test_ambient_git_environment_cannot_redirect_the_scan(self):
        self.write("safe.md", [LEAKS["email"]])
        self.git("add", "safe.md")
        for settings in [
            {"GIT_INDEX_FILE": str(self.root / "missing-index")},
            {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "diff.orderFile",
             "GIT_CONFIG_VALUE_0": str(self.root / "missing-order")},
            {"GIT_CONFIG_PARAMETERS": "'diff.orderFile=missing-order'"},
        ]:
            with self.subTest(keys=sorted(settings)):
                self.env = {**os.environ, **settings}
                result = self.check("--staged")
                self.assertEqual(result.returncode, 1)
                self.assertIn("safe.md:1: email", result.stdout)

    def test_git_diff_prefix_configuration_cannot_hide_content(self):
        self.git("config", "diff.noprefix", "true")
        self.write("safe.md", [LEAKS["email"]])
        self.git("add", ".")
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("safe.md:1: email", result.stdout)

    def test_external_diff_and_textconv_cannot_execute_or_hide_leaks(self):
        marker = self.root / "executed"
        driver = self.write("driver", ["#!/bin/sh", f'touch "{marker}"', "printf 'fine\\n'"])
        driver.chmod(0o700)
        self.write(".gitattributes", ["*.md diff=unsafe"])
        self.git("config", "diff.external", str(driver))
        self.git("config", "diff.unsafe.command", str(driver))
        self.git("config", "diff.unsafe.textconv", str(driver))
        self.write("safe.md", [LEAKS["email"]])
        self.git("add", ".gitattributes", "safe.md")
        result = self.check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("safe.md:1: email", result.stdout)
        self.assertFalse(marker.exists())
        self.git("commit", "-qm", "add note")
        result = self.check("--range", "HEAD~1..HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("safe.md:1: email", result.stdout)
        self.assertFalse(marker.exists())

    def test_pre_push_scans_each_outgoing_commit(self):
        base = self.git("rev-parse", "HEAD").strip()
        self.write("note.md", ["zephyrbox"])
        self.git("add", ".")
        self.git("commit", "-qm", "add note")
        self.git("rm", "-q", "note.md")
        self.git("commit", "-qm", "remove note")
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/test {head} refs/heads/test {base}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("denylist entry", result.stdout)
        self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_pre_push_requires_usable_denylist(self):
        result = self.check("--pre-push", stdin="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("usable denylist", result.stderr)

    def test_pre_push_new_branch_scans_even_known_remote_history(self):
        self.write("old.md", ["zephyrbox"])
        self.git("add", ".")
        self.git("commit", "-qm", "existing remote note")
        self.git("update-ref", "refs/remotes/origin/test", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "fine")
        head = self.git("rev-parse", "HEAD").strip()
        record = f"refs/heads/test {head} refs/heads/new {'0' * 40}\n"
        result = self.check("--pre-push", denylist="zephyrbox", stdin=record)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("denylist entry", result.stdout)
        self.write("new.md", ["zephyrbox"])
        self.git("add", ".")
        self.git("commit", "-qm", "new note")
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/test {head} refs/heads/new {'0' * 40}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("denylist entry", result.stdout)

    def test_pre_push_unrelated_private_remote_cannot_hide_a_new_public_leak(self):
        self.write("note.md", ["zephyrbox"])
        self.git("add", "note.md")
        self.git("commit", "-qm", "private note")
        self.git("remote", "add", "private", "https://example.com/private/repo.git")
        self.git("update-ref", "refs/remotes/private/main", "HEAD")
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/main {head} refs/heads/main {'0' * 40}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("note.md:1: denylist entry", result.stdout)
        self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_pre_push_scans_both_local_and_remote_ref_names(self):
        head = self.git("rev-parse", "HEAD").strip()
        for local, remote in [("refs/heads/zephyrbox", "refs/heads/main"),
                              ("refs/heads/main", "refs/heads/zephyrbox"),
                              ("refs/tags/zephyrbox", "refs/tags/release")]:
            with self.subTest(local_private="zephyrbox" in local):
                result = self.check("--pre-push", denylist="zephyrbox",
                                    stdin=f"{local} {head} {remote} {head}\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("ref", result.stdout)
                self.assertIn("denylist entry", result.stdout)
                self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_pre_push_scans_annotated_tag_message_and_tagger(self):
        for field, value in [("message", "zephyrbox"), ("user.name", "zephyrbox"),
                             ("user.email", "person@" + "gmail.com")]:
            with self.subTest(field=field):
                if field != "message":
                    self.git("config", field, value)
                self.git("tag", "--no-sign", "-f", "-a", "release", "-m",
                         value if field == "message" else "fine")
                sha = self.git("rev-parse", "refs/tags/release").strip()
                result = self.check("--pre-push", denylist="zephyrbox",
                                    stdin=f"refs/tags/release {sha} refs/tags/release {'0' * 40}\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("tag", result.stdout)
                self.assertNotIn(value, result.stdout + result.stderr)
                self.git("config", "user.name", "Test")
                self.git("config", "user.email", "test@example.com")

    def test_pre_push_scans_nested_tag_objects(self):
        for field in ["message", "name"]:
            with self.subTest(field=field):
                inner = "zephyrbox" if field == "name" else "inner"
                self.git("tag", "--no-sign", "-f", "-a", inner, "-m",
                         "zephyrbox" if field == "message" else "fine")
                self.git("tag", "--no-sign", "-f", "-a", "outer", inner, "-m", "fine")
                sha = self.git("rev-parse", "refs/tags/outer").strip()
                head = self.git("rev-parse", "HEAD").strip()
                result = self.check("--pre-push", denylist="zephyrbox",
                                    stdin=f"refs/tags/outer {sha} refs/tags/release {head}\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn("tag", result.stdout)
                self.assertIn("denylist entry", result.stdout)
                self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_pre_push_deleted_refs_are_skipped(self):
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"(delete) {'0' * 40} refs/heads/test {head}\n")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pre_push_new_tag_scans_root_commit_and_removed_history(self):
        self.write("README", ["zephyrbox"])
        self.git("add", "README")
        self.git("commit", "--amend", "-qm", "base")
        self.write("README", ["fine"])
        self.git("add", "README")
        self.git("commit", "-qm", "remove note")
        self.git("tag", "--no-sign", "-a", "release", "-m", "fine")
        sha = self.git("rev-parse", "refs/tags/release").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/tags/release {sha} refs/tags/release {'0' * 40}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("README:1: denylist entry", result.stdout)
        self.assertNotIn("zephyrbox", result.stdout + result.stderr)

    def test_pre_push_known_destination_excludes_only_its_provided_history(self):
        self.write("note.md", ["zephyrbox"])
        self.git("add", "note.md")
        self.git("commit", "-qm", "existing destination note")
        base = self.git("rev-parse", "HEAD").strip()
        self.git("commit", "--allow-empty", "-qm", "fine")
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/main {head} refs/heads/main {base}\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_pre_push_unknown_nonzero_destination_object_fails_closed(self):
        head = self.git("rev-parse", "HEAD").strip()
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/main {head} refs/heads/main {'1' * 40}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_input_failures_never_echo_private_paths_or_values(self):
        for args, stdin in [
            (("--file", str(self.root / "zephyrbox-missing.md")), None),
            (("--range", "zephyrbox..HEAD"), None),
            (("--pre-push",), "refs/heads/test zephyrbox refs/heads/test invalid\n"),
        ]:
            with self.subTest(mode=args[0]):
                result = self.check(*args, denylist="zephyrbox", stdin=stdin)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn("zephyrbox", result.stdout + result.stderr)
                self.assertNotIn("Traceback", result.stdout + result.stderr)
                self.assertIn("error:", result.stderr)

    def test_pre_push_rejects_non_object_ids(self):
        base = self.git("rev-parse", "HEAD").strip()
        self.git("commit", "--allow-empty", "-qm", "fine")
        result = self.check("--pre-push", denylist="zephyrbox",
                            stdin=f"refs/heads/test HEAD refs/heads/test {base}\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stderr)

    def test_range_checks_commit_messages(self):
        self.write("ok.md", ["fine"])
        self.git("add", "ok.md")
        self.git("commit", "-qm", "deploy to " + LEAKS["private IPv4"])
        result = self.check("--range", "HEAD~1..HEAD")
        self.assertEqual(result.returncode, 1)
        self.assertIn("message:1: private or tailnet IPv4", result.stdout)

    def test_allow_marker_cannot_hide_denylist_or_secrets(self):
        for text, denylist in [("fixture-host", "fixture-host"), (LEAKS["token"], ""),
                               (LEAKS["private key"], ""), (LEAKS["webhook"], "")]:
            with self.subTest(kind=text[:4]):
                result = self.check("--file", str(self.write("draft.md", [
                    text + " # privacy-check: allow"])), denylist=denylist)
                self.assertEqual(result.returncode, 1)

    def test_file_comments_are_scanned(self):
        result = self.check("--file", str(self.write("draft.md", ["# " + LEAKS["email"]])))
        self.assertEqual(result.returncode, 1)

    def test_commit_message_comments_are_skipped(self):
        msg = self.write("MSG", ["fix: thing", "# " + LEAKS["email"]])
        self.assertEqual(self.check("--message", str(msg)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
