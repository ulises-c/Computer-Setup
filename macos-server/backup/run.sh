#!/usr/bin/env bash
set -uo pipefail

# launchd entry point for the nightly backup. launchd has no OnFailure, so the
# engine's failure notifier (ntfy / Uptime Kuma, status JSON) runs from here.
# The agent puts Homebrew's bash 5 first on PATH: the engine needs bash 4+.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf '=== %s\n' "$(date '+%F %T %Z')"
if bash "$SCRIPT_DIR/backup.sh"; then
  exit 0
fi
bash "$SCRIPT_DIR/backup.sh" notify-failure
exit 1
