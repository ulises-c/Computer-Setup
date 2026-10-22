#!/usr/bin/env python3
"""Flag identifying or secret values before they reach this public repo.

Checks added lines (not whole files) so existing, reviewed text does not
re-trigger, plus commit messages. Two layers:

* Patterns that need no private knowledge: tailnet names, private/tailnet
  IPv4 addresses, personal emails, home paths, MAC addresses, tokens, keys.
* A private denylist of the real values (hostnames, tailnet, usernames, ...):
  `.privacy-denylist` at the repo root (gitignored), or the PRIVACY_DENYLIST
  environment variable in CI. One value per line, `#` comments allowed. The
  repo owner's public handle is exempt only within links to the origin repo.

A hit is reported as path:line and the check name. The matched text is never
printed; identifying paths are redacted while safe filenames stay useful.

Usage:
  check-privacy.py --staged             staged changes (pre-commit)
  check-privacy.py --message FILE       a commit message (commit-msg hook)
  check-privacy.py --range BASE..HEAD   added lines and commit messages (CI)
  check-privacy.py --file PATH...       whole files, e.g. a PR body draft
  check-privacy.py --pre-push           outgoing commits from hook stdin;
                                      requires a usable denylist
  --require-denylist                   fail closed without usable entries
  --no-allow                           ignore generic fixture allow markers
"""
import argparse
import ast
import functools
import ipaddress
import itertools
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


@functools.lru_cache(maxsize=8)
def repo_scope(directory):
    try:
        origin = git("-C", directory, "remote", "get-url", "origin").strip().lower()
    except subprocess.CalledProcessError:
        return None
    return re.search(r"(?:://(?:[^/@]+@)?|@)([^/:]+)[:/]([^/]+)/([^/]+?)(?:\.git)?$", origin)


def repo_owner():
    scope = repo_scope(os.getcwd())
    return scope.group(2) if scope else ""


@functools.lru_cache(maxsize=4096)
def denylist_rule(entry):
    try:
        address = ipaddress.ip_address(entry)
    except ValueError:
        return None, re.compile(rf"(?<![\w-]){re.escape(entry)}(?![\w-])")
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        address = address.ipv4_mapped
    return address, None


def text_addresses(text):
    addresses = set()
    for match in re.finditer(r"(?<![\w:.])[0-9a-f:.]+(?:%[\w.-]+)?(?![\w:.])", text):
        candidate = match.group().rstrip(".")
        if candidate.count(":") == 1 and "." in candidate:
            candidate = candidate.split(":", 1)[0]
        try:
            address = ipaddress.ip_address(candidate)
            if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
                address = address.ipv4_mapped
            addresses.add(address)
        except ValueError:
            pass
    return addresses


def denylisted(text, entry, addresses=None):
    address, pattern = denylist_rule(entry)
    if address is None:
        assert pattern is not None
        return bool(pattern.search(text))
    return address in (text_addresses(text) if addresses is None else addresses)


def check_line(text, denylist, path="", owner="", *, no_allow=False):
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
    if not no_allow and ALLOW_MARKER in text:
        hits = []
    hits += [name for name, pattern in SECRETS if pattern.search(text)]
    lowered = text.lower()
    if owner:
        scope = repo_scope(os.getcwd())
        if scope and scope.group(2) == owner.lower():
            host, handle, repo = map(re.escape, scope.groups())
            lowered = re.sub(
                rf"((?<![\w@./-])https?://{host}/){handle}(/{repo}(?:\.git)?)(?=$|[/#?\s)\]>,]|\.(?=$|\s))",
                r"\1 \2", lowered)
    addresses = text_addresses(lowered) if ':' in lowered or any(c.isdigit() for c in lowered) else set()
    for entry in denylist:
        if denylisted(lowered, entry.lower(), addresses):
            hits.append("denylist entry")
    return hits


def safe_location(path, denylist):
    if not check_line(path, denylist, no_allow=True):
        return path
    name = os.path.basename(path)
    if check_line(name, denylist, no_allow=True):
        return "<redacted path>"
    return "<redacted path>/" + name


def git(*args):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_TERMINAL_PROMPT="0", GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_NO_REPLACE_OBJECTS="1", GIT_OPTIONAL_LOCKS="0")
    return subprocess.run(["git", "--no-pager", "-c", "core.fsmonitor=false",
                           "-c", f"core.hooksPath={os.devnull}",
                           "-c", f"core.attributesFile={os.devnull}", "-c", "diff.external=",
                           "-c", "credential.helper=", "-c", "protocol.allow=never", *args],
                          check=True, capture_output=True, text=True, env=env,
                          encoding="utf-8", errors="replace").stdout


def added_lines(diff):
    path, line = None, 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            name = raw[4:]
            if name.startswith('"'):
                name = ast.literal_eval("b" + name).decode("utf-8", errors="replace")
            path = name[2:] if name.startswith("b/") else None
        elif raw.startswith("@@"):
            hunk = re.search(r"\+(\d+)", raw)
            line = int(hunk.group(1)) if hunk else 0
        elif path and raw.startswith("+"):
            yield path, line, raw[1:]
            line += 1
        elif path and not raw.startswith("-") and not raw.startswith("\\"):
            line += 1


