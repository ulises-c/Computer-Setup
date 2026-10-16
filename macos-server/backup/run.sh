#!/usr/bin/env bash
set -uo pipefail

# launchd entry point for the nightly backup. launchd has no OnFailure, so the
# engine's failure notifier (ntfy / Uptime Kuma, status JSON) runs from here.
# The agent puts Homebrew's bash 5 first on PATH: the engine needs bash 4+.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The notifier never executes sources.sh, so the Homepage-served status path
# must come from here for both the run and the failure notifier (launchd sets
# no STATUS_JSON; an explicit one, as in tests, wins).
STATUS_JSON="${STATUS_JSON:-$(dirname -- "$SCRIPT_DIR")/status/www/backup-status.json}"
export STATUS_JSON
printf '=== %s\n' "$(date '+%F %T %Z')"
child_pid=""
result=1

finish() {
  trap '' TERM INT
  if [[ -n "$child_pid" ]]; then
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  if [[ "$result" != 0 ]]; then
    bash "$SCRIPT_DIR/backup.sh" notify-failure \
      || printf 'warning: backup failure notifier failed\n' >&2
  fi
}

trap finish EXIT
trap 'result=143; exit "$result"' TERM
trap 'result=130; exit "$result"' INT

# An isolated job group lets cancellation reach the engine's foreground children
# without signalling this wrapper or its subsequent failure notifier.
set -m
bash "$SCRIPT_DIR/backup.sh" &
child_pid=$!
wait "$child_pid"
result=$?
child_pid=""
exit "$result"
