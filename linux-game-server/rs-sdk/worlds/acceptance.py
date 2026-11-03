#!/usr/bin/env python3
"""Acceptance reports for RS-SDK server images (the promote gate).

The bot host's post-update suite (2004Scape-Botting `scripts/acceptance.sh`, docs/acceptance.md
there) runs test bots on the isolated test world against a candidate image and writes one JSON
report. `world.sh acceptance record IMAGE FILE` stores it here, next to the candidate list, and
`world.sh promote` refuses an image unless the newest report recorded for that exact image id
passed, covered the whole suite, and finished after the image was built.

    acceptance.py record STATE_DIR IMAGE_ID FILE|-    validate + store; prints the summary line
    acceptance.py check STATE_DIR IMAGE_ID CREATED    exit 0 = a passing report gates IMAGE_ID in
    acceptance.py list STATE_DIR [IMAGE_ID]
    acceptance.py skip STATE_DIR IMAGE_ID REASON      log a --skip-acceptance override

CREATED is the image's build time as docker prints it (`{{.Created}}`, RFC 3339 with nanoseconds).
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
from pathlib import Path

IMAGE_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
INDEX = "acceptance.tsv"


def parse_time(text: str) -> float:
    """RFC 3339 (docker's nanosecond Created, or the report's ISO Z) -> epoch seconds."""
    t = text.strip()
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$", t)
    if not m:
        raise ValueError(f"not an RFC 3339 time: {text!r}")
    frac = (m.group(2) or "")[:7]  # microseconds at most
    zone = "+00:00" if m.group(3) == "Z" else m.group(3)
    return dt.datetime.fromisoformat(m.group(1) + frac + zone).timestamp()


def validate(report: dict, image_id: str) -> list[str]:
    problems = []
    if report.get("kind") != "rs-sdk-acceptance" or report.get("version") != 1:
        problems.append("not an rs-sdk-acceptance v1 report")
    if report.get("image") != image_id:
        problems.append(f"report is for image {report.get('image')!r}, not {image_id}")
    for key in ("runId", "startedAt", "finishedAt", "checks", "summary"):
        if key not in report:
            problems.append(f"missing {key}")
    if not isinstance(report.get("passed"), bool):
        problems.append("missing passed")
    if not isinstance(report.get("checks"), list) or not report.get("checks"):
        problems.append("no checks")
    try:
        parse_time(str(report.get("finishedAt", "")))
    except ValueError as e:
        problems.append(str(e))
    if not re.match(r"^[A-Za-z0-9._-]{1,120}$", str(report.get("runId", ""))):
        problems.append("bad runId")
    return problems


def summary_line(r: dict) -> str:
    s = r.get("summary", {})
    failed = [c.get("id") for c in r.get("checks", []) if c.get("status") == "fail"]
    world = r.get("world", {})
    return (f"{'PASSED' if r.get('passed') else 'FAILED'}{'' if r.get('complete', True) else ' (partial run)'}: "
            f"image {str(r.get('image'))[7:19]} on world {world.get('id')} ({world.get('mode') or 'shared'}); "
            f"{s.get('pass', 0)} pass, {s.get('fail', 0)} fail, {s.get('not-reached', 0)} not reached, {s.get('skipped', 0)} skipped"
            + (f"; failed: {', '.join(map(str, failed))}" if failed else "")
            + f"; SDK {str(r.get('sdk', {}).get('commit', '?'))[:9]}, bots {','.join(r.get('bots', []))}, {r.get('durationS', '?')} s")


def rows(state: Path) -> list[list[str]]:
    index = state / INDEX
    if not index.exists():
        return []
    return [line.rstrip("\n").split("\t") for line in index.read_text().splitlines() if line.strip()]


def cmd_record(state: Path, image_id: str, src: str) -> int:
    if not IMAGE_RE.match(image_id):
        print(f"not an image id: {image_id}", file=sys.stderr)
        return 2
    text = sys.stdin.read() if src == "-" else Path(src).read_text()
    try:
        report = json.loads(text)
    except json.JSONDecodeError as e:
        print(f"report is not JSON: {e}", file=sys.stderr)
        return 2
    problems = validate(report, image_id)
    if problems:
        print("report refused: " + "; ".join(problems), file=sys.stderr)
        return 2
    folder = state / "acceptance" / image_id[7:19]
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = folder / f"{report['runId']}.json"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")
    finished = parse_time(report["finishedAt"])
    complete = report.get("complete", True) is not False
    with open(state / INDEX, "a") as f:
        f.write("\t".join([image_id, report["runId"], str(int(finished)), "pass" if report["passed"] else "fail",
                           "complete" if complete else "partial", str(path)]) + "\n")
    print(summary_line(report))
    return 0


def gate(state: Path, image_id: str, created: str) -> tuple[bool, str]:
    """(ok, reason): the NEWEST report recorded for image_id decides; it must pass, be complete and
    have finished after the image was built."""
    mine = [r for r in rows(state) if r and r[0] == image_id]
    if not mine:
        return False, f"no acceptance report for {image_id}"
    newest = max(mine, key=lambda r: int(r[2]))
    built = parse_time(created)
    run, finished, verdict, scope = newest[1], int(newest[2]), newest[3], newest[4]
    if verdict != "pass":
        return False, f"the newest acceptance report ({run}) FAILED"
    if scope != "complete":
        return False, f"the newest acceptance report ({run}) is a partial run"
    if finished <= built:
        return False, f"the newest acceptance report ({run}) is older than the image"
    return True, f"acceptance report {run} passed ({dt.datetime.fromtimestamp(finished, dt.timezone.utc):%F %T}Z)"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, state = argv[0], Path(argv[1])
    if cmd == "record" and len(argv) == 4:
        return cmd_record(state, argv[2], argv[3])
    if cmd == "check" and len(argv) == 4:
        ok, reason = gate(state, argv[2], argv[3])
        print(reason)
        return 0 if ok else 1
    if cmd == "list" and len(argv) in (2, 3):
        for r in rows(state):
            if len(argv) == 3 and r[0] != argv[2]:
                continue
            when = dt.datetime.fromtimestamp(int(r[2]), dt.timezone.utc).strftime("%F %T")
            print(f"{when}Z  {r[3]:<4}  {r[4]:<8}  {r[0][7:19]}  {r[1]}")
        return 0
    if cmd == "skip" and len(argv) == 4:
        (state / "acceptance").mkdir(parents=True, exist_ok=True, mode=0o700)
        with open(state / "acceptance" / "skips.log", "a") as f:
            f.write("\t".join([dt.datetime.now(dt.timezone.utc).strftime("%FT%TZ"), argv[2], os.environ.get("USER", "?"),
                               argv[3].replace("\t", " ").replace("\n", " ")]) + "\n")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
