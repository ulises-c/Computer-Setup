#!/usr/bin/env bash
set -euo pipefail

# Install the RGB keep-off service and the status exporter in one idempotent run.
#
#   sudo bash linux-game-server/rgb/setup.sh [--dry-run]
#
# - rgb-off (root-owned copy in /usr/local/libexec) forces every OpenRGB device to
#   #000000: rgb-off.service at boot (and on `systemctl start rgb-off.service`),
#   rgb-off-resume.service after suspend/hibernate. No periodic re-assert.
# - rgb-status (same directory) exports /var/lib/host-status/rgb.json every
#   10 minutes for the Homepage OpenRGB card, including the keep-off policy state.
# Both are started once at the end so the dashboard shows the result at once.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIBEXEC=/usr/local/libexec
UNITS=/etc/systemd/system
STATUS_DIR=/var/lib/host-status
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
command -v openrgb >/dev/null || [[ "$DRY_RUN" == true ]] || {
  printf 'error: openrgb is not installed (https://openrgb.org/releases.html, or apt install openrgb)\n' >&2
  exit 1
}

# Scripts live in a root-owned directory and are never run from this checkout.
run install -d -o root -g root -m 755 "$LIBEXEC" "$STATUS_DIR"
run install -o root -g root -m 755 "$HERE/rgb-status.py" "$LIBEXEC/rgb-status"
run install -o root -g root -m 755 "$HERE/rgb-off.py" "$LIBEXEC/rgb-off"
run install -o root -g root -m 644 "$HERE/rgb_common.py" "$LIBEXEC/rgb_common.py"
run install -o root -g root -m 644 \
  "$HERE/rgb-status.service" "$HERE/rgb-status.timer" \
  "$HERE/rgb-off.service" "$HERE/rgb-off-resume.service" "$UNITS/"
run systemctl daemon-reload
run systemctl enable rgb-off.service rgb-off-resume.service
run systemctl enable --now rgb-status.timer

# First apply now (a oneshot: this waits for it), then refresh the dashboard JSON.
off_rc=0
run systemctl start rgb-off.service || off_rc=$?
run systemctl start rgb-status.service

if [[ "$DRY_RUN" != true ]]; then
  printf 'enabled: %s\n' "$(systemctl is-enabled rgb-off.service rgb-off-resume.service rgb-status.timer 2>&1 | paste -sd' ' -)"
  printf 'policy:  %s\n' "$(head -c 400 "$STATUS_DIR/rgb-policy.json" 2>/dev/null || echo 'not written')"
  printf 'rgb.json: %s\n' "$(head -c 300 "$STATUS_DIR/rgb.json" 2>/dev/null || echo 'not written')"
  if [[ "$off_rc" -ne 0 ]]; then
    printf 'warning: rgb-off.service failed (exit %s); see: journalctl -u rgb-off -n 30\n' "$off_rc" >&2
    exit 1
  fi
fi
