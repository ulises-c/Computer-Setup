#!/usr/bin/env bash
# Idempotent setup: symlinks this repo's Claude config into ~/.claude/
# Safe to re-run. Backs up any existing settings.json before replacing it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

printf 'Installing from: %s\n' "$REPO_DIR"

# Back up settings.json if it exists and is not already one of ours
if [[ -e "$SETTINGS" && ! -L "$SETTINGS" ]]; then
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  printf 'Backing up existing settings.json → %s\n' "$BACKUP"
  mv "$SETTINGS" "$BACKUP"
fi

ln -sf "$REPO_DIR/settings.json" "$SETTINGS"
printf 'Linked: settings.json\n'

# Symlink CLAUDE.md
ln -sf "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
printf 'Linked: CLAUDE.md\n'

# Symlink rules directory (used by @imports in CLAUDE.md)
# rm -f first: ln -sf on an existing dir-symlink creates a nested link inside it
rm -f "$CLAUDE_DIR/rules"
ln -sf "$REPO_DIR/rules" "$CLAUDE_DIR/rules"
printf 'Linked: rules/\n'

# Symlink railguard policy (global: find_policy_file walks up from cwd)
ln -sf "$REPO_DIR/railguard.yaml" "$HOME/.railguard.yaml"
printf 'Linked: railguard.yaml → ~/.railguard.yaml\n'

# Create hooks dir if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Symlink each hook script and ensure it's executable
for hook in "$REPO_DIR/hooks/"*.sh; do
  chmod +x "$hook"
  ln -sf "$hook" "$HOOKS_DIR/$(basename "$hook")"
  printf 'Linked: hooks/%s\n' "$(basename "$hook")"
done

# Install railguard if not already present
RAILGUARD_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/railguard"
if [[ -x "$RAILGUARD_BIN" ]]; then
  printf 'railguard already installed: %s\n' "$RAILGUARD_BIN"
else
  if ! command -v cargo &>/dev/null && ! [[ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]]; then
    printf '\nerror: railguard is not installed and cargo was not found.\n' >&2
    printf '  Install Rust via rustup, then re-run this script:\n' >&2
    printf '    curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh\n' >&2
    exit 1
  fi
  CARGO_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
  printf 'Installing railguard via cargo...\n'
  "$CARGO_BIN" install railguard
  "$RAILGUARD_BIN" install
  printf 'Installed: railguard\n'
fi

# Warn on Ubuntu 24.04+ if the bwrap AppArmor profile isn't set up
if grep -qi 'ubuntu' /etc/os-release 2>/dev/null && ! [[ -f /etc/apparmor.d/bwrap ]]; then
  printf '\n'
  printf '⚠  Ubuntu detected: run setup-linux-sandbox.sh (with sudo) to enable sandboxing.\n'
  printf '   bash %s/setup-linux-sandbox.sh\n' "$REPO_DIR"
fi

printf '\nDone. Restart Claude Code for changes to take effect.\n'
