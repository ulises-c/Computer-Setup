#!/usr/bin/env bash
# Idempotent setup: symlinks this repo's OpenCode config into ~/.config/opencode/
# Safe to re-run. Backs up any existing opencode.json before replacing it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_DIR="$HOME/.config/opencode"
CONFIG="$OPENCODE_DIR/opencode.json"

printf 'Installing from: %s\n' "$REPO_DIR"

mkdir -p "$OPENCODE_DIR"

# Back up opencode.json if it exists and is not already one of ours
if [[ -e "$CONFIG" && ! -L "$CONFIG" ]]; then
  BACKUP="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  printf 'Backing up existing opencode.json → %s\n' "$BACKUP"
  mv "$CONFIG" "$BACKUP"
fi

ln -sf "$REPO_DIR/opencode.json" "$CONFIG"
printf 'Linked: opencode.json\n'

# Symlink launch script into PATH
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
ln -sf "$REPO_DIR/bin/opencode-local" "$LOCAL_BIN/opencode-local"
printf 'Linked: bin/opencode-local → %s/opencode-local\n' "$LOCAL_BIN"

printf '\nDone. Restart OpenCode for changes to take effect.\n'
