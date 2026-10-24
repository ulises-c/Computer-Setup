#!/usr/bin/env bash
set -euo pipefail

# Install the live-map publisher on the bot workstation (macOS): a KeepAlive
# LaunchAgent that streams redacted fleet snapshots to the portal over SSH.
# The script is copied out of the checkout so branch switches can't break it.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SSH_HOST="${1:?usage: install-live-publisher.sh <game-server-ssh-alias> [TICKS>=10]}"
TICKS="${2:-10}"
[[ "$SSH_HOST" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'error: use an SSH alias\n' >&2; exit 1; }
[[ "$TICKS" =~ ^[0-9]+$ && "$TICKS" -ge 10 ]] || { printf 'error: TICKS must be an integer >= 10 (600 ms each)\n' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { printf 'error: this publisher installer is for the bot workstation Mac\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../macos-server/lib.sh"
INSTALL_DIR="$HOME/Library/Application Support/computer-setup/rs-sdk-portal"
mkdir -p "$INSTALL_DIR"
install -m 0644 "$SCRIPT_DIR/live_publish.py" "$INSTALL_DIR/live_publish.py"
render_plist "$SCRIPT_DIR/net.computer-setup.rs-sdk-portal-live.plist.template" net.computer-setup.rs-sdk-portal-live \
  "PYTHON=/usr/bin/python3" "PUBLISHER=$INSTALL_DIR/live_publish.py" "SSH_HOST=$SSH_HOST" "TICKS=$TICKS"
agent_load net.computer-setup.rs-sdk-portal-live
printf 'Live publisher installed (every %s ticks).\n' "$TICKS"
