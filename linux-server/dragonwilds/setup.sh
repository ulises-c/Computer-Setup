#!/usr/bin/env bash
set -euo pipefail

# Installs the systemd units, ufw rules, and status container for the Dragonwilds
# dedicated server. The game itself is installed separately by steamcmd — see
# README.md.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DRY_RUN=false

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'error: unknown argument: %s\n' "$1" >&2; exit 1 ;;
esac

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

readonly APPID=4019830
readonly UNIT_DIR=/etc/systemd/system
readonly POLKIT_RULE=/etc/polkit-1/rules.d/50-dragonwilds-restart.rules
: "${SERVICE_USER:=${SUDO_USER:-$(id -un)}}"
: "${STEAMCMD:=/usr/games/steamcmd}"
: "${SERVER_PORT:=7777}"
: "${LAN_CIDR:=}"

# sed renders these into unit files, so a quoted path would break the templates.
if ! [[ "$SCRIPT_DIR" =~ ^/[[:alnum:]_./-]+$ ]]; then
  printf 'error: unsupported character in checkout path: %s\n' "$SCRIPT_DIR" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false && $EUID -ne 0 ]]; then
  printf 'error: run with sudo: sudo bash %s\n' "$0" >&2
  exit 1
fi

if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || (( SERVER_PORT < 1024 || SERVER_PORT > 65535 )); then
  printf 'error: SERVER_PORT must be a number from 1024 to 65535, got: %s\n' "$SERVER_PORT" >&2
  exit 1
fi

