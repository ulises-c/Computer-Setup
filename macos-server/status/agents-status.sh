#!/usr/bin/env bash
set -euo pipefail

# Writes status/www/agents.json for the Homepage cards: one entry per watched
# LaunchAgent with its state from `launchctl list` (no extra process probes).
# Run every minute by net.computer-setup.host-status. Watched agents come from
# AGENTS in status/.env ("name=label ..."), defaulting to the repo-managed ones.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${STATUS_OUT_DIR:-$SCRIPT_DIR/www}"
AGENTS="glances=net.computer-setup.glances forgejo-runner=net.forgejo.runner mlx-server=net.computer-setup.mlx-server mac-backup=net.computer-setup.mac-backup"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  value="$(grep -E '^AGENTS=' "$SCRIPT_DIR/.env" | tail -1 | cut -d= -f2- || true)"
  value="${value#\"}"
  value="${value%\"}"
  [[ -n "$value" ]] && AGENTS="$value"
fi

listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
launchctl list >"$listing"

entries=()
for pair in $AGENTS; do
  name="${pair%%=*}"
  label="${pair#*=}"
  [[ "$name" =~ ^[a-z0-9-]+$ && "$label" =~ ^[A-Za-z0-9._-]+$ ]] || continue
  read -r pid code < <(awk -v l="$label" '$3 == l { print $1, $2 }' "$listing") || true
  if [[ -z "${pid:-}" ]]; then
    state="not loaded"
  elif [[ "$pid" == - && ( "$code" == 0 || "$code" == -15 ) ]]; then
    # -15: stopped on purpose with SIGTERM (inference/run.sh stop).
    state="stopped"
  elif [[ "$pid" == - ]]; then
    state="stopped · exit $code"
  else
    state="running"
  fi
  entries+=("$(jq -cn --arg name "$name" --arg label "$label" --arg state "$state" \
    --arg pid "${pid:--}" --arg code "${code:-}" \
    '{name:$name, label:$label, state:$state, pid:(if $pid == "-" then null else ($pid|tonumber) end), last_exit:(if $code == "" then null else ($code|tonumber? // $code) end)}')")
  unset pid code
done

mkdir -p "$OUT_DIR"
tmp="$(mktemp "$OUT_DIR/.agents.XXXXXX")"
printf '%s\n' ${entries[@]+"${entries[@]}"} | jq -s --argjson updated "$(date +%s)" '{
  updated: $updated,
  running: (map(select(.state == "running")) | length),
  total: length,
  agents: (map({key: .name, value: .}) | from_entries),
  rows: map({name: .name, label: .state})
}' >"$tmp"
chmod 644 "$tmp"
mv -f "$tmp" "$OUT_DIR/agents.json"
