#!/usr/bin/env bash
set -euo pipefail

# Writes the JSON behind the homepage "dragonwilds" card, served by the loopback
# nginx in this folder's docker-compose.yml. Run on a 1-minute systemd timer
# (dragonwilds-status.timer); safe to run by hand.
#
# The game server is a host systemd unit rather than a container, so the card
# cannot key off Docker state — "running" here means the unit is active *and*
# holding its UDP socket.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${DRAGONWILDS_INSTALL_DIR:=$HOME/games/dragonwilds}"
: "${STATUS_JSON:=$SCRIPT_DIR/status/dragonwilds-status.json}"
: "${SERVER_PORT:=7777}"

readonly UNIT=dragonwilds.service
readonly APPID=4019830
config="$DRAGONWILDS_INSTALL_DIR/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
savegames="$DRAGONWILDS_INSTALL_DIR/RSDragonwilds/Saved/SaveGames"
manifest="$DRAGONWILDS_INSTALL_DIR/steamapps/appmanifest_$APPID.acf"

ini_get() {
  local key="$1"
  [[ -r "$config" ]] || return 0
  sed -n "s/^$key=\(.*\)$/\1/p" "$config" | head -1 | tr -d '\r'
}

json_escape() { printf '%s' "${1-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

state="$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null || true)"
case "$state" in
  active) status=running ;;
  activating) status=starting ;;
  failed) status=failed ;;
  "") status=unknown ;;
  *) status=stopped ;;
esac

uptime_seconds=0
started="$(systemctl show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null || true)"
if [[ "$status" == running && -n "$started" ]]; then
  if started_epoch="$(date -d "$started" +%s 2>/dev/null)"; then
    uptime_seconds=$(( $(date +%s) - started_epoch ))
    (( uptime_seconds < 0 )) && uptime_seconds=0
  fi
fi

# Roughly 30s of asset loading separates process start from the socket opening,
# so an active unit alone would show "running" while nobody can connect yet.
listening=false
if ss -uln 2>/dev/null | grep -qE "(^|[^0-9.]):$SERVER_PORT\b"; then
  listening=true
elif [[ "$status" == running ]]; then
  status=starting
fi

server_name="$(ini_get ServerName)"
world_name="$(ini_get DefaultWorldName)"
[[ -n "$(ini_get OwnerId)" ]] && owner_configured=true || owner_configured=false
[[ -n "$(ini_get WorldPassword)" ]] && world_password=true || world_password=false

build=""
if [[ -r "$manifest" ]]; then
  build="$(sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$manifest" | head -1)"
fi

# The newest .sav is the one the server reloads on startup.
last_save=""
if [[ -d "$savegames" ]]; then
  newest="$(find "$savegames" -maxdepth 1 -name '*.sav' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  [[ -n "$newest" ]] && last_save="$(date -u -d "@$(stat -c %Y "$newest")" +%Y-%m-%dT%H:%M:%SZ)"
fi

mkdir -p "$(dirname "$STATUS_JSON")"
tmp="$(mktemp "$(dirname "$STATUS_JSON")/.status.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<EOF
{
  "status": "$status",
  "server_name": "$(json_escape "$server_name")",
  "world": "$(json_escape "$world_name")",
  "uptime_seconds": $uptime_seconds,
  "listening": $listening,
  "owner_configured": $owner_configured,
  "world_password": $world_password,
  "build": "$(json_escape "$build")",
  "last_save": "$last_save",
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
chmod 644 "$tmp"
# Rename so nginx never serves a half-written file.
mv "$tmp" "$STATUS_JSON"
trap - EXIT
