#!/usr/bin/env bash
set -euo pipefail

# Writes the JSON behind the homepage "dragonwilds" card, served by the loopback
# nginx in this folder's docker-compose.yml. Run on a 5-second systemd timer
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
: "${MAX_PLAYERS:=6}"
: "${LATEST_BUILD_FILE:=$SCRIPT_DIR/status/.latest-build}"
: "${STATUS_HISTORY_FILE:=$SCRIPT_DIR/.metrics/history.json}"
: "${BACKUP_STATUS_JSON:=/var/lib/computer-setup-backup/game-backup/backup-status.json}"

# Keep configuration loading in this entrypoint for both scheduled and manual runs.
if [[ "${1:-}" != --slow ]]; then
  exec python3 "$SCRIPT_DIR/fast_status.py"
fi

command -v jq >/dev/null || { printf 'error: jq not installed (apt install jq)\n' >&2; exit 1; }
[[ "$MAX_PLAYERS" =~ ^[1-9][0-9]*$ ]] || { printf 'error: MAX_PLAYERS must be a positive integer\n' >&2; exit 1; }

# Serialize timer/manual refreshes, including journal collection and publication.
# The lock and bounded history live outside the nginx-served directory.
mkdir -p "$(dirname "$STATUS_HISTORY_FILE")"
chmod 700 "$(dirname "$STATUS_HISTORY_FILE")"
exec 9>"$(dirname "$STATUS_HISTORY_FILE")/.status.lock"
flock -x 9

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
ports="$(ss -uln 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' || true)"
if grep -qx "$SERVER_PORT" <<<"$ports"; then
  listening=true
elif [[ "$status" == running ]]; then
  status=starting
fi

# Both the join code and the player list come from this run's journal only: the
# code is minted per session, and connections from a previous boot are long dead.
invocation="$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)"
game_version="unknown"

join_code=""
world_id=""
world_owner=""
players=0
players_max="$MAX_PLAYERS"
player_names=""
if [[ "$status" == running && -n "$invocation" ]]; then
  run_log="$(journalctl -u "$UNIT" "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat 2>/dev/null || true)"
  version="$(sed -nE 's/.*LogNetVersion: Set ProjectVersion to ([0-9]+(\.[0-9]+)+)\..*/\1/p' <<<"$run_log" | tail -1)"
  [[ -n "$version" ]] && game_version="$version"

  join_code="$(printf '%s\n' "$run_log" \
    | grep -oE '"JoinCode"\] written with key\[[a-z]+\] value\[[A-Z0-9-]+\]' \
    | tail -1 | grep -oE '[A-Z0-9]{4}-[A-Z0-9]{4}' || true)"

  loaded="$(printf '%s\n' "$run_log" | grep -oE 'World load SUCCEEDED .*' | tail -1 || true)"
  world_id="$(grep -oE 'Guid\[[0-9A-F]{32}\]' <<<"$loaded" | head -1 | cut -c6-13 || true)"
  world_owner="$(grep -oE 'OwnerName\[[^]]*\]' <<<"$loaded" | head -1 | sed -E 's/^OwnerName\[(.*)\]$/\1/' || true)"

  # Shared with dragonwilds-auto-update.sh, which needs the same live answer.
  # A failed read must not abort the whole refresh and freeze the card.
  if counted="$("$SCRIPT_DIR/dragonwilds-players.sh" "$UNIT")"; then
    players="${counted%%$'\t'*}"
    player_names="${counted#*$'\t'}"
  else
    players=null
    player_names="unknown (journal unreadable)"
  fi
fi

server_name="$(ini_get ServerName)"
world_name="$(ini_get DefaultWorldName)"
join_password="$(ini_get WorldPassword)"
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

# Allocated on-disk footprint of this game's installation, including Saved;
# never substitute host filesystem free space for game-specific storage.
if ! install_bytes="$(du -s -B1 -- "$DRAGONWILDS_INSTALL_DIR" 2>/dev/null | cut -f1)"; then
  install_bytes=null
fi
[[ "$install_bytes" =~ ^[0-9]+$ ]] || install_bytes=null

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

# The server loads DefaultWorldName.sav; any other .sav is an idle world, so the
# newest file is not necessarily the live one.
last_save=""
save_bytes=0
worlds_on_disk=""
world_count=0
if [[ -d "$savegames" ]]; then
  world_save="$savegames/$world_name.sav"
  if [[ -n "$world_name" && -f "$world_save" ]]; then
    last_save="$(date -u -d "@$(stat -c %Y "$world_save")" +%Y-%m-%dT%H:%M:%SZ)"
    save_bytes="$(stat -c %s "$world_save" 2>/dev/null || echo 0)"
  fi
  worlds_on_disk="$(find "$savegames" -maxdepth 1 -type f -name '*.sav' -printf '%f\n' 2>/dev/null \
    | sed 's/\.sav$//' | sort | paste -sd, - | sed 's/,/, /g')"
  [[ -n "$worlds_on_disk" ]] && world_count="$(tr ',' '\n' <<<"$worlds_on_disk" | wc -l | tr -d ' ')"
