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
: "${LATEST_BUILD_FILE:=$SCRIPT_DIR/status/.latest-build}"

command -v jq >/dev/null || { printf 'error: jq not installed (apt install jq)\n' >&2; exit 1; }

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
# Compare the port field exactly. A regex on the whole line cannot: the local
# address ends in a digit ("0.0.0.0:7777"), and a bare ":7777" would also match
# a peer column or a longer port.
if ss -uln 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | grep -qx "$SERVER_PORT"; then
  listening=true
elif [[ "$status" == running ]]; then
  status=starting
fi

# Both the join code and the player list come from this run's journal only: the
# code is minted per session, and connections from a previous boot are long dead.
since=""
[[ -n "$started" ]] && since="$(date -d "$started" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"

join_code=""
players=0
player_names=""
if [[ "$status" == running && -n "$since" ]]; then
  run_log="$(journalctl -u "$UNIT" --since "$since" --no-pager 2>/dev/null || true)"

  join_code="$(printf '%s\n' "$run_log" \
    | grep -oE '"JoinCode"\] written with key\[[a-z]+\] value\[[A-Z0-9-]+\]' \
    | tail -1 | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' || true)"

  # Shared with dragonwilds-auto-update.sh, which needs the same live answer.
  # A failed read must not abort the whole refresh and freeze the card.
  if counted="$("$SCRIPT_DIR/dragonwilds-players.sh" "$UNIT")"; then
    players="${counted%%$'\t'*}"
    player_names="${counted#*$'\t'}"
  else
    player_names="unknown (journal unreadable)"
  fi
fi

server_name="$(ini_get ServerName)"
world_name="$(ini_get DefaultWorldName)"
[[ -n "$(ini_get OwnerId)" ]] && owner_configured=true || owner_configured=false
[[ -n "$(ini_get WorldPassword)" ]] && world_password=true || world_password=false

# The address to paste into the client's Direct field — it does not resolve
# hostnames. Derive the LAN address from the default route: picking "the first
# global address" would land on one of the host's many Docker bridges.
connect_lan=""
default_iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "$default_iface" ]]; then
  lan_ip="$(ip -4 -o addr show dev "$default_iface" scope global 2>/dev/null \
    | awk '{sub(/\/.*/, "", $4); print $4; exit}')"
  [[ -n "$lan_ip" ]] && connect_lan="$lan_ip:$SERVER_PORT"
fi
connect_tailnet=""
if command -v tailscale >/dev/null 2>&1; then
  ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
  [[ -n "$ts_ip" ]] && connect_tailnet="$ts_ip:$SERVER_PORT"
fi

# Empty for an inactive unit, so it cannot be emitted as a bare JSON value.
memory_bytes="$(systemctl show "$UNIT" -p MemoryCurrent --value 2>/dev/null || true)"
[[ "$memory_bytes" =~ ^[0-9]+$ ]] || memory_bytes=0

disk_free_bytes="$(df -B1 --output=avail "$DRAGONWILDS_INSTALL_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
[[ "$disk_free_bytes" =~ ^[0-9]+$ ]] || disk_free_bytes=0

build=""
if [[ -r "$manifest" ]]; then
  build="$(sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$manifest" | head -1)"
fi

# Written by dragonwilds-update-check.timer, which is the only thing that talks
# to Steam — keep this path free of network calls, it runs every minute.
latest_build=""
update_checked=""
update_status="unknown"
if [[ -r "$LATEST_BUILD_FILE" ]]; then
  read -r latest_build update_checked < "$LATEST_BUILD_FILE" || true
  if [[ "$latest_build" =~ ^[0-9]+$ && "$build" =~ ^[0-9]+$ ]]; then
    if [[ "$latest_build" == "$build" ]]; then
      update_status="up to date"
    else
      update_status="update available ($latest_build)"
    fi
  fi
fi

# The newest .sav is the one the server reloads on startup.
last_save=""
save_bytes=0
if [[ -d "$savegames" ]]; then
  newest="$(find "$savegames" -maxdepth 1 -name '*.sav' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
  if [[ -n "$newest" ]]; then
    last_save="$(date -u -d "@$(stat -c %Y "$newest")" +%Y-%m-%dT%H:%M:%SZ)"
    save_bytes="$(stat -c %s "$newest" 2>/dev/null || echo 0)"
  fi
fi

# A blank row reads as a broken widget; an em dash reads as "nobody".
[[ -z "$player_names" ]] && player_names="—"

mkdir -p "$(dirname "$STATUS_JSON")"
tmp="$(mktemp "$(dirname "$STATUS_JSON")/.status.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# jq builds the document rather than a heredoc: the values below come from an
# operator-editable ini and from log output, and a hand-rolled escaper missed
# control characters — a tab in ServerName produced invalid JSON and a blank card.
# --arg always yields a string, --argjson an already-valid number or boolean.
jq -n \
  --arg status "$status" \
  --arg server_name "$server_name" \
  --arg world "$world_name" \
  --arg join_code "$join_code" \
  --arg player_names "$player_names" \
  --arg connect_lan "$connect_lan" \
  --arg connect_tailnet "$connect_tailnet" \
  --arg build "$build" \
  --arg latest_build "$latest_build" \
  --arg update_status "$update_status" \
  --arg update_checked "$update_checked" \
  --arg last_save "$last_save" \
  --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson players "$players" \
  --argjson players_max 6 \
  --argjson memory_bytes "$memory_bytes" \
  --argjson save_bytes "$save_bytes" \
  --argjson disk_free_bytes "$disk_free_bytes" \
  --argjson uptime_seconds "$uptime_seconds" \
  --argjson listening "$listening" \
  --argjson owner_configured "$owner_configured" \
  --argjson world_password "$world_password" \
  '{
    status: $status,
    server_name: $server_name,
    world: $world,
    join_code: $join_code,
    players: $players,
    players_max: $players_max,
    player_names: $player_names,
    connect_lan: $connect_lan,
    connect_tailnet: $connect_tailnet,
    memory_bytes: $memory_bytes,
    save_bytes: $save_bytes,
    disk_free_bytes: $disk_free_bytes,
    uptime_seconds: $uptime_seconds,
    listening: $listening,
    owner_configured: $owner_configured,
    world_password: $world_password,
    build: $build,
    latest_build: $latest_build,
    update_status: $update_status,
    update_checked: $update_checked,
    last_save: $last_save,
    updated: $updated
  }' > "$tmp"
chmod 644 "$tmp"
# Rename so nginx never serves a half-written file.
mv "$tmp" "$STATUS_JSON"
trap - EXIT
