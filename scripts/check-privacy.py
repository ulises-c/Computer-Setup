#!/usr/bin/env python3
"""Flag identifying or secret values before they reach this public repo.

Checks added lines (not whole files) so existing, reviewed text does not
re-trigger, plus commit messages. Two layers:

* Patterns that need no private knowledge: tailnet names, private/tailnet
  IPv4 addresses, personal emails, home paths, MAC addresses, tokens, keys.
* A private denylist of the real values (hostnames, tailnet, usernames, ...):
  `.privacy-denylist` at the repo root (gitignored), or the PRIVACY_DENYLIST
  environment variable in CI. One value per line, `#` comments allowed. The
  repo owner's public handle (from the origin URL) is ignored, so a username
  that is part of it does not flag every link to this repo.

A hit is reported as path:line and the check name. The matched text is never
printed, so running the check cannot itself leak the value into a log.

Usage:
  check-privacy.py --staged             staged changes (pre-commit)
  check-privacy.py --message FILE       a commit message (commit-msg hook)
  check-privacy.py --range BASE..HEAD   added lines and commit messages (CI)
  check-privacy.py --file PATH...       whole files, e.g. a PR body draft
"""
import argparse
import ipaddress
import os
import re
import subprocess
import sys

ALLOW_MARKER = "privacy-check: allow"
DENYLIST_FILE = ".privacy-denylist"

TAILNET_HOST = re.compile(r"([A-Za-z0-9-]+)\.ts\.net\b")
TAILNET_ID = re.compile(r"\btail[0-9a-f]{6}\b")
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])(/\d{1,2})?")
EMAIL = re.compile(r"\b([A-Za-z0-9._%+-]+)@((?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,})\b")
HOME_PATH = re.compile(r"/(?:home|Users)/([A-Za-z0-9._-]+)")
MAC = re.compile(r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b")
SECRETS = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("token", re.compile(
        r"\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|glpat-[A-Za-z0-9_-]{20,}"
        r"|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|tskey-[A-Za-z0-9-]{10,}"
        r"|sk-[A-Za-z0-9_-]{20,})")),
    ("webhook URL", re.compile(r"discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{20,}")),
]

PRIVATE_NETS = [ipaddress.ip_network(n) for n in
                ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")]
# Well-known fixed addresses, not anyone's machine.
PUBLIC_KNOWLEDGE_IPS = {"100.100.100.100", "172.17.0.1"}
EXAMPLE_DOMAINS = {"example.com", "example.org", "example.net"}
EXAMPLE_TLDS = (".example", ".test", ".invalid", ".localhost")
SYSTEMD_SUFFIXES = {"service", "timer", "socket", "target", "mount", "path", "slice", "scope", "device"}
GENERIC_HOME_NAMES = {"runner", "user", "username", "you", "me", "pi", "ubuntu", "example",
                      "linuxbrew", "Shared"}


def private_ip(match):
    if match.group(1):  # a CIDR range, not a host
        return False
    text = match.group(0)
    try:
        addr = ipaddress.ip_address(text)
    except ValueError:
        return False
    if text in PUBLIC_KNOWLEDGE_IPS or text.endswith((".0", ".255")):
        return False
    return any(addr in net for net in PRIVATE_NETS)


def personal_email(match):
    local, domain = match.group(1), match.group(2).lower()
    if local in ("git", "noreply", "no-reply") or domain == "users.noreply.github.com":
        return False
    if domain in EXAMPLE_DOMAINS or domain.endswith(EXAMPLE_TLDS):
        return False
    if any(domain.endswith("." + d) for d in EXAMPLE_DOMAINS):
        return False
    return domain.rsplit(".", 1)[-1] not in SYSTEMD_SUFFIXES


def real_mac(match):
    return match.group(0).lower() not in ("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff")


def load_denylist(root):
    text = os.environ.get("PRIVACY_DENYLIST", "")
    path = os.path.join(root, DENYLIST_FILE)
    found = bool(text.strip())
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as handle:
            text += "\n" + handle.read()
        found = True
    entries = []
    for raw in text.splitlines():
        value = raw.strip()
        if value and not value.startswith("#") and len(value) >= 4:
            entries.append(value.lower())
    return sorted(set(entries)), found


def is_test_path(path):
    name = os.path.basename(path)
    return "/tests/" in f"/{path}" or name.startswith(("test_", "test-"))


def repo_owner():
    """The public GitHub/Forgejo owner of this repo; its handle is not a leak."""
    try:
        url = git("remote", "get-url", "origin").strip()
    except subprocess.CalledProcessError:
        return ""
    match = re.search(r"[:/]([A-Za-z0-9_.-]+)/[A-Za-z0-9_.-]+?(?:\.git)?$", url)
    return match.group(1).lower() if match else ""


def check_line(text, denylist, path="", owner=""):
    if ALLOW_MARKER in text:
        return []
    hits = []
    if any(m.group(1) != "example" for m in TAILNET_HOST.finditer(text)):
        hits.append("tailnet hostname (use <tailnet>.ts.net or example.ts.net)")
    if TAILNET_ID.search(text):
        hits.append("tailnet id")
    # Test fixtures need private-looking addresses; real ones still hit the denylist.
    if not is_test_path(path) and any(private_ip(m) for m in IPV4.finditer(text)):
        hits.append("private or tailnet IPv4 address (use 192.0.2.x in examples)")
    if any(personal_email(m) for m in EMAIL.finditer(text)):
        hits.append("email address (use example.com)")
    if any(m.group(1) not in GENERIC_HOME_NAMES for m in HOME_PATH.finditer(text)):
        hits.append("personal home path (use $HOME or <username>)")
    if any(real_mac(m) for m in MAC.finditer(text)):
        hits.append("MAC address")
    hits += [name for name, pattern in SECRETS if pattern.search(text)]
    lowered = text.lower()
    if owner:
        lowered = re.sub(rf"(?<![a-z0-9-]){re.escape(owner)}(?![a-z0-9-])", " ", lowered)
    for entry in denylist:
        if entry in lowered:
            hits.append(f"denylist entry ({len(entry)}ch, {entry[:3]}…)")
    return hits


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          encoding="utf-8", errors="replace").stdout


