#!/usr/bin/env bash
set -euo pipefail

# Restart the server onto a new build, but only while nobody is playing.
#
# The build itself is downloaded by the service's own ExecStartPre; this script
# decides *when* that restart is allowed to happen. It runs as the service user,
# not root: this checkout and its .env are writable by that same account (and so
# by a compromised game process), so a root run would hand them root. The one
# privileged action it needs — restarting this unit — is granted by the polkit
# rule setup.sh installs.

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
: "${FAILED_BUILD_FILE:=$SCRIPT_DIR/status/.failed-build}"
: "${AUTO_UPDATE_RESTART:=true}"
: "${SERVER_PORT:=7777}"
: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"

readonly UNIT=dragonwilds.service
readonly APPID=4019830
manifest="$DRAGONWILDS_INSTALL_DIR/steamapps/appmanifest_$APPID.acf"

log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*"; }

installed_info() {
  [[ -r "$manifest" ]] || return 0
  python3 "$SCRIPT_DIR/dragonwilds_update_metadata.py" installed "$manifest"
}

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
installed_manifest=""
installed_data="$(installed_info 2>/dev/null || true)"
read -r installed installed_manifest <<< "$installed_data" || true
latest=""
latest_manifest=""
[[ -r "$LATEST_BUILD_FILE" ]] && read -r latest _ latest_manifest < "$LATEST_BUILD_FILE" || true

# Old two-field metadata has no Linux depot manifest. Fail closed until the
# update-check timer writes the new three-field format; never restart on BuildID alone.
if [[ ! "$installed" =~ ^[0-9]+$ || ! "$installed_manifest" =~ ^[0-9]+$ \
   || ! "$latest" =~ ^[0-9]+$ || ! "$latest_manifest" =~ ^[0-9]+$ ]]; then
  log "no usable app build and Linux depot manifest yet (installed='$installed' depot='$installed_manifest' latest='$latest' depot='$latest_manifest')"
  exit 0
fi
if [[ "$installed_manifest" == "$latest_manifest" ]]; then
  exit 0
fi

update_key="linux-depot:$latest_manifest"

# Announce a Linux depot manifest once, however many timer ticks fire before the
# server is actually free to restart.
notified=""
[[ -r "$NOTIFIED_BUILD_FILE" ]] && read -r notified < "$NOTIFIED_BUILD_FILE" || true
if [[ "$notified" != "$update_key" ]]; then
  notify "Dragonwilds update available" \
    "App build $latest is out (installed app build $installed; Linux depot $latest_manifest). Will restart when the server is empty." \
    default
  mkdir -p "$(dirname "$NOTIFIED_BUILD_FILE")"
  printf '%s\n' "$update_key" > "$NOTIFIED_BUILD_FILE"
fi

if [[ "$AUTO_UPDATE_RESTART" != true ]]; then
  log "Linux depot update $latest_manifest available (app build $latest); AUTO_UPDATE_RESTART is off, leaving it alone"
  exit 0
fi

# A failed Linux depot install is not retried every 15 minutes; that would keep
# bouncing an empty server. A different app BuildID is not a retry if the depot
# is unchanged. An operator can retry through a manual service restart.
failed=""
[[ -r "$FAILED_BUILD_FILE" ]] && read -r failed < "$FAILED_BUILD_FILE" || true
if [[ "$failed" == "$update_key" ]]; then
  log "Linux depot update $latest_manifest previously failed to install; waiting for a manual restart or newer depot"
  exit 0
fi

# Fail closed: only an explicit count of zero allows a restart. An unreadable
# journal must never be mistaken for an empty server.
if ! counted="$("$SCRIPT_DIR/dragonwilds-players.sh" "$UNIT")"; then
  log "Linux depot update $latest_manifest available (app build $latest); deferring, cannot determine who is online"
  exit 0
fi
players="${counted%%$'\t'*}"
if [[ "$players" != 0 ]]; then
  log "Linux depot update $latest_manifest available (app build $latest); deferring, $players player(s) online"
  exit 0
fi

fail() {
  log "error: $1"
  printf '%s\n' "$update_key" > "$FAILED_BUILD_FILE"
  notify "Dragonwilds update FAILED" "$1 Check: systemctl status $UNIT" high
  exit 1
}

log "Linux depot update $latest_manifest available (app build $latest) and nobody online — restarting $UNIT"
# Blocks through ExecStartPre, i.e. the whole download.
systemctl --no-ask-password restart "$UNIT" \
  || fail "Restart for app build $latest / Linux depot $latest_manifest did not complete (download timed out or the unit failed to start)."

# ExecStartPre installs the depot before the server starts, so the socket can
# take a while to come back. Confirm the depot manifest rather than assume.
for _ in $(seq 1 60); do
  if ss -uln 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | grep -qx "$SERVER_PORT"; then
    new_data="$(installed_info 2>/dev/null || true)"
    new=""
    new_manifest=""
    read -r new new_manifest <<< "$new_data" || true
    # ExecStartPre's "-" lets a failed download start the old build, which looks
    # exactly like success from the socket alone.
    [[ "$new_manifest" == "$latest_manifest" ]] \
      || fail "Server is back up but Linux depot is $new_manifest, not $latest_manifest — the SteamCMD download did not install the target depot."
    log "back up on Linux depot $new_manifest (app build $new)"
    notify "Dragonwilds updated" "Server restarted onto Linux depot $new_manifest (app build $new; was $installed)." low
    exit 0
  fi
  sleep 10
done

fail "Restarted for build $latest but the server never bound UDP $SERVER_PORT within 10 minutes."
