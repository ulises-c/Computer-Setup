#!/usr/bin/env bash
set -euo pipefail

# Installs 2004scape-status.{service,timer}: game_status.py, run as the login
# user every 15 s, writes the Lost City and RS-SDK Homepage card JSON into
# status/ (served by this directory's loopback nginx). --dry-run prints the plan.
#
# Usage: sudo bash linux-game-server/2004scape/install-status-timer.sh [--dry-run]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly UNIT_DIR=/etc/systemd/system
DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s (use --dry-run)\n' "$1" >&2; exit 1 ;;
esac

if [[ "$DRY_RUN" == false && $EUID -ne 0 ]]; then
  printf 'error: run with sudo: sudo bash %s\n' "$0" >&2
  exit 1
fi
: "${SERVICE_USER:=${SUDO_USER:-$(id -un)}}"
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'error: unsupported user name: %s\n' "$SERVICE_USER" >&2; exit 1; }
[[ "$SERVICE_USER" != root ]] || { printf 'error: run through sudo from the login user, not as root\n' >&2; exit 1; }
id -u "$SERVICE_USER" >/dev/null 2>&1 || { printf 'error: no such user: %s\n' "$SERVICE_USER" >&2; exit 1; }
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx docker \
  || { printf 'error: %s is not in the docker group\n' "$SERVICE_USER" >&2; exit 1; }
STATUS_SCRIPT="$SCRIPT_DIR/game_status.py"
[[ "$STATUS_SCRIPT" =~ ^/[[:alnum:]_./-]+$ ]] \
  || { printf 'error: unsupported character in checkout path: %s\n' "$STATUS_SCRIPT" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@GROUP@|$SERVICE_GROUP|g" -e "s|@STATUS_SCRIPT@|$STATUS_SCRIPT|g" \
  "$SCRIPT_DIR/2004scape-status.service.template" >"$tmp/2004scape-status.service"
cp "$SCRIPT_DIR/2004scape-status.timer" "$tmp/"
rc=0
grep -nE '@[A-Za-z0-9_]+@' "$tmp"/* || rc=$?
case "$rc" in
  0) printf 'error: unrendered template placeholder above\n' >&2; exit 1 ;;
  1) ;;
  *) printf 'error: cannot scan the rendered files\n' >&2; exit 1 ;;
esac
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/2004scape-status.service" "$tmp/2004scape-status.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install -d -o %s %s/status\n' "$SERVICE_USER" "$SCRIPT_DIR"
  printf '[dry-run] install %s/2004scape-status.service (User=%s, ExecStart %s)\n' "$UNIT_DIR" "$SERVICE_USER" "$STATUS_SCRIPT"
  printf '[dry-run] install %s/2004scape-status.timer\n' "$UNIT_DIR"
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now 2004scape-status.timer\n'
  exit 0
fi
install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 755 "$SCRIPT_DIR/status"
install -o root -g root -m 644 "$tmp/2004scape-status.service" "$UNIT_DIR/2004scape-status.service"
install -o root -g root -m 644 "$tmp/2004scape-status.timer" "$UNIT_DIR/2004scape-status.timer"
systemctl daemon-reload
systemctl enable --now 2004scape-status.timer
printf 'Installed. Check: systemctl list-timers 2004scape-status.timer; curl -s http://127.0.0.1:8097/lostcity-status.json\n'
