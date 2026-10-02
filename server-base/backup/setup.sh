#!/usr/bin/env bash
set -euo pipefail

# Install a host's backup units. Run through the host's symlink
# (sudo bash <host>/backup/setup.sh); unit names come from its sources.sh and
# the unit templates are the host's own files next to it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DRY_RUN=false
unit="$(sed -n 's/^BACKUP_UNIT=//p' "$SCRIPT_DIR/sources.sh")"
prefix="${unit%.service}"
[[ "$prefix" =~ ^[a-z][a-z-]*$ ]] || { printf 'error: bad BACKUP_UNIT in %s/sources.sh\n' "$SCRIPT_DIR" >&2; exit 1; }

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

render_unit "$SCRIPT_DIR/$prefix.service.template" "$prefix.service"
render_unit "$SCRIPT_DIR/$prefix-failure.service.template" "$prefix-failure.service"
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/$prefix.service" "$tmp/$prefix-failure.service" "$SCRIPT_DIR/$prefix.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install %s as /etc/systemd/system/%s.timer\n' "$SCRIPT_DIR/$prefix.timer" "$prefix"
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now %s.timer\n' "$prefix"
else
  install -o root -g root -m 644 "$SCRIPT_DIR/$prefix.timer" "/etc/systemd/system/$prefix.timer"
  systemctl daemon-reload
  systemctl enable --now "$prefix.timer"
  printf 'Installed and enabled %s.timer\n' "$prefix"
fi