# Also rendered into the polkit rule, which is JavaScript.
if ! [[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  printf 'error: unsupported service user name: %s\n' "$SERVICE_USER" >&2
  exit 1
fi
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  printf 'error: no such user: %s\n' "$SERVICE_USER" >&2
  exit 1
fi
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"
: "${DRAGONWILDS_INSTALL_DIR:=$(getent passwd "$SERVICE_USER" | cut -d: -f6)/games/dragonwilds}"

if ! [[ "$DRAGONWILDS_INSTALL_DIR" =~ ^/[[:alnum:]_./-]+$ ]]; then
  printf 'error: unsupported character in install path: %s\n' "$DRAGONWILDS_INSTALL_DIR" >&2
  exit 1
fi

[[ -x "$STEAMCMD" ]] || \
  printf 'warning: %s not found — install steamcmd first (apt install steamcmd)\n' "$STEAMCMD" >&2
game_installed=true
if [[ ! -x "$DRAGONWILDS_INSTALL_DIR/RSDragonwildsServer.sh" ]]; then
  game_installed=false
  printf 'warning: %s not installed yet — run the steamcmd app_update from README.md\n' "$DRAGONWILDS_INSTALL_DIR" >&2
fi

# The player count and join code come from the unit's journal, read as this user.
# Without access the card shows no players, and the auto-updater refuses to
# restart because it cannot prove the server is empty.
if ! id -nG "$SERVICE_USER" | tr ' ' '\n' | grep -qxE 'adm|systemd-journal'; then
  printf 'warning: %s cannot read the system journal — run: sudo usermod -aG systemd-journal %s\n' \
    "$SERVICE_USER" "$SERVICE_USER" >&2
fi

# The server boots without an OwnerId but then refuses to create a world, which
# is easy to miss in the log.
config="$DRAGONWILDS_INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
if [[ -r "$config" ]] && ! grep -qE '^OwnerId=.+' "$config"; then
  printf 'warning: OwnerId is empty in %s — set it before the server can host a world\n' "$config" >&2
fi

run() {
  if [[ "$DRY_RUN" == true ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() {
  local src="$1" dest="$2"
  sed -e "s|@USER@|$SERVICE_USER|g" \
      -e "s|@GROUP@|$SERVICE_GROUP|g" \
      -e "s|@INSTALL_DIR@|$DRAGONWILDS_INSTALL_DIR|g" \
      -e "s|@STEAMCMD@|$STEAMCMD|g" \
      -e "s|@APPID@|$APPID|g" \
      -e "s|@SERVER_PORT@|$SERVER_PORT|g" \
      -e "s|@STATUS_SCRIPT@|$SCRIPT_DIR/dragonwilds-status.sh|g" \
      -e "s|@STATUS_JSON@|$SCRIPT_DIR/status/dragonwilds-status.json|g" \
      -e "s|@UPDATE_CHECK_SCRIPT@|$SCRIPT_DIR/dragonwilds-update-check.sh|g" \
      -e "s|@LATEST_BUILD_FILE@|$SCRIPT_DIR/status/.latest-build|g" \
      -e "s|@NOTIFIED_BUILD_FILE@|$SCRIPT_DIR/status/.notified-build|g" \
      -e "s|@FAILED_BUILD_FILE@|$SCRIPT_DIR/status/.failed-build|g" \
      -e "s|@AUTO_UPDATE_SCRIPT@|$SCRIPT_DIR/dragonwilds-auto-update.sh|g" \
      "$src" > "$tmp/$dest"
}

render "$SCRIPT_DIR/dragonwilds.service.template" dragonwilds.service
render "$SCRIPT_DIR/dragonwilds-status.service.template" dragonwilds-status.service
render "$SCRIPT_DIR/dragonwilds-update-check.service.template" dragonwilds-update-check.service
render "$SCRIPT_DIR/dragonwilds-auto-update.service.template" dragonwilds-auto-update.service
render "$SCRIPT_DIR/dragonwilds-restart.rules.template" dragonwilds-restart.rules

if command -v systemd-analyze >/dev/null; then
  # verify rejects an ExecStart that does not exist yet, which would abort a
  # first-time setup run before the game is installed.
  verify_units=()
  [[ "$game_installed" == true ]] && verify_units+=("$tmp/dragonwilds.service")
  systemd-analyze verify "${verify_units[@]}" "$tmp/dragonwilds-status.service" \
    "$tmp/dragonwilds-update-check.service" "$tmp/dragonwilds-auto-update.service" \
    "$SCRIPT_DIR/dragonwilds-status.timer" "$SCRIPT_DIR/dragonwilds-update-check.timer" \
    "$SCRIPT_DIR/dragonwilds-auto-update.timer"
fi

if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] install rendered units into %s/\n' "$UNIT_DIR"
  printf '[dry-run] install polkit rule %s\n' "$POLKIT_RULE"
else
  install -o root -g root -m 644 "$tmp/dragonwilds.service" "$UNIT_DIR/dragonwilds.service"
  install -o root -g root -m 644 "$tmp/dragonwilds-status.service" "$UNIT_DIR/dragonwilds-status.service"
  install -o root -g root -m 644 "$SCRIPT_DIR/dragonwilds-status.timer" "$UNIT_DIR/dragonwilds-status.timer"
  install -o root -g root -m 644 "$tmp/dragonwilds-update-check.service" "$UNIT_DIR/dragonwilds-update-check.service"
  install -o root -g root -m 644 "$SCRIPT_DIR/dragonwilds-update-check.timer" "$UNIT_DIR/dragonwilds-update-check.timer"
  install -o root -g root -m 644 "$tmp/dragonwilds-auto-update.service" "$UNIT_DIR/dragonwilds-auto-update.service"
  install -o root -g root -m 644 "$SCRIPT_DIR/dragonwilds-auto-update.timer" "$UNIT_DIR/dragonwilds-auto-update.timer"
  # polkitd watches rules.d and reloads on its own.
  install -o root -g root -m 644 "$tmp/dragonwilds-restart.rules" "$POLKIT_RULE"
  chmod 755 "$SCRIPT_DIR/dragonwilds-update-check.sh" "$SCRIPT_DIR/dragonwilds-auto-update.sh" \
    "$SCRIPT_DIR/dragonwilds-players.sh"
  # Holds NTFY_TOKEN; a cp of .env.example lands world-readable.
  [[ -f "$SCRIPT_DIR/.env" ]] && chmod 600 "$SCRIPT_DIR/.env"
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 755 "$SCRIPT_DIR/status"
  chmod 755 "$SCRIPT_DIR/dragonwilds-status.sh"
fi

run systemctl daemon-reload
# Starting before the game is installed would run the whole first download inside
# ExecStartPre; do that explicitly (README.md), then start the unit.
if [[ "$game_installed" == true ]]; then
  run systemctl enable --now dragonwilds.service
else
  run systemctl enable dragonwilds.service
  printf 'note: dragonwilds.service enabled but not started — install the game, then: sudo systemctl start dragonwilds.service\n' >&2
fi
run systemctl enable --now dragonwilds-status.timer
run systemctl enable --now dragonwilds-update-check.timer
run systemctl enable --now dragonwilds-auto-update.timer

# LAN and tailnet only — running this never implies a router port-forward.
if [[ -z "$LAN_CIDR" ]]; then
  default_iface="$(ip -4 route show default | awk '{print $5; exit}')"
  [[ -n "$default_iface" ]] && \
    LAN_CIDR="$(ip -4 route show dev "$default_iface" proto kernel scope link | awk '{print $1; exit}')"
fi
if [[ -n "$LAN_CIDR" ]]; then
  run ufw allow proto udp from "$LAN_CIDR" to any port "$SERVER_PORT" comment 'dragonwilds (LAN)'
else
  printf 'warning: could not detect the LAN subnet — set LAN_CIDR in .env\n' >&2
fi
if ip link show tailscale0 >/dev/null 2>&1; then
  run ufw allow in on tailscale0 proto udp to any port "$SERVER_PORT" comment 'dragonwilds (tailnet)'
fi
# ufw records rules while inactive and reports success, so the lines above can
# succeed while enforcing nothing. The game binds 0.0.0.0, so say so.
# (`ufw status` needs root, hence skipped on a non-root dry run.)
if [[ $EUID -eq 0 ]] && ufw status 2>/dev/null | grep -qx 'Status: inactive'; then
  printf 'warning: ufw is inactive — the rules above are saved but NOT enforced; UDP %s, 8888 and 45453 are open to any network that can reach this host\n' \
    "$SERVER_PORT" >&2
fi

run docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

printf 'Installed. Status: systemctl status dragonwilds.service\n'
printf 'Logs:      journalctl -u dragonwilds.service -f\n'
