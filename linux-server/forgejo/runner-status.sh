#!/usr/bin/env bash
set -euo pipefail

# Server-side check that the Mac mini Forgejo Actions runner is connected.
# Surfaces the result three ways: a JSON file for the homepage card, an Uptime
# Kuma push, and an ntfy alert when the runner transitions offline (and when it
# recovers). Run on a 2-minute systemd timer (forgejo-runner-status.timer).
#
# "Up" means Forgejo's API currently reports the runner as idle/active — i.e.
# the server actually sees it connected, not merely that the host pings. The
# runner itself lives in macOS/forgejo-runner/.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${RUNNER_NAME:=m4-mini}"
: "${FORGEJO_DOMAIN:?set FORGEJO_DOMAIN in .env}"
# Endpoint that lists runners. Defaults to the instance (admin) scope; override
# in .env if your token is org/repo-scoped instead.
: "${FORGEJO_RUNNER_API_URL:=https://${FORGEJO_DOMAIN}/api/v1/admin/actions/runners}"
: "${FORGEJO_RUNNER_API_TOKEN:?set FORGEJO_RUNNER_API_TOKEN in .env (a Forgejo token that can read runners)}"
: "${STATUS_JSON:=$SCRIPT_DIR/runner-status/runner-status.json}"
: "${STATE_FILE:=$SCRIPT_DIR/runner-status/.last-state}"
: "${KUMA_PUSH_URL:=}"
: "${NTFY_TOPIC:=server-runner}"

command -v jq >/dev/null || { printf 'error: jq not installed (apt install jq)\n' >&2; exit 1; }

notify() {
  local title="$1" priority="$2" tags="$3" msg="$4"
  [[ -n "${NTFY_URL:-}" ]] || return 0
  local args=(-fsS -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$msg")
  [[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl "${args[@]}" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

kuma_push() {
  local status="$1" msg="$2"
  [[ -n "$KUMA_PUSH_URL" ]] || return 0
  curl -fsS -G \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" \
    "$KUMA_PUSH_URL" >/dev/null 2>&1 || true
}

# --- query Forgejo ----------------------------------------------------------
resp="$(curl -fsS -m 10 -H "Authorization: token $FORGEJO_RUNNER_API_TOKEN" \
  "$FORGEJO_RUNNER_API_URL" 2>/dev/null || true)"

# The list endpoint may return a bare array or a {runners|entries:[...]} wrapper.
runners='[]'
if [[ -n "$resp" ]]; then
  runners="$(jq -c 'if type=="array" then . else (.runners // .entries // .data // []) end' <<<"$resp" 2>/dev/null || echo '[]')"
fi

runner="$(jq -c --arg n "$RUNNER_NAME" 'map(select(.name==$n)) | .[0] // {}' <<<"$runners")"
status="$(jq -r '.status // "unknown"' <<<"$runner")"
busy="$(jq -r 'if .busy == true then true else false end' <<<"$runner")"

state=down
case "$status" in
  idle | active) state=up ;;
esac

# --- homepage JSON ----------------------------------------------------------
mkdir -p "$(dirname "$STATUS_JSON")"
jq -n \
  --arg state "$state" \
  --arg status "$status" \
  --arg runner "$RUNNER_NAME" \
  --argjson busy "$busy" \
  --arg checked "$(date -u +%FT%TZ)" \
  '{state:$state, status:$status, runner:$runner, busy:$busy, checked:$checked}' \
  >"$STATUS_JSON"

# --- Uptime Kuma ------------------------------------------------------------
if [[ "$state" == up ]]; then
  kuma_push up "$RUNNER_NAME: $status"
else
  kuma_push down "$RUNNER_NAME: $status — Forgejo does not see the runner"
fi

# --- ntfy, only on a state change ------------------------------------------
prev="$(cat "$STATE_FILE" 2>/dev/null || true)"
if [[ -z "$prev" ]]; then
  printf '%s\n' "$state" >"$STATE_FILE"   # seed on first run, no alert
elif [[ "$state" != "$prev" ]]; then
  if [[ "$state" == down ]]; then
    notify "Forgejo runner DOWN" urgent rotating_light \
      "$RUNNER_NAME is $status — Forgejo no longer sees the runner. Check the Mac mini: bash macOS/forgejo-runner/run.sh status"
  else
    notify "Forgejo runner recovered" default white_check_mark "$RUNNER_NAME is back ($status)"
  fi
  printf '%s\n' "$state" >"$STATE_FILE"
fi

printf '[runner-status] %s: %s (%s)\n' "$RUNNER_NAME" "$state" "$status"
