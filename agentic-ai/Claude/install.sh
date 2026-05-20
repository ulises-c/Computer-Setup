#!/usr/bin/env bash
# Idempotent setup: symlinks this repo's Claude config into ~/.claude/
# Safe to re-run. Backs up any existing settings.json before replacing it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "Installing from: $REPO_DIR"

# Back up settings.json if it exists and is not already our symlink
if [[ -f "$SETTINGS" && ! -L "$SETTINGS" ]]; then
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  echo "Backing up existing settings.json → $BACKUP"
  mv "$SETTINGS" "$BACKUP"
fi

# Symlink settings.json
ln -sf "$REPO_DIR/settings.json" "$SETTINGS"
echo "Linked: settings.json"

# Symlink CLAUDE.md
ln -sf "$REPO_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
echo "Linked: CLAUDE.md"

# Symlink rules directory (used by @imports in CLAUDE.md)
ln -sf "$REPO_DIR/rules" "$CLAUDE_DIR/rules"
echo "Linked: rules/"

# Create hooks dir if it doesn't exist
mkdir -p "$HOOKS_DIR"

# Symlink each hook script and ensure it's executable
for hook in "$REPO_DIR/hooks/"*.sh; do
  chmod +x "$hook"
  ln -sf "$hook" "$HOOKS_DIR/$(basename "$hook")"
  echo "Linked: hooks/$(basename "$hook")"
done

echo "Done. Restart Claude Code for changes to take effect."