def message_lines(label, text, skip_comments=True):
    for number, raw in enumerate(text.splitlines(), 1):
        if not skip_comments or not raw.startswith("#"):
            yield label, number, raw


def filename_lines(names):
    for name in names.split("\0"):
        if name:
            yield name, 0, name


def commit_sources(commits):
    for commit in commits:
        yield added_lines(git("-c", "core.quotePath=true", "diff-tree", "--root", "-m", "-r", "-p", "-U0",
                              "--src-prefix=a/", "--dst-prefix=b/",
                              "--no-renames", "--no-color", "--no-ext-diff", "--no-textconv", commit))
        yield filename_lines(git("diff-tree", "--root", "-m", "-r", "--no-commit-id",
                                 "--no-renames", "--name-only", "-z", commit))
        yield message_lines(f"commit {commit[:12]} message",
                            git("log", "-1", "--format=%B", commit), skip_comments=False)
        yield message_lines(f"commit {commit[:12]} metadata",
                            git("log", "-1", "--format=%an%n%ae%n%cn%n%ce", commit), skip_comments=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true")
    mode.add_argument("--message", metavar="FILE")
    mode.add_argument("--range", metavar="BASE..HEAD")
    mode.add_argument("--pre-push", action="store_true")
    mode.add_argument("--file", nargs="+", metavar="PATH")
    parser.add_argument("--no-allow", action="store_true")
    parser.add_argument("--require-denylist", action="store_true")
    args = parser.parse_args()

    root = git("rev-parse", "--show-toplevel").strip()
    denylist, have_denylist = load_denylist(root)
    if (args.require_denylist or args.pre_push) and not denylist:
        print("error: a usable denylist is required", file=sys.stderr)
        return 1
    owner = repo_owner()
    sources = []
    if args.staged:
        sources.append(added_lines(git("-c", "core.quotePath=true", "diff", "--cached", "-U0",
                                      "--src-prefix=a/", "--dst-prefix=b/",
                                      "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames")))
        sources.append(filename_lines(git("diff", "--cached", "--no-renames", "--name-only", "-z")))
    elif args.message:
        with open(args.message, encoding="utf-8", errors="replace") as handle:
            sources.append(message_lines("commit message", handle.read()))
    elif args.range:
        base, _, head = args.range.partition("..")
        head = head or "HEAD"
        sources = commit_sources(git("rev-list", f"{base}..{head}").split())
    elif args.pre_push:
        commits = set()
        for raw in sys.stdin:
            local_ref, local_sha, remote_ref, remote_sha = raw.split()
            if not all(re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value)
                       for value in (local_sha, remote_sha)):
                raise ValueError("invalid pre-push object id")
            sources.append(message_lines("push refs", f"{local_ref}\n{remote_ref}",
                                         skip_comments=False))
            if set(local_sha) == {"0"}:
                continue
            tag_sha = local_sha
            while git("cat-file", "-t", tag_sha).strip() == "tag":
                tag = git("cat-file", "tag", tag_sha)
                sources.append(message_lines(f"tag {tag_sha[:12]} metadata", tag,
                                             skip_comments=False))
                kind, _, tag_sha = tag.partition("\n")[0].partition(" ")
                if kind != "object" or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", tag_sha):
                    raise ValueError("invalid tag target")
            if set(remote_sha) == {"0"}:
                commits.update(git("rev-list", local_sha).split())
            else:
                commits.update(git("rev-list", f"{remote_sha}..{local_sha}").split())
        sources = itertools.chain(sources, commit_sources(sorted(commits)))
    else:
        for path in args.file:
            absolute = os.path.abspath(path)
            name = (os.path.relpath(absolute, root) if os.path.commonpath([absolute, root]) == root
                    else os.path.basename(path))
            sources.append([(path, 0, name)])
            with open(path, encoding="utf-8", errors="replace") as handle:
                sources.append(message_lines(path, handle.read(), skip_comments=False))

    count = 0
    for source in sources:
        for where, line, text in source:
            for hit in check_line(text, denylist, where if line else "", owner,
                                  no_allow=args.no_allow or not line):
                safe_where = safe_location(where, denylist)
                location = f"{safe_where}:{line}" if line else f"{safe_where} (file name)"
                print(f"{location}: {hit}")
                count += 1
    if not have_denylist:
        print(f"note: no {DENYLIST_FILE} or PRIVACY_DENYLIST; real hostnames and names were not checked",
              file=sys.stderr)
    if count:
        print(f"\n{count} possible identifying value(s); see 'Privacy & Security' in AGENTS.md. "
              "Replace with a placeholder. Allow markers never suppress denylist entries or secrets.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError, SyntaxError):
        print("error: privacy scan could not complete; check inputs and local Git objects", file=sys.stderr)
        sys.exit(1)
