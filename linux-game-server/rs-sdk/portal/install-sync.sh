#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${1:?usage: install-sync.sh <game-server-ssh-alias>}"
[[ "$SSH_HOST" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'error: use an SSH alias\n' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { printf 'error: this sync installer is for the source Mac\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../macos-server/lib.sh"
mkdir -p "$HOME/Library/Caches/computer-setup/rs-sdk-portal"
render_plist "$SCRIPT_DIR/net.computer-setup.rs-sdk-portal-sync.plist.template" net.computer-setup.rs-sdk-portal-sync \
  "PYTHON=$(command -v python3)" "SYNC=$SCRIPT_DIR/sync.py" "SSH_HOST=$SSH_HOST"
agent_load net.computer-setup.rs-sdk-portal-sync
printf 'Read-only source sync installed (every two minutes).\n'
