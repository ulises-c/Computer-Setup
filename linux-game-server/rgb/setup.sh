#!/usr/bin/env bash
set -euo pipefail

# Install the RGB status exporter: a root-owned copy of rgb-status.py run by a
# timer every 10 minutes, writing /var/lib/host-status/rgb.json for the
# Homepage top bar (served at /host-status/ by serve.sh).
#
#   sudo bash linux-game-server/rgb/setup.sh [--dry-run]

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac
run() {
  if [[ "$DRY_RUN" == true ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}
[[ "$DRY_RUN" == true || $EUID -eq 0 ]] || { printf 'error: run with sudo\n' >&2; exit 1; }
command -v openrgb >/dev/null || { printf 'error: openrgb is not installed\n' >&2; exit 1; }

run install -D -o root -g root -m 755 "$HERE/rgb-status.py" /usr/local/libexec/rgb-status
run install -o root -g root -m 644 "$HERE/rgb-status.service" "$HERE/rgb-status.timer" /etc/systemd/system/
run install -d -o root -g root -m 755 /var/lib/host-status
run systemctl daemon-reload
run systemctl enable --now rgb-status.timer
run systemctl start rgb-status.service
[[ "$DRY_RUN" == true ]] || printf 'ok: %s\n' "$(head -c 300 /var/lib/host-status/rgb.json)"
