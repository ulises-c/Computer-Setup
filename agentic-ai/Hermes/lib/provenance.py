#!/usr/bin/env python3
"""Per-skill edit provenance for hermes-skills.

The curator ledger records the session behind every skill create/patch, and
each session records its working directory. Each session is classified:

  1. its repo commits as an address outside HERMES_SKILLS_WORK_EMAIL_DOMAINS
     -> not work. Definitive: work is only ever committed as the work identity.
  2. its repo's origin matches HERMES_SKILLS_WORK_REMOTE_PATTERNS -> work.
     The work email alone proves nothing: work-adjacent open-source repos use
     it too.
  3. any other repo -> not work
  4. no repo (home dir, deleted worktree): the parent session's class for a
     subagent, else work if what the user typed matches a work marker:
     HERMES_SKILLS_MARK_CI (ERE, case-insensitive), HERMES_SKILLS_MARK_CS
     (Jira refs, case-sensitive), or a whole word from the terms file named
     by HERMES_SKILLS_MARK_TERMS (case-insensitive).

Prints "<skill>\t<work edits>\t<classified edits>" for each skill on argv.
Reads state.db read-only; never writes anything.
"""
from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
from pathlib import Path


def git(repo: str, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def compile_env(name: str, flags: int = 0) -> re.Pattern | None:
    value = os.environ.get(name, "")
    return re.compile(value, flags) if value else None


def terms_pattern() -> re.Pattern | None:
    path = os.environ.get("HERMES_SKILLS_MARK_TERMS", "")
    if not path or not Path(path).is_file():
        return None
    terms = sorted({t.strip() for t in Path(path).read_text().splitlines() if t.strip()}, key=len, reverse=True)
    if not terms:
        return None
    return re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(map(re.escape, terms)) + r")(?![A-Za-z0-9_])", re.I)


def main() -> int:
    wanted = sys.argv[1:]
    counts = {name: [0, 0] for name in wanted}
    home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    ledger = home / "skills" / ".curator_ledger.jsonl"
    db_path = home / "state.db"
    if not counts or not ledger.is_file() or not db_path.is_file():
        for name in counts:
            print(f"{name}\t0\t0")
        return 0

    remote_re = compile_env("HERMES_SKILLS_WORK_REMOTE_PATTERNS")
    domains = {d.lower() for d in os.environ.get("HERMES_SKILLS_WORK_EMAIL_DOMAINS", "").split()}
    typed_res = [
        p
        for p in (compile_env("HERMES_SKILLS_MARK_CI", re.I), compile_env("HERMES_SKILLS_MARK_CS"), terms_pattern())
        if p
    ]
    user_home = str(Path.home())
    db = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    repos: dict[str, str | None] = {}
    sessions: dict[str, str] = {}

    def repo_class(path: str) -> str | None:
        """work / nonwork for a path inside a git repo, None when not in one."""
        if path not in repos:
            top = git(path, "rev-parse", "--show-toplevel")
            if not top or top == user_home:
                repos[path] = None
            else:
                email = git(top, "config", "user.email").lower()
                origin = git(top, "remote", "get-url", "origin")
                if domains and email and email.rsplit("@", 1)[-1] not in domains:
                    repos[path] = "nonwork"
                elif remote_re and remote_re.search(origin):
                    repos[path] = "work"
                else:
                    repos[path] = "nonwork"
        return repos[path]

    def session_class(sid: str, depth: int = 0) -> str:
        if sid in sessions:
            return sessions[sid]
        row = db.execute(
            "SELECT coalesce(nullif(git_repo_root, ''), nullif(cwd, '')), parent_session_id FROM sessions WHERE id = ?",
            (sid,),
        ).fetchone()
        result = None
        if row:
            path, parent = row
            if path and Path(path).is_dir():
                result = repo_class(path)
            if result is None and parent and depth < 8:
                result = session_class(parent, depth + 1)
        if result is None:
            typed = db.execute("SELECT content FROM messages WHERE session_id = ? AND role = 'user'", (sid,))
            hit = any(p.search(text or "") for (text,) in typed for p in typed_res)
            result = "work" if hit else "nonwork"
        sessions[sid] = result
        return result

    with ledger.open() as fh:
        for line in fh:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = entry.get("skill")
            sid = (entry.get("evidence") or {}).get("session_id")
            if name not in counts or not sid:
                continue
            counts[name][1] += 1
            counts[name][0] += session_class(sid) == "work"

    for name, (work, total) in counts.items():
        print(f"{name}\t{work}\t{total}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
