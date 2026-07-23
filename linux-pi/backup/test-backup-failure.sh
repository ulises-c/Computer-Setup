#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_notifier() {
  local ntfy_url="${1:-}"
  local kuma_push_url="${2:-}"

  STATUS_JSON="$tmp/status.json" \
    NTFY_URL="$ntfy_url" \
    NTFY_TOPIC=pi-backup-test \
    NTFY_TOKEN='' \
    KUMA_PUSH_URL="$kuma_push_url" \
    bash "$SCRIPT_DIR/backup.sh" notify-failure
}

run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]

jq -n '{status:"success", last_run:"previous"}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]

jq -n '{status:"failed", last_run:"detailed", duration_seconds:42, notifier_pending:true}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.last_run' "$tmp/status.json")" == detailed ]]
[[ "$(jq -r '.duration_seconds' "$tmp/status.json")" == 42 ]]
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == false ]]

jq -n '{status:"failed", last_run:"stale", duration_seconds:42, notifier_pending:false}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]
[[ "$(jq -r '.last_run' "$tmp/status.json")" != stale ]]

jq -n '{status:"running", last_run:"interrupted", notifier_pending:false}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]
[[ "$(jq -r '.last_run' "$tmp/status.json")" != interrupted ]]

cp "$SCRIPT_DIR/backup.sh" "$tmp/backup.sh"
if STATUS_JSON="$tmp/status.json" NTFY_URL=not-a-url bash "$tmp/backup.sh" >/dev/null 2>&1; then
  printf 'FAIL: invalid early notification input unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == true ]]
run_notifier
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == false ]]

rm -f "$tmp/status.json"
run_notifier not-a-url also-not-a-url
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]]

printf 'backup failure notifier tests: PASSED\n'
