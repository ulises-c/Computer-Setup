#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ $# -eq 0 && $EUID -ne 0 ]] || { printf 'usage: bash %s (as the game user)\n' "$0" >&2; exit 1; }
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi
: "${DRAGONWILDS_INSTALL_DIR:=$HOME/games/dragonwilds}"
: "${SSH_CONNECTION:=}"
: "${SSH_PORT:=${SSH_CONNECTION##* }}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT > 0 && SSH_PORT <= 65535 )) || {
  printf 'error: set SSH_PORT to the actual SSH listener port (or run from an SSH session)\n' >&2; exit 1;
}
# shellcheck source=linux-game-server/dragonwilds/maintenance.sh
source "$SCRIPT_DIR/maintenance.sh"
maintenance_hold -x
maintenance_check

validate_world() {
  local world saved_world
  [[ -x "$DRAGONWILDS_INSTALL_DIR/RSDragonwildsServer.sh" ]] || {
    maintenance_error 'game launcher is missing'; return 1;
  }
  world="$(python3 - "$DRAGONWILDS_INSTALL_DIR" <<'PY'
import configparser
from pathlib import Path
import sys

try:
    saved = Path(sys.argv[1]) / 'RSDragonwilds/Saved'
    config = configparser.ConfigParser(interpolation=None)
    config.read(saved / 'Config/LinuxServer/DedicatedServer.ini')
    settings = config['/Script/Dominion.DedicatedServerSettings']
    if not all(settings.get(key, '').strip() for key in ('OwnerId', 'ServerGuid', 'ServerName', 'DefaultWorldName')):
        raise ValueError()
    world = settings['DefaultWorldName'].strip()
    if world in ('.', '..') or '/' in world or '\\' in world or '\n' in world:
        raise ValueError()
    if not (saved / 'SaveGames' / (world + '.sav')).is_file():
        raise ValueError()
except (OSError, KeyError, ValueError, configparser.Error):
    sys.exit('error: migrated config/world is missing or invalid; no config values were printed')
print(world)
PY
)"
  saved_world="$(bash "$SCRIPT_DIR/read-save-info.sh" \
    "$DRAGONWILDS_INSTALL_DIR/RSDragonwilds/Saved/SaveGames/$world.sav" | sed -n 's/^world name : //p')"
  [[ "$saved_world" == "$world" ]] || { maintenance_error 'config, save filename and save header disagree'; return 1; }
}

firewall_active() {
  local status
  status="$(sudo ufw status verbose)"
  grep -qx 'Status: active' <<< "$status" && grep -q 'Default: \(deny\|reject\) (incoming)' <<< "$status" || {
    maintenance_error 'UFW must already be active with default deny/reject incoming; preserve SSH before enabling it'; return 1;
  }
}

firewall_ready() {
  local status
  firewall_active
  status="$(sudo ufw status verbose)"
  grep -qE "^${SSH_PORT}/tcp[[:space:]].*ALLOW IN" <<< "$status" || {
    maintenance_error 'SSH-preserving UFW rule is not confirmed'; return 1;
  }
}

validate_world
firewall_active
sudo ufw allow "$SSH_PORT/tcp" comment 'Dragonwilds SSH access'
firewall_ready
# The inherited installer uses enable --now. Persistent conditions keep every game/update start blocked.
sudo bash "$SCRIPT_DIR/setup.sh"
maintenance_check
validate_world
firewall_ready
maintenance_release
trap 'maintenance_block; maintenance_stop' ERR
sudo systemctl start dragonwilds.service
sudo systemctl is-active --quiet dragonwilds.service
sudo systemctl start "${MAINTENANCE_TIMERS[@]}"
trap - ERR
printf 'Dragonwilds activated. Confirm the imported world loaded and test a player connection.\n'
