#!/usr/bin/env bash
set -euo pipefail

# Installs the AdGuard DNS watchdog timer (dns-watchdog.sh) as a system unit.

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
command -v dig >/dev/null || { printf 'error: dig not installed (apt install bind9-dnsutils)\n' >&2; exit 1; }
if [[ "$DRY_RUN" == false ]]; then
  [[ $EUID -eq 0 ]] || { printf 'error: run with sudo: sudo bash %s\n' "$0" >&2; exit 1; }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sed "s|@WATCHDOG_SCRIPT@|$SCRIPT_DIR/dns-watchdog.sh|g" \
  "$SCRIPT_DIR/dns-watchdog.service.template" > "$tmp/dns-watchdog.service"
if command -v systemd-analyze >/dev/null; then
  systemd-analyze verify "$tmp/dns-watchdog.service" "$SCRIPT_DIR/dns-watchdog.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install dns-watchdog.service and dns-watchdog.timer into /etc/systemd/system\n'
  printf '[dry-run] systemctl daemon-reload\n'
  printf '[dry-run] systemctl enable --now dns-watchdog.timer\n'
else
  install -o root -g root -m 644 "$tmp/dns-watchdog.service" /etc/systemd/system/dns-watchdog.service
  install -o root -g root -m 644 "$SCRIPT_DIR/dns-watchdog.timer" /etc/systemd/system/dns-watchdog.timer
  systemctl daemon-reload
  systemctl enable --now dns-watchdog.timer
  printf 'Installed and enabled dns-watchdog.timer\n'
fi
