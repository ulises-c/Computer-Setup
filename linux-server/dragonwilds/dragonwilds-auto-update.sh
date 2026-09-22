#!/usr/bin/env bash
set -euo pipefail

# Restart the server onto a new build, but only while nobody is playing.
#
# The build itself is downloaded by the service's own ExecStartPre; this script
# decides *when* that restart is allowed to happen. It runs as root because it
# calls systemctl, which is why it never invokes steamcmd itself — network work
# stays in dragonwilds-update-check.sh, running unprivileged on its own timer.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${DRAGONWILDS_INSTALL_DIR:=$HOME/games/dragonwilds}"
: "${LATEST_BUILD_FILE:=$SCRIPT_DIR/status/.latest-build}"
: "${NOTIFIED_BUILD_FILE:=$SCRIPT_DIR/status/.notified-build}"
: "${AUTO_UPDATE_RESTART:=true}"
: "${SERVER_PORT:=7777}"
: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"

readonly UNIT=dragonwilds.service
readonly APPID=4019830
manifest="$DRAGONWILDS_INSTALL_DIR/steamapps/appmanifest_$APPID.acf"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

notify() {
  local title="$1" body="$2" priority="${3:-default}"
  [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
  local -a auth=()
  [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 "${auth[@]}" \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: video_game" \
    -d "$body" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 \
    || log "warning: ntfy notification failed"
}

installed=""
[[ -r "$manifest" ]] && installed="$(sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$manifest" | head -1)"
latest=""
[[ -r "$LATEST_BUILD_FILE" ]] && read -r latest _ < "$LATEST_BUILD_FILE" || true

if [[ ! "$installed" =~ ^[0-9]+$ || ! "$latest" =~ ^[0-9]+$ ]]; then
  log "no usable build numbers yet (installed='$installed' latest='$latest')"
  exit 0
fi
if [[ "$installed" == "$latest" ]]; then
  exit 0
fi

# Announce a given build once, however many times this timer fires before the
# server is actually free to restart.
notified=""
[[ -r "$NOTIFIED_BUILD_FILE" ]] && read -r notified < "$NOTIFIED_BUILD_FILE" || true
if [[ "$notified" != "$latest" ]]; then
  notify "Dragonwilds update available" \
    "Build $latest is out (running $installed). Will restart when the server is empty." \
    default
  mkdir -p "$(dirname "$NOTIFIED_BUILD_FILE")"
  printf '%s\n' "$latest" > "$NOTIFIED_BUILD_FILE"
fi

if [[ "$AUTO_UPDATE_RESTART" != true ]]; then
  log "update $latest available; AUTO_UPDATE_RESTART is off, leaving it alone"
  exit 0
fi

# Fail closed: only an explicit count of zero allows a restart. An unreadable
# journal must never be mistaken for an empty server.
if ! counted="$("$SCRIPT_DIR/dragonwilds-players.sh" "$UNIT")"; then
  log "update $latest available; deferring, cannot determine who is online"
  exit 0
fi
players="${counted%%$'\t'*}"
if [[ "$players" != 0 ]]; then
  log "update $latest available; deferring, $players player(s) online"
  exit 0
fi

log "update $latest available and nobody online — restarting $UNIT"
systemctl restart "$UNIT"

# ExecStartPre downloads the build before the server starts, so the socket can
# take a while to come back. Confirm rather than assume.
for _ in $(seq 1 60); do
  if ss -uln 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | grep -qx "$SERVER_PORT"; then
    new="$(sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$manifest" | head -1)"
    log "back up on build $new"
    notify "Dragonwilds updated" "Server restarted onto build $new (was $installed)." low
    exit 0
  fi
  sleep 10
done

log "error: server did not come back within 10 minutes"
notify "Dragonwilds update FAILED" \
  "Restarted for build $latest but the server never bound UDP $SERVER_PORT. Check: systemctl status $UNIT" \
  high
exit 1