fi

# Fast metrics/history are added by fast_status.py after this cached scan.
metrics="{}"
# A restart during this refresh invalidates the earlier journal version.
if [[ "$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)" != "$invocation" ]]; then
  game_version=unknown
fi

# Reads the journal backwards and stops at the first match, so it stays cheap.
last_join=""
last_join_name=""
join_line="$(journalctl -u "$UNIT" -r -n 1 --no-pager -o short-unix --grep 'Join succeeded: ' 2>/dev/null || true)"
if [[ "$join_line" =~ ^([0-9]+)\. ]]; then
  last_join="$(date -u -d "@${BASH_REMATCH[1]}" +%Y-%m-%dT%H:%M:%SZ)"
  last_join_name="$(sed -nE 's/.*Join succeeded: (.*)$/\1/p' <<<"$join_line" | tr -d '\r' | cut -c1-40)"
fi

auto_update="off"
systemctl is-active --quiet dragonwilds-auto-update.timer 2>/dev/null && auto_update="on"

backup_status="unknown"
last_backup=""
if [[ -r "$BACKUP_STATUS_JSON" ]]; then
  backup_status="$(jq -r '.status // "unknown"' "$BACKUP_STATUS_JSON" 2>/dev/null || printf unknown)"
  last_backup="$(jq -r '.last_run // ""' "$BACKUP_STATUS_JSON" 2>/dev/null || true)"
fi

online_capacity="$players/$players_max"
[[ "$players" == null ]] && online_capacity="unknown / $players_max"

# A blank row reads as a broken widget; an em dash reads as "nobody".
[[ -z "$player_names" ]] && player_names="—"
[[ -z "$last_join_name" ]] && last_join_name="—"

mkdir -p "$(dirname "$STATUS_JSON")"
tmp="$(mktemp "$(dirname "$STATUS_JSON")/.status.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# jq builds the document rather than a heredoc: the values below come from an
# operator-editable ini and from log output, and a hand-rolled escaper missed
# control characters — a tab in ServerName produced invalid JSON and a blank card.
# --arg always yields a string, --argjson an already-valid number or boolean.
jq -n \
  --arg status "$status" \
  --arg game_version "$game_version" \
  --argjson metrics "$metrics" \
  --arg server_name "$server_name" \
  --arg world "$world_name" \
  --arg join_password "$join_password" \
  --arg join_code "$join_code" \
  --arg online_capacity "$online_capacity" \
  --arg player_names "$player_names" \
  --arg connect_lan "$connect_lan" \
  --arg connect_tailnet "$connect_tailnet" \
  --arg build "$build" \
  --arg latest_build "$latest_build" \
  --arg update_status "$update_status" \
  --arg update_checked "$update_checked" \
  --arg last_save "$last_save" \
  --arg world_id "$world_id" \
  --arg world_owner "$world_owner" \
  --arg worlds_on_disk "$worlds_on_disk" \
  --arg last_join "$last_join" \
  --arg last_join_name "$last_join_name" \
  --arg auto_update "$auto_update" \
  --arg backup_status "$backup_status" \
  --arg last_backup "$last_backup" \
  --argjson world_count "$world_count" \
  --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson players "$players" \
  --argjson players_max "$players_max" \
  --argjson save_bytes "$save_bytes" \
  --argjson install_bytes "$install_bytes" \
  --argjson uptime_seconds "$uptime_seconds" \
  --argjson listening "$listening" \
  --argjson owner_configured "$owner_configured" \
  --argjson world_password "$world_password" \
  '{
    status: $status,
    game_version: $game_version,
    server_name: $server_name,
    world: $world,
    join_code: $join_code,
    join_password: $join_password,
    players: $players,
    players_max: $players_max,
    online_capacity: $online_capacity,
    player_names: $player_names,
    connect_lan: $connect_lan,
    connect_tailnet: $connect_tailnet,
    save_bytes: $save_bytes,
    install_bytes: $install_bytes,
    installation_footprint: (if $install_bytes == null then "unknown" else
      (($install_bytes / 1073741824 * 100 | floor) / 100 | tostring) + " GiB" end),
    uptime_seconds: $uptime_seconds,
    listening: $listening,
    owner_configured: $owner_configured,
    world_password: $world_password,
    build: $build,
    latest_build: $latest_build,
    update_status: $update_status,
    update_checked: $update_checked,
    last_save: $last_save,
    world_id: $world_id,
    world_owner: $world_owner,
    worlds_on_disk: $worlds_on_disk,
    world_count: $world_count,
    last_join: $last_join,
    last_join_name: $last_join_name,
    auto_update: $auto_update,
    backup_status: $backup_status,
    last_backup: $last_backup,
    updated: $updated
  } + $metrics' > "$tmp"
chmod 644 "$tmp"
# Rename so nginx never serves a half-written file.
mv "$tmp" "$STATUS_JSON"
trap - EXIT
