#!/usr/bin/env python3
"""One-off repair of RS-SDK skill hiscore rows written under the wrong XP curve.

On 2026-10-26 (03:00-11:56 PDT) rs-sdk-server ran an image with the fork's level/10
curve, so every logout in that window stored inflated skill levels in `hiscore`. The
stored XP (`value`, in tenths of XP like the engine's stats) is right; only `level` is
wrong. This recomputes each skill row's level from its XP on the original level/7 curve
(Player.ts getLevelByExp, capped at 99) and deletes rows that fall below the board's
level 15, which the login server would never have written.

Not touched: Quest Points (type 100), `hiscore_large` (total level needs every skill,
including those under 15 that have no row; it heals at the account's next logout) and
`playtime` (kept, so ties still go to who reached the level first).

Dry run by default: prints before/after counts and changes nothing. `--apply` refuses
while rs-sdk-server is running on that database, takes a backup first (SQLite backup
API plus raw copies of the db/-wal/-shm files) and changes everything in one transaction.
"""
import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

SKILL_TYPES = range(1, 22)  # hiscore type = stat + 1 for the 21 stats
BOARD_MIN_LEVEL = 15
CONTAINER = "rs-sdk-server"


def level_table():
    """levelExperience from Player.ts: XP thresholds for levels 2..100, in tenths of XP."""
    table, acc = [], 0
    for i in range(99):
        level = i + 1
        acc += int(level + 2.0 ** (level / 7.0) * 300.0)
        table.append((acc // 4) * 10)
    return table


LEVELS = level_table()


def level_for(value):
    """getLevelByExp from Player.ts (value is XP * 10)."""
    for i in range(98, -1, -1):
        if value >= LEVELS[i]:
            return min(i + 2, 99)
    return 1


def plan(con):
    rows = con.execute(
        "SELECT h.account_id, h.profile, h.type, h.level, h.value, a.username "
        "FROM hiscore h LEFT JOIN account a ON a.id = h.account_id "
        f"WHERE h.type BETWEEN {SKILL_TYPES.start} AND {SKILL_TYPES.stop - 1} "
        "ORDER BY h.profile, h.type, h.account_id"
    ).fetchall()
    update, delete = [], []
    for account_id, profile, kind, stored, value, username in rows:
        level = level_for(value)
        if level < BOARD_MIN_LEVEL:
            delete.append((account_id, profile, kind, stored, level, value, username))
        elif level != stored:
            update.append((account_id, profile, kind, stored, level, value, username))
    return rows, update, delete


def counts(con):
    skill = con.execute(
        f"SELECT count(*), count(DISTINCT account_id) FROM hiscore WHERE type BETWEEN {SKILL_TYPES.start} AND {SKILL_TYPES.stop - 1}"
    ).fetchone()
    other = con.execute(
        f"SELECT count(*) FROM hiscore WHERE type NOT BETWEEN {SKILL_TYPES.start} AND {SKILL_TYPES.stop - 1}"
    ).fetchone()[0]
    large = con.execute("SELECT count(*) FROM hiscore_large").fetchone()[0]
    _, update, delete = plan(con)
    return {
        "skill_rows": skill[0],
        "skill_accounts": skill[1],
        "off_curve_rows": len(update),
        "below_15_rows": len(delete),
        "other_hiscore_rows": other,
        "hiscore_large_rows": large,
    }


def show(label, c):
    print(f"{label}: " + ", ".join(f"{k}={v}" for k, v in c.items()))


def live_database(db):
    """True when rs-sdk-server is running with this file under its data mount."""
    docker = shutil.which("docker")
    if not docker:
        return False
    result = subprocess.run([docker, "inspect", CONTAINER], capture_output=True, text=True)
    if result.returncode != 0:
        return False
    info = json.loads(result.stdout)[0]
    if not info["State"]["Running"]:
        return False
    db = Path(db).resolve()
    for mount in info.get("Mounts", []):
        source = Path(mount.get("Source", "")).resolve()
        if db == source or source in db.parents:
            return True
    return False


def backup(db, backup_dir):
    stamp = dt.datetime.now().strftime("%Y%m%dT%H%M%S")
    backup_dir.mkdir(parents=True, exist_ok=True)
    target = backup_dir / f"hiscore-fix-{stamp}.sqlite"
    raw = backup_dir / f"hiscore-fix-{stamp}.raw"
    if target.exists() or raw.exists():
        raise SystemExit(f"{target} already exists; rerun in a second")
    src = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    dst = sqlite3.connect(target)
    with dst:
        src.backup(dst)
    dst.execute("PRAGMA journal_mode = DELETE")  # one self-contained file, no -wal/-shm
    src.close()
    dst.close()
    raw.mkdir()
    for suffix in ("", "-wal", "-shm"):
        path = Path(f"{db}{suffix}")
        if path.exists():
            shutil.copy2(path, raw / path.name)
    check = sqlite3.connect(f"file:{target}?mode=ro", uri=True)
    ok = check.execute("PRAGMA integrity_check").fetchone()[0]
    rows = check.execute("SELECT count(*) FROM hiscore").fetchone()[0]
    check.close()
    if ok != "ok":
        raise SystemExit(f"backup {target} failed its integrity check: {ok}")
    print(f"backup: {target} (integrity ok, {rows} hiscore rows) + raw files in {raw}")
    return target


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--db", required=True, help="path to the RS-SDK db.sqlite")
    parser.add_argument("--apply", action="store_true", help="change the database (default: dry run)")
    parser.add_argument("--backup-dir", type=Path, default=Path.home() / ".local/state/computer-setup")
    parser.add_argument("--examples", type=int, default=10, help="changes to list (default 10)")
    args = parser.parse_args(argv)

    db = Path(args.db)
    if not db.is_file():
        raise SystemExit(f"{db}: no such database")
    if args.apply and live_database(db):
        raise SystemExit(f"{CONTAINER} is running on {db}; stop the engine before --apply")

    mode = "rw" if args.apply else "ro"
    con = sqlite3.connect(f"file:{db}?mode={mode}", uri=True)
    con.execute("PRAGMA busy_timeout = 10000")
    before = counts(con)
    show("before", before)
    _, update, delete = plan(con)
    accounts = len({(r[0], r[1]) for r in update + delete})
    print(f"plan: relevel {len(update)} rows, delete {len(delete)} rows below {BOARD_MIN_LEVEL}, {accounts} account/profiles")
    for verb, rows in (("relevel", update), ("delete", delete)):
        for account_id, profile, kind, stored, level, value, username in rows[: args.examples]:
            print(f"  {verb} {username or account_id}/{profile} type {kind}: xp {value / 10:,.1f} level {stored} -> {level}")
    expected = dict(before, off_curve_rows=0, below_15_rows=0,
                    skill_rows=before["skill_rows"] - len(delete))

    if not args.apply:
        con.close()
        show("after (dry run, expected)", expected)
        print("dry run: nothing changed; rerun with --apply while the engine is stopped")
        return 0

    con.close()
    if not update and not delete:
        print("nothing to apply: every skill row already matches the original curve (no backup taken)")
        return 0
    backup(db, args.backup_dir)
    con = sqlite3.connect(f"file:{db}?mode=rw", uri=True)
    con.execute("PRAGMA busy_timeout = 10000")
    with con:
        con.executemany(
            "UPDATE hiscore SET level = ? WHERE account_id = ? AND profile = ? AND type = ? AND level = ?",
            [(level, account_id, profile, kind, stored) for account_id, profile, kind, stored, level, _, _ in update],
        )
        con.executemany(
            "DELETE FROM hiscore WHERE account_id = ? AND profile = ? AND type = ?",
            [(account_id, profile, kind) for account_id, profile, kind, *_ in delete],
        )
    after = counts(con)
    con.close()
    show("after", after)
    skill_accounts_ok = after["skill_accounts"] <= before["skill_accounts"]
    if {k: v for k, v in after.items() if k != "skill_accounts"} != {k: v for k, v in expected.items() if k != "skill_accounts"} or not skill_accounts_ok:
        print("after counts differ from the plan; restore the backup and investigate", file=sys.stderr)
        return 1
    print("applied: every skill row now matches the original curve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
