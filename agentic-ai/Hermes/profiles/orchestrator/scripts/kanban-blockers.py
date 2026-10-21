#!/usr/bin/env python3
"""Kanban blocker monitor for the orchestrator's Slack cron job.

Prints one stable line per card that needs a human, across every board.
Prints nothing when there is nothing to report. No timestamps or ages in
the output: the cron monitor wakes the agent only when this output changes.
Stdlib only, read-only.
"""
import json
import os
import sqlite3
from pathlib import Path

ROOT = Path(os.environ.get("HERMES_KANBAN_HOME") or Path.home() / ".hermes")


def boards():
    yield "default", ROOT / "kanban.db"
    base = ROOT / "kanban" / "boards"
    if not base.is_dir():
        return
    for d in sorted(base.iterdir()):
        meta = d / "board.json"
        db = d / "kanban.db"
        if d.name.startswith("_") or not db.is_file():
            continue
        try:
            if json.loads(meta.read_text()).get("archived"):
                continue
        except (OSError, ValueError):
            pass
        yield d.name, db


SQL = """
SELECT id, status, COALESCE(assignee, '-'), COALESCE(block_kind, ''), title
  FROM tasks
 WHERE status IN ('blocked', 'triage')
    OR (status = 'ready' AND assignee IS NULL)
 ORDER BY id
"""

lines = []
for slug, db in boards():
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        rows = conn.execute(SQL).fetchall()
        conn.close()
    except sqlite3.Error as exc:
        lines.append(f"{slug} | DB ERROR {exc}")
        continue
    for tid, status, assignee, kind, title in rows:
        reason = status if status != "blocked" else f"blocked:{kind or 'untyped'}"
        if status == "ready":
            reason = "ready-unassigned"
        lines.append(f"{slug} | {tid} | {reason} | @{assignee} | {title[:90]}")

print("\n".join(lines))
