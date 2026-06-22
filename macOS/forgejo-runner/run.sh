#!/usr/bin/env bash
# Control the Forgejo runner LaunchAgent.
#
# Usage: bash run.sh <command>
#   start    load + start the daemon
#   stop     stop + unload the daemon
#   restart  force a restart (picks up config changes)
#   status   show launchd state + recent log lines
#   logs     print the full log
#   tail     follow the log (Ctrl-C to stop)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=macOS/forgejo-runner/lib.sh
source "$HERE/lib.sh"

DOMAIN="$(launchd_domain)"
cmd="${1:-status}"

case "$cmd" in
  start)
    [[ -f "$PLIST" ]] || die "LaunchAgent not installed — run: bash $HERE/install.sh"
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart "$DOMAIN/$LABEL"
    ok "started $LABEL"
    ;;
  stop)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    ok "stopped $LABEL"
    ;;
  restart)
    launchctl kickstart -k "$DOMAIN/$LABEL"
    ok "restarted $LABEL"
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|last exit code) ' || warn "not loaded"
    printf '\n--- last 10 log lines ---\n'
    [[ -f "$LOG" ]] && tail -10 "$LOG" || info "no log yet: $LOG"
    ;;
  logs)
    [[ -f "$LOG" ]] && cat "$LOG" || die "no log at $LOG"
    ;;
  tail)
    [[ -f "$LOG" ]] || die "no log at $LOG"
    tail -f "$LOG"
    ;;
  *)
    die "unknown command: $cmd (try: start|stop|restart|status|logs|tail)"
    ;;
esac
