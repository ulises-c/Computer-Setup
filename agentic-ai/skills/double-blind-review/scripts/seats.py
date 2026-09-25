#!/usr/bin/env python3
"""Pick the reviewer seats for one double-blind review, deterministically.

Reads ../seats.json, drops the orchestrator's family when the roster says so,
and for each remaining family takes the first launcher that is usable right now:
its CLI (and adapter script) exists, its Hermes profile exists, its `until`
date has not passed, and for Bedrock billing the AWS session is valid.
Prints one JSON object; exit 1 when fewer families than required are available.
"""

import argparse
import datetime
import functools
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
ADAPTERS = {
    "hermes": "hermes-run.sh",
    "claude": "claude-run.sh",
    "codex": "codex-run.sh",
    "agy": "agy-run.sh",
}
EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]


@functools.cache
def aws_session_ok():
    try:
        r = subprocess.run(["aws", "sts", "get-caller-identity"], capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0


def hermes_profile_exists(name):
    home = Path(os.environ.get("HOME", "~")).expanduser()
    return (home / ".hermes" / "profiles" / name / "config.yaml").is_file()


def unavailable_reason(seat, today):
    launcher = seat["launcher"]
    adapter = ADAPTERS.get(launcher)
    if adapter is None or not (SKILL_DIR / "scripts" / adapter).is_file():
        return f"no adapter script for launcher '{launcher}'"
    if shutil.which(launcher) is None:
        return f"'{launcher}' not on PATH"
    expires = seat.get("expires")
    if expires and today >= datetime.date.fromisoformat(expires):
        return f"expired {expires}"
    if launcher == "hermes" and not hermes_profile_exists(seat["profile"]):
        return f"hermes profile '{seat['profile']}' missing"
    if seat.get("billing") == "bedrock" and not aws_session_ok():
        return "AWS session invalid (run aws sso login)"
    if launcher == "codex" and seat.get("bedrock") and shutil.which("uv") is None:
        return "uv not on PATH (needed to mint the Bedrock token)"
    return None


def clamp_effort(requested, policy):
    lo, hi = EFFORTS.index(policy["floor"]), EFFORTS.index(policy["ceiling"])
    return EFFORTS[min(max(EFFORTS.index(requested or policy["default"]), lo), hi)]


def main():
    ap = argparse.ArgumentParser(description="Pick reviewer seats for a double-blind review.")
    ap.add_argument("--roster", required=True)
    ap.add_argument("--orchestrator-family", required=True,
                    help="model family of the orchestrating agent: anthropic, openai, google, other")
    ap.add_argument("--effort", choices=EFFORTS, help="requested effort; clamped to the roster's floor/ceiling")
    ap.add_argument("--seats-file", default=str(SKILL_DIR / "seats.json"))
    ap.add_argument("--today", help="YYYY-MM-DD override, for testing expiry")
    args = ap.parse_args()

    config = json.loads(Path(args.seats_file).read_text())
    roster = config["rosters"].get(args.roster)
    if roster is None:
        sys.exit(f"seats: unknown roster '{args.roster}'; have {sorted(config['rosters'])}")
    today = datetime.date.fromisoformat(args.today) if args.today else datetime.date.today()
    effort = clamp_effort(args.effort, roster["effort"])

    chosen, skipped = [], []
    for family, candidates in roster["seats"].items():
        if roster["exclude_orchestrator_family"] and family == args.orchestrator_family:
            skipped.append({"family": family, "reason": "orchestrator's own family"})
            continue
        for seat in candidates:
            reason = unavailable_reason(seat, today)
            if reason is None:
                chosen.append({"family": family, "effort": effort,
                               "adapter": str(SKILL_DIR / "scripts" / ADAPTERS[seat["launcher"]]), **seat})
                break
            skipped.append({"family": family, "launcher": seat["launcher"], "reason": reason})
        if len(chosen) == roster["families"]:
            break

    ok = len(chosen) == roster["families"]
    print(json.dumps({"roster": args.roster, "ok": ok, "seats": chosen, "skipped": skipped}, indent=2))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
