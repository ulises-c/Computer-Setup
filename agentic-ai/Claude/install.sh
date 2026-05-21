#!/usr/bin/env bash
# Idempotent setup: symlinks this repo's Claude config into ~/.claude/
# Safe to re-run. Backs up any existing settings.json before replacing it.
#
# GH_TOKEN: if provided (via env or prompt), settings.json is written as a
# generated file (not a symlink) with the token merged in. Re-run install.sh
# after repo changes to settings.json to pick them up.

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

# Prompt for GH_TOKEN if not already in env (empty answer = skip)
if [[ -z "${GH_TOKEN:-}" ]]; then
  read -r -s -p "GH_TOKEN for gh CLI (leave blank to skip): " GH_TOKEN
  printf '\n'
fi

if [[ -n "${GH_TOKEN:-}" ]]; then
  # Generate settings.json with token merged in — NOT a symlink.
  # Pass the token via env so it never appears in jq's argv / /proc/*/cmdline.
  rm -f "$SETTINGS"
  GH_TOKEN="$GH_TOKEN" jq '.env.GH_TOKEN = env.GH_TOKEN' "$REPO_DIR/settings.json" > "$SETTINGS"
  printf 'Generated: settings.json (with GH_TOKEN — not a symlink; re-run install.sh after repo changes)\n'
else
  ln -sf "$REPO_DIR/settings.json" "$SETTINGS"
  printf 'Linked: settings.json\n'
fi

# Symlink CLAUDE.md
ln -sf "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
printf 'Linked: CLAUDE.md\n'

# Symlink rules directory (used by @imports in CLAUDE.md)
ln -sf "$REPO_DIR/rules" "$CLAUDE_DIR/rules"
printf 'Linked: rules/\n'

# Create hooks dir if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Symlink each hook script and ensure it's executable
for hook in "$REPO_DIR/hooks/"*.sh; do
  chmod +x "$hook"
  ln -sf "$hook" "$HOOKS_DIR/$(basename "$hook")"
  printf 'Linked: hooks/%s\n' "$(basename "$hook")"
done

# Warn on Ubuntu 24.04+ if the bwrap AppArmor profile isn't set up
if grep -qi 'ubuntu' /etc/os-release 2>/dev/null && ! [[ -f /etc/apparmor.d/bwrap ]]; then
  printf '\n'
  printf '⚠  Ubuntu detected: run setup-linux-sandbox.sh (with sudo) to enable sandboxing.\n'
  printf '   bash %s/setup-linux-sandbox.sh\n' "$REPO_DIR"
fi

printf '\nDone. Restart Claude Code for changes to take effect.\n'