def added_lines(diff):
    path, line = None, 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else None
            if path:
                yield path, 0, path
        elif raw.startswith("@@"):
            hunk = re.search(r"\+(\d+)", raw)
            line = int(hunk.group(1)) if hunk else 0
        elif path and raw.startswith("+"):
            yield path, line, raw[1:]
            line += 1
        elif path and not raw.startswith("-") and not raw.startswith("\\"):
            line += 1


def message_lines(label, text):
    for number, raw in enumerate(text.splitlines(), 1):
        if not raw.startswith("#"):
            yield label, number, raw


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--message", metavar="FILE")
    mode.add_argument("--range", metavar="BASE..HEAD")
    mode.add_argument("--file", nargs="+", metavar="PATH")
    args = parser.parse_args()

    root = git("rev-parse", "--show-toplevel").strip()
    denylist, have_denylist = load_denylist(root)
    owner = repo_owner()
    sources = []
    if args.staged:
        sources.append(added_lines(git("diff", "--cached", "-U0", "--no-color", "--no-ext-diff")))
    elif args.message:
        with open(args.message, encoding="utf-8", errors="replace") as handle:
            sources.append(message_lines("commit message", handle.read()))
    elif args.range:
        base, _, head = args.range.partition("..")
        head = head or "HEAD"
        sources.append(added_lines(git("diff", "-U0", "--no-color", "--no-ext-diff", f"{base}...{head}")))
        for commit in git("rev-list", f"{base}..{head}").split():
            sources.append(message_lines(f"commit {commit[:12]} message", git("log", "-1", "--format=%B", commit)))
    else:
        for path in args.file:
            with open(path, encoding="utf-8", errors="replace") as handle:
                sources.append(message_lines(path, handle.read()))

    count = 0
    for source in sources:
        for where, line, text in source:
            for hit in check_line(text, denylist, where, owner):
                location = f"{where}:{line}" if line else f"{where} (file name)"
                print(f"{location}: {hit}")
                count += 1
    if not have_denylist:
        print(f"note: no {DENYLIST_FILE} or PRIVACY_DENYLIST; real hostnames and names were not checked",
              file=sys.stderr)
    if count:
        print(f"\n{count} possible identifying value(s); see 'Privacy & Security' in AGENTS.md. "
              f"Replace with a placeholder, or mark a deliberately public value with "
              f"'{ALLOW_MARKER}' on that line.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
