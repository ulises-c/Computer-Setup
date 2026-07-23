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
sed "s|@RUNNER_STATUS_SCRIPT@|$SCRIPT_DIR/runner-status.sh|g" \
  "$SCRIPT_DIR/forgejo-runner-status.service.template" > "$tmp/forgejo-runner-status.service"

if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/forgejo-runner-status.service" "$SCRIPT_DIR/forgejo-runner-status.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install rendered forgejo-runner-status.service\n'
  printf '[dry-run] install forgejo-runner-status.timer\n'
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now forgejo-runner-status.timer\n'
else
  install -o root -g root -m 644 "$tmp/forgejo-runner-status.service" /etc/systemd/system/forgejo-runner-status.service
  install -o root -g root -m 644 "$SCRIPT_DIR/forgejo-runner-status.timer" /etc/systemd/system/forgejo-runner-status.timer
  systemctl daemon-reload
  systemctl enable --now forgejo-runner-status.timer
  printf 'Installed and enabled forgejo-runner-status.timer\n'
fi
