#!/usr/bin/env bash
set -euo pipefail

# Deploys NUT (Network UPS Tools) config for the CyberPower CST135UC2 to
# /etc/nut and enables the services. Idempotent — re-runs are no-ops unless a
# config changed. Run as root: sudo bash setup.sh [--dry-run]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

if [[ "$DRY_RUN" == false && $EUID -ne 0 ]]; then
  die "must run as root: sudo bash $0"
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
elif [[ "$DRY_RUN" == true ]]; then
  UPSMON_PASSWORD=dryrun
else
  die "no .env — cp .env.example .env, then set UPSMON_PASSWORD (openssl rand -hex 16)"
fi

[[ -n "${UPSMON_PASSWORD:-}" ]] || die "UPSMON_PASSWORD is empty in .env — generate with: openssl rand -hex 16"
[[ "$UPSMON_PASSWORD" =~ ^[[:alnum:]]+$ ]] || die "UPSMON_PASSWORD must be alphanumeric (it is rendered into configs with sed)"
[[ -z "${NTFY_URL:-}" || "${NTFY_URL:-}" =~ ^https?://[^[:space:]]+$ ]] || die "NTFY_URL must be an http(s) URL without whitespace"
[[ "${NTFY_TOPIC:-server-ups}" != *$'\n'* && "${NTFY_TOPIC:-server-ups}" != *$'\r'* ]] || die "NTFY_TOPIC cannot contain a newline"
[[ "${NTFY_TOKEN:-}" != *$'\n'* && "${NTFY_TOKEN:-}" != *$'\r'* ]] || die "NTFY_TOKEN cannot contain a newline"

if ! command -v upsdrvctl >/dev/null; then
  if [[ "$DRY_RUN" == true ]]; then
    printf 'warning: NUT is not installed yet — run: sudo apt install nut\n' >&2
  else
    die "NUT is not installed — run: sudo apt install nut (or rerun the root setup.sh)"
  fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$SCRIPT_DIR/nut.conf" "$SCRIPT_DIR/ups.conf" "$SCRIPT_DIR/upsd.conf" "$SCRIPT_DIR/ups-notify.sh" "$SCRIPT_DIR/udev-ecoflow.rules" "$tmp/"
sed "s|@UPSMON_PASSWORD@|$UPSMON_PASSWORD|" "$SCRIPT_DIR/upsd.users.template" > "$tmp/upsd.users"
sed "s|@UPSMON_PASSWORD@|$UPSMON_PASSWORD|" "$SCRIPT_DIR/upsmon.conf.template" > "$tmp/upsmon.conf"
{
  printf 'NTFY_URL=%q\n' "${NTFY_URL:-}"
  printf 'NTFY_TOPIC=%q\n' "${NTFY_TOPIC:-server-ups}"
  printf 'NTFY_TOKEN=%q\n' "${NTFY_TOKEN:-}"
} > "$tmp/ups-notify.env"

changed=false
deploy() {
  local src="$1" dest="$2" mode="$3"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    run chown root:nut "$dest"
    run chmod "$mode" "$dest"
    printf '  ✓ %s\n' "$dest"
    return 0
  fi
  run install -o root -g nut -m "$mode" "$src" "$dest"
  changed=true
  printf '  installed %s\n' "$dest"
}

log "Deploying NUT configs to /etc/nut..."
ups_conf_changed=true
[[ -f /etc/nut/ups.conf ]] && cmp -s "$tmp/ups.conf" /etc/nut/ups.conf && ups_conf_changed=false
deploy "$tmp/nut.conf"        /etc/nut/nut.conf        640
deploy "$tmp/ups.conf"        /etc/nut/ups.conf        640
deploy "$tmp/upsd.conf"       /etc/nut/upsd.conf       640
deploy "$tmp/upsd.users"      /etc/nut/upsd.users      640
deploy "$tmp/upsmon.conf"     /etc/nut/upsmon.conf     640
deploy "$tmp/ups-notify.env"  /etc/nut/ups-notify.env  640
deploy "$tmp/ups-notify.sh"   /etc/nut/ups-notify.sh   750

udev_dest=/etc/udev/rules.d/65-nut-usbups-ecoflow.rules
udev_changed=false
if [[ -f "$udev_dest" ]] && cmp -s "$tmp/udev-ecoflow.rules" "$udev_dest"; then
  printf '  ✓ %s\n' "$udev_dest"
else
  run install -o root -g root -m 644 "$tmp/udev-ecoflow.rules" "$udev_dest"
  udev_changed=true
  changed=true
  printf '  installed %s\n' "$udev_dest"
fi
if [[ "$udev_changed" == true ]]; then
  run udevadm control --reload
  run udevadm trigger --subsystem-match=usb
fi

log "Enabling NUT services..."
run systemctl enable --now nut-driver@cyberpower.service nut-driver@ecoflow.service nut-server.service nut-monitor.service

if [[ "$changed" == true ]]; then
  log "Configs changed — restarting NUT..."
  if [[ "$ups_conf_changed" == true ]]; then
    run systemctl restart nut-driver@cyberpower.service nut-driver@ecoflow.service
  fi
  run systemctl restart nut-server.service nut-monitor.service
fi

if [[ "$DRY_RUN" == false ]]; then
  log "Verifying (drivers can take a few seconds to settle)..."
  sleep 3
  for ups in cyberpower ecoflow; do
    if status="$(upsc "$ups@localhost" ups.status 2>/dev/null)"; then
      log "$ups ups.status: $status (OL = on line power)"
    else
      printf 'warning: upsc could not reach the %s UPS yet — check: journalctl -u nut-driver@%s -u nut-server\n' "$ups" "$ups" >&2
    fi
  done
  log "Test a notification with:"
  printf '    sudo -u nut NOTIFYTYPE=ONBATT /etc/nut/ups-notify.sh "test event"\n'
fi
