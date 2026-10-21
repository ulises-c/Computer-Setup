#!/usr/bin/env bash
set -euo pipefail

# Installs the nightly 2004Scape update: 2004scape-update.{service,timer} running
# update.sh as the login user, and a polkit rule letting that user restart
# game-backup.service (the fresh pre-update backup). --dry-run prints the plan.
#
# Usage: sudo bash linux-game-server/2004scape/install-update-timer.sh [--dry-run]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly UNIT_DIR=/etc/systemd/system
readonly POLKIT_RULE=/etc/polkit-1/rules.d/60-2004scape-update.rules
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
# Rendered into a unit file and the polkit rule (JavaScript).
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { printf 'error: unsupported user name: %s\n' "$SERVICE_USER" >&2; exit 1; }
[[ "$SERVICE_USER" != root ]] || { printf 'error: run through sudo from the login user, not as root\n' >&2; exit 1; }
id -u "$SERVICE_USER" >/dev/null 2>&1 || { printf 'error: no such user: %s\n' "$SERVICE_USER" >&2; exit 1; }
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qx docker \
  || { printf 'error: %s is not in the docker group\n' "$SERVICE_USER" >&2; exit 1; }
UPDATE_SCRIPT="$SCRIPT_DIR/update.sh"
[[ "$UPDATE_SCRIPT" =~ ^/[[:alnum:]_./-]+$ ]] \
  || { printf 'error: unsupported character in checkout path: %s\n' "$UPDATE_SCRIPT" >&2; exit 1; }
if [[ "$(systemctl show game-backup.service -p LoadState --value 2>/dev/null)" != loaded ]]; then
  printf 'warning: game-backup.service is not installed; update runs will refuse to start until it is\n' >&2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() {
  sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@GROUP@|$SERVICE_GROUP|g" -e "s|@UPDATE_SCRIPT@|$UPDATE_SCRIPT|g" \
    "$SCRIPT_DIR/$1" >"$tmp/$2"
}
render 2004scape-update.service.template 2004scape-update.service
render 2004scape-update.rules.template 2004scape-update.rules
cp "$SCRIPT_DIR/2004scape-update.timer" "$tmp/"
rc=0
grep -nE '@[A-Za-z0-9_]+@' "$tmp"/* || rc=$?
case "$rc" in
  0) printf 'error: unrendered template placeholder above\n' >&2; exit 1 ;;
  1) ;;
  *) printf 'error: cannot scan the rendered files\n' >&2; exit 1 ;;
esac
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/2004scape-update.service" "$tmp/2004scape-update.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install %s/2004scape-update.service (User=%s, ExecStart %s)\n' "$UNIT_DIR" "$SERVICE_USER" "$UPDATE_SCRIPT"
  printf '[dry-run] install %s/2004scape-update.timer\n' "$UNIT_DIR"
  printf '[dry-run] install polkit rule %s (restart game-backup.service)\n' "$POLKIT_RULE"
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now 2004scape-update.timer\n'
  exit 0
fi
install -o root -g root -m 644 "$tmp/2004scape-update.service" "$UNIT_DIR/2004scape-update.service"
install -o root -g root -m 644 "$tmp/2004scape-update.timer" "$UNIT_DIR/2004scape-update.timer"
# polkitd watches rules.d and reloads on its own.
install -o root -g root -m 644 "$tmp/2004scape-update.rules" "$POLKIT_RULE"
systemctl daemon-reload
systemctl enable --now 2004scape-update.timer
printf 'Installed. Next run: systemctl list-timers 2004scape-update.timer\n'
