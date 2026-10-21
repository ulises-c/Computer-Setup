#!/usr/bin/env bash
set -euo pipefail

# Start or stop the local MLX inference server by hand. It is installed (and
# registered with launchd) by agents.sh but never starts on its own, because
# the model stays in memory for as long as it runs.
#
#   bash macos-server/inference/run.sh start|stop|status|tail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macos-server/lib.sh
source "$SCRIPT_DIR/../lib.sh"
LABEL=net.computer-setup.mlx-server
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
[[ -f "$PLIST" ]] || die "not installed; run: bash $MACOS_SERVER_DIR/agents.sh install"
port="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:6' "$PLIST")"
url="http://127.0.0.1:$port/v1/models"

case "${1:-}" in
  start)
    [[ -n "$(agent_state "$LABEL")" ]] || agent_load "$LABEL"
    launchctl kickstart "$(gui_domain)/$LABEL"
    printf 'loading the model; waiting for %s\n' "$url"
    curl -fsS --retry 60 --retry-connrefused --retry-delay 2 "$url" >/dev/null
    printf 'ready: %s\n' "$url"
    ;;
  stop)
    launchctl kill SIGTERM "$(gui_domain)/$LABEL" 2>/dev/null || true
    printf 'stopped %s\n' "$LABEL"
    ;;
  status)
    state="$(agent_state "$LABEL")"
    printf '%s: %s\n' "$LABEL" "${state:-not loaded}"
    curl -fsS --max-time 3 "$url" 2>/dev/null | jq -r '.data[].id' 2>/dev/null || printf 'API not answering on %s\n' "$url"
    ;;
  tail) tail -f "$LOG_DIR/mlx-server.log" ;;
  *) printf 'usage: bash %s start|stop|status|tail\n' "$0" >&2; exit 1 ;;
esac
