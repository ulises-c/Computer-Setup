#!/usr/bin/env bash
set -euo pipefail

# Install or inspect this host's repo-managed LaunchAgents.
#
#   bash macos-server/agents.sh install [--dry-run]   # render + reload (active backup deferred)
#   bash macos-server/agents.sh status                # loaded / running / last exit
#
# Agents (labels):
#   net.computer-setup.glances       Glances web server + API on 127.0.0.1:61208
#   net.computer-setup.host-status   writes status/www/agents.json every minute
#   net.computer-setup.mac-backup    nightly restic backup at 03:00 (only once backup/.env exists)
#   net.computer-setup.mlx-server    mlx_lm.server, installed but off: inference/run.sh start
# The Forgejo runner keeps its own installer (forgejo-runner/install.sh).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=macos-server/lib.sh
source "$SCRIPT_DIR/lib.sh"

cmd="${1:-}"
[[ "${2:-}" == --dry-run ]] && DRY_RUN=true
[[ $# -le 2 ]] || die "too many arguments"

env_value() {
  local file="$1" key="$2" value=""
  [[ -f "$file" ]] && value="$(grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- || true)"
  value="${value%$'\r'}"
  [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"
  printf '%s' "${value/#\~/$HOME}"
}

install_glances() {
  local conf="$SCRIPT_DIR/glances/glances.conf" hosts="localhost,127.0.0.1" domain
  domain="$(tailnet_domain)"
  [[ -n "$domain" ]] && hosts+=",$domain"
  [[ "$hosts" =~ ^[A-Za-z0-9.,-]+$ ]] || die "unexpected tailnet name: $domain"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] write %s (allowed hosts: %s)\n' "${conf#"$REPO_ROOT"/}" "$hosts"
  else
    sed "s|@ALLOWED_HOSTS@|$hosts|" "$SCRIPT_DIR/glances/glances.conf.in" >"$conf"
  fi
  render_plist "$SCRIPT_DIR/glances/net.computer-setup.glances.plist.template" net.computer-setup.glances \
    "CONF=$conf"
  agent_load net.computer-setup.glances
}

install_host_status() {
  [[ "$DRY_RUN" == true ]] || mkdir -p "$SCRIPT_DIR/status/www"
  render_plist "$SCRIPT_DIR/status/net.computer-setup.host-status.plist.template" net.computer-setup.host-status
  agent_load net.computer-setup.host-status
}

install_backup() {
  if [[ ! -f "$SCRIPT_DIR/backup/.env" ]]; then
    printf 'skip mac-backup: create backup/.env first (backup/connect.sh, see README.md)\n'
    return
  fi
  [[ "$DRY_RUN" == true ]] || chmod 600 "$SCRIPT_DIR/backup/.env"
  render_plist "$SCRIPT_DIR/backup/net.computer-setup.mac-backup.plist.template" net.computer-setup.mac-backup
  agent_load net.computer-setup.mac-backup
}

install_inference() {
  local env="$SCRIPT_DIR/inference/.env" model port
  model="$(env_value "$env" MLX_MODEL)"
  port="$(env_value "$env" MLX_PORT)"
  model="${model:-$HOME/.models/mlx-community--Qwen3.5-9B-4bit}"
  port="${port:-8080}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "MLX_PORT must be a number"
  [[ "$model" =~ ^/[[:alnum:]_./+-]+$ ]] || die "MLX_MODEL must be an absolute path"
  [[ -d "$model" || "$DRY_RUN" == true ]] || printf 'warning: model directory %s does not exist yet\n' "$model" >&2
  render_plist "$SCRIPT_DIR/inference/net.computer-setup.mlx-server.plist.template" net.computer-setup.mlx-server \
    "MODEL=$model" "PORT=$port"
  # RunAtLoad is false: loading registers the agent without starting the model.
  agent_load net.computer-setup.mlx-server
}

status() {
  local label state
  printf '%-34s %s\n' LABEL STATE
  for label in net.computer-setup.glances net.computer-setup.host-status net.computer-setup.mac-backup \
      net.computer-setup.mlx-server net.forgejo.runner; do
    state="$(agent_state "$label")"
    if [[ -z "$state" ]]; then
      state="not loaded"
    elif [[ "${state%% *}" == - ]]; then
      state="stopped (last exit ${state##* })"
    else
      state="running (pid ${state%% *})"
    fi
    printf '%-34s %s\n' "$label" "$state"
  done
}

case "$cmd" in
  install)
    command -v jq >/dev/null || [[ "$DRY_RUN" == true ]] || die "jq is required (brew install jq)"
    install_glances
    install_host_status
    install_backup
    install_inference
    ;;
  status) status ;;
  *) printf 'usage: bash %s install [--dry-run] | status\n' "$0" >&2; exit 1 ;;
esac
