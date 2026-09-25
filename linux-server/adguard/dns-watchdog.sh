#!/usr/bin/env bash
set -euo pipefail

# AdGuard DNS watchdog, run every minute by dns-watchdog.timer. Probes host :53
# on loopback and the LAN address; after consecutive failures, while a public
# resolver still answers (so AdGuard, not the internet, is at fault), it brings
# adguardhome back and alerts ntfy. Everything else is left alone.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
CONTAINER=adguardhome
STATE_DIR="${STATE_DIRECTORY:-/var/lib/dns-watchdog}"

log() { printf '[dns-watchdog] %s\n' "$*"; }

# Read one key from the user-owned .env without sourcing it (this runs as root).
env_value() {
  local v
  [[ -f "$SCRIPT_DIR/.env" ]] || return 0
  v="$(grep -E "^$1=" "$SCRIPT_DIR/.env" | tail -1 | cut -d= -f2- || true)"
  if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then
    v="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$v"
}

NTFY_URL="$(env_value NTFY_URL)"
NTFY_TOPIC="$(env_value NTFY_TOPIC)"
NTFY_TOKEN="$(env_value NTFY_TOKEN)"
KUMA_PUSH_URL="$(env_value KUMA_PUSH_URL)"
PROBE_NAME="$(env_value WATCHDOG_PROBE_NAME)"
: "${NTFY_TOPIC:=server-dns}"
: "${PROBE_NAME:=example.com}"
[[ "$PROBE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { printf 'error: WATCHDOG_PROBE_NAME is not a hostname: %s\n' "$PROBE_NAME" >&2; exit 1; }
FAILS_BEFORE_ACTION=2
COOLDOWN_SECONDS=600
REFERENCE_RESOLVERS=(9.9.9.9 1.1.1.1)

notify() {
  local title="$1" priority="$2" tags="$3" msg="$4"
  [[ -n "$NTFY_URL" ]] || return 0
  local args=(-fsS -m 10 -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$msg")
  [[ -n "$NTFY_TOKEN" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl "${args[@]}" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

kuma_push() {
  [[ -n "$KUMA_PUSH_URL" ]] || return 0
  curl -fsS -m 10 -G --data-urlencode "status=$1" --data-urlencode "msg=$2" \
    "$KUMA_PUSH_URL" >/dev/null 2>&1 || true
}

# dig exits 0 on any reply, SERVFAIL included: only silence counts as down.
answers() {
  dig +time=3 +tries=2 +short @"$1" "$PROBE_NAME" A >/dev/null 2>&1
}

state_get() { cat "$STATE_DIR/$1" 2>/dev/null || printf '%s' "$2"; }
state_set() { printf '%s' "$2" >"$STATE_DIR/$1"; }

mkdir -p "$STATE_DIR"
fails="$(state_get fails 0)"
last_action="$(state_get last_action 0)"
alerted="$(state_get alerted 0)"

lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
probes=(127.0.0.1)
[[ -n "$lan_ip" ]] && probes+=("$lan_ip")

down=()
for addr in "${probes[@]}"; do
  answers "$addr" || down+=("$addr")
done

if [[ ${#down[@]} -eq 0 ]]; then
  if [[ "$alerted" == 1 ]]; then
    notify "AdGuard DNS recovered" default white_check_mark "answering on ${probes[*]} again"
    log "recovered"
  fi
  state_set fails 0
  state_set alerted 0
  kuma_push up "answering on ${probes[*]}"
  exit 0
fi

fails=$((fails + 1))
state_set fails "$fails"
log "no answer from ${down[*]} (failure $fails)"
kuma_push down "no answer from ${down[*]}"

# A brief blip (e.g. the one dockerd restart in linux-server/README.md step 8)
# resolves itself; only a sustained outage gets acted on.
(( fails >= FAILS_BEFORE_ACTION )) || exit 0

internet=false
for r in "${REFERENCE_RESOLVERS[@]}"; do
  if answers "$r"; then internet=true; break; fi
done
if [[ "$internet" == false ]]; then
  log "public resolvers are silent too — internet outage, not restarting AdGuard"
  exit 0
fi

# Docker restarting or down is dockerd's (and systemd's) job to recover, not ours.
if ! docker info >/dev/null 2>&1; then
  log "docker is not reachable — leaving it to systemd"
  if [[ "$alerted" == 0 ]]; then
    notify "AdGuard DNS down" urgent rotating_light "docker daemon unreachable — check: systemctl status docker"
    state_set alerted 1
  fi
  exit 0
fi

now="$(date +%s)"
if (( now - last_action < COOLDOWN_SECONDS )); then
  log "within cooldown of the last recovery attempt — waiting"
  exit 0
fi

state_set last_action "$now"
running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || printf 'missing')"
if [[ "$running" == true ]]; then
  action=(docker restart "$CONTAINER")
else
  # Covers stopped, crashed, or removed (network included): compose recreates it.
  action=(docker compose -f "$COMPOSE_FILE" --project-directory "$SCRIPT_DIR" up -d "$CONTAINER")
fi
log "recovery (container was: $running): ${action[*]}"
if ! out="$("${action[@]}" 2>&1)"; then
  log "recovery command failed: $out"
fi
ran="${action[*]}"

sleep 5
if answers "${down[0]}"; then
  notify "AdGuard DNS restored" high warning "was silent ~${fails}min on ${down[*]}; ran: $ran"
  state_set fails 0
  state_set alerted 0
  kuma_push up "restored by watchdog"
else
  notify "AdGuard DNS down" urgent rotating_light "still silent on ${down[*]} after: $ran — next attempt in $((COOLDOWN_SECONDS / 60))min. Check: docker logs $CONTAINER; ss -lunp 'sport = :53'"
  state_set alerted 1
fi
