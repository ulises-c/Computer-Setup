#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DRY_RUN=false

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

if ! [[ "$SCRIPT_DIR" =~ ^/[[:alnum:]_./-]+$ ]]; then
  printf 'error: unsupported character in checkout path: %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi
if [[ "$DRY_RUN" == false ]]; then
  [[ $EUID -eq 0 ]] || { printf 'error: run with sudo: sudo bash %s\n' "$0" >&2; exit 1; }
  [[ -f "$SCRIPT_DIR/.env" ]] || { printf 'error: create %s/.env before installing\n' "$SCRIPT_DIR" >&2; exit 1; }
  chmod 600 "$SCRIPT_DIR/.env"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_unit() {
  local src="$1" dest="$2"
  sed \
    -e "s|@BACKUP_SCRIPT@|$SCRIPT_DIR/backup.sh|g" \
    -e "s|@BACKUP_ENV@|$SCRIPT_DIR/.env|g" \
    "$src" > "$tmp/$dest"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] install %s as /etc/systemd/system/%s\n' "$src" "$dest"
  else
    install -o root -g root -m 644 "$tmp/$dest" "/etc/systemd/system/$dest"
  fi
}

render_unit "$SCRIPT_DIR/pi-backup.service.template" pi-backup.service
render_unit "$SCRIPT_DIR/pi-backup-failure.service.template" pi-backup-failure.service
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/pi-backup.service" "$tmp/pi-backup-failure.service" "$SCRIPT_DIR/pi-backup.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install %s as /etc/systemd/system/pi-backup.timer\n' "$SCRIPT_DIR/pi-backup.timer"
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now pi-backup.timer\n'
else
  install -o root -g root -m 644 "$SCRIPT_DIR/pi-backup.timer" /etc/systemd/system/pi-backup.timer
  systemctl daemon-reload
  systemctl enable --now pi-backup.timer
  printf 'Installed and enabled pi-backup.timer\n'
fi
