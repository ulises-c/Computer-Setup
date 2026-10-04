#!/usr/bin/env bash
set -euo pipefail

# OnFailure hook for dragonwilds-player-log.service. Runs as the service user,
# like the auto-updater, because this checkout and its .env belong to that user.
# The timer fires every minute, so a broken parser alerts at most every 6 hours.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"
: "${PLAYER_LOG_ALERT_STAMP:=$SCRIPT_DIR/status/.player-log-alerted}"

readonly UNIT=dragonwilds-player-log.service
readonly REPEAT_SECONDS=21600

if [[ -z "$NTFY_URL" || -z "$NTFY_TOPIC" ]]; then
  printf 'warning: NTFY_URL/NTFY_TOPIC unset; %s failure not alerted\n' "$UNIT" >&2
  exit 0
fi

if [[ -f "$PLAYER_LOG_ALERT_STAMP" ]] \
  && (( $(date +%s) - $(date -r "$PLAYER_LOG_ALERT_STAMP" +%s) < REPEAT_SECONDS )); then
  exit 0
fi

detail="$(journalctl -u "$UNIT" -n 50 -o cat --no-pager 2>/dev/null | grep '^error:' | tail -n 1 || true)"
body="Player history is not being recorded. ${detail:-See the journal.} Check: journalctl -u $UNIT"

auth=()
[[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
if ! curl -fsS -m 15 "${auth[@]}" \
  -H "Title: Dragonwilds player log FAILED" -H "Priority: high" -H "Tags: video_game,warning" \
  -d "${body:0:1000}" "$NTFY_URL/$NTFY_TOPIC" >/dev/null; then
  printf 'error: ntfy alert for %s failed\n' "$UNIT" >&2
  exit 1
fi
touch "$PLAYER_LOG_ALERT_STAMP"
