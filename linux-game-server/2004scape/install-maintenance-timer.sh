#!/usr/bin/env bash
set -euo pipefail

# Installs the 2004Scape maintenance: 2004scape-maintenance.{service,timer}
# running maintenance.sh as the login user, and a polkit rule letting that user
# start game-backup.service and game-backup-restore-check.service (the backup
# of the stopped games and its check). --dry-run prints the plan.
#
# Usage: sudo bash linux-game-server/2004scape/install-maintenance-timer.sh [--dry-run]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly UNIT_DIR=/etc/systemd/system
readonly POLKIT_RULE=/etc/polkit-1/rules.d/60-2004scape-maintenance.rules
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
MAINTENANCE_SCRIPT="$SCRIPT_DIR/maintenance.sh"
[[ "$MAINTENANCE_SCRIPT" =~ ^/[[:alnum:]_./-]+$ ]] \
  || { printf 'error: unsupported character in checkout path: %s\n' "$MAINTENANCE_SCRIPT" >&2; exit 1; }
for unit in game-backup.service game-backup-restore-check.service; do
  if [[ "$(systemctl show "$unit" -p LoadState --value 2>/dev/null)" != loaded ]]; then
    printf 'warning: %s is not installed (sudo bash linux-game-server/backup/setup.sh); maintenance refuses to run until it is\n' "$unit" >&2
  fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
render() {
  sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@GROUP@|$SERVICE_GROUP|g" -e "s|@MAINTENANCE_SCRIPT@|$MAINTENANCE_SCRIPT|g" \
    "$SCRIPT_DIR/$1" >"$tmp/$2"
}
render 2004scape-maintenance.service.template 2004scape-maintenance.service
render 2004scape-maintenance.rules.template 2004scape-maintenance.rules
cp "$SCRIPT_DIR/2004scape-maintenance.timer" "$tmp/"
rc=0
grep -nE '@[A-Za-z0-9_]+@' "$tmp"/* || rc=$?
case "$rc" in
  0) printf 'error: unrendered template placeholder above\n' >&2; exit 1 ;;
  1) ;;
  *) printf 'error: cannot scan the rendered files\n' >&2; exit 1 ;;
esac
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/2004scape-maintenance.service" "$tmp/2004scape-maintenance.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install %s/2004scape-maintenance.service (User=%s, ExecStart %s)\n' "$UNIT_DIR" "$SERVICE_USER" "$MAINTENANCE_SCRIPT"
  printf '[dry-run] install %s/2004scape-maintenance.timer\n' "$UNIT_DIR"
  printf '[dry-run] install polkit rule %s (start game-backup.service, game-backup-restore-check.service)\n' "$POLKIT_RULE"
  printf '[dry-run] systemctl disable --now 2004scape-update.timer (if installed; leaves any active update running)\n'
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now 2004scape-maintenance.timer\n'
  exit 0
fi
if [[ "$(systemctl show 2004scape-update.timer -p LoadState --value)" == loaded ]]; then
  systemctl disable --now 2004scape-update.timer
fi
if systemctl is-active --quiet 2004scape-update.service; then
  printf 'error: an old update is still running; wait for it to finish before installing maintenance\n' >&2
  exit 1
fi
install -o root -g root -m 644 "$tmp/2004scape-maintenance.service" "$UNIT_DIR/2004scape-maintenance.service"
install -o root -g root -m 644 "$tmp/2004scape-maintenance.timer" "$UNIT_DIR/2004scape-maintenance.timer"
# polkitd watches rules.d and reloads on its own.
install -o root -g root -m 644 "$tmp/2004scape-maintenance.rules" "$POLKIT_RULE"
systemctl daemon-reload
systemctl enable --now 2004scape-maintenance.timer
printf 'Installed. Next run: systemctl list-timers 2004scape-maintenance.timer\n'
