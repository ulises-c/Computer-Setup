#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${1:?usage: install-sync.sh <game-server-ssh-alias> [--curated|--accounts-only]}"
SYNC_MODE_ARG='--no-curated'
INPUTS_ARG='--no-bot-inputs'
if [[ ${2:-} == --curated || ${2:-} == --accounts-only ]]; then
  SYNC_MODE_ARG="$2"
elif [[ $# -gt 1 ]]; then
  printf 'error: expected --curated or --accounts-only (upgrade receiver first)\n' >&2
  exit 1
fi
[[ $# -le 2 ]] || { printf 'error: too many arguments\n' >&2; exit 1; }
if [[ "$SYNC_MODE_ARG" == --accounts-only ]]; then
  INPUTS_ARG='--bot-inputs'
fi
[[ "$SSH_HOST" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'error: use an SSH alias\n' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { printf 'error: this sync installer is for the source Mac\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../macos-server/lib.sh"
mkdir -p "$HOME/Library/Caches/computer-setup/rs-sdk-portal"
render_plist "$SCRIPT_DIR/net.computer-setup.rs-sdk-portal-sync.plist.template" net.computer-setup.rs-sdk-portal-sync \
  "PYTHON=$(command -v python3)" "SYNC=$SCRIPT_DIR/sync.py" "SSH_HOST=$SSH_HOST" "SYNC_MODE_ARG=$SYNC_MODE_ARG" "INPUTS_ARG=$INPUTS_ARG"
agent_load net.computer-setup.rs-sdk-portal-sync
printf 'Source sync installed (every two minutes).\n'
