#!/usr/bin/env bash
# Idempotent setup: deploys this repo's Claude config into ~/.claude/
# (settings.json is copied, everything else symlinked).
# Safe to re-run. Backs up any existing settings.json before replacing it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

printf 'Installing from: %s\n' "$REPO_DIR"

# settings.json is COPIED, not symlinked: Claude Code rewrites its user
# settings at runtime (model switches, plugin installs re-serialize the file),
# and a symlink funnels that machine state into the repo as permanent dirt.
# The repo file is the template; the live copy is machine state. Re-running
# resets the live copy to the template (after a backup) — re-pick your model
# afterwards. settings-drift.sh reports when the two diverge.
if [[ -L "$SETTINGS" ]]; then
  rm "$SETTINGS"   # old symlink layout — live content was the repo file itself
elif [[ -e "$SETTINGS" ]] && ! cmp -s "$REPO_DIR/settings.json" "$SETTINGS"; then
  BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  printf 'Backing up existing settings.json → %s\n' "$BACKUP"
  cp "$SETTINGS" "$BACKUP"
fi
cp "$REPO_DIR/settings.json" "$SETTINGS"
printf 'Copied: settings.json\n'

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

# Install railguard binary if not already present
RAILGUARD_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/railguard"
if ! [[ -x "$RAILGUARD_BIN" ]]; then
  CARGO_BIN="$(command -v cargo 2>/dev/null || echo "${CARGO_HOME:-$HOME/.cargo}/bin/cargo")"
  if ! [[ -x "$CARGO_BIN" ]]; then
    printf '\nerror: railguard is not installed and cargo was not found.\n' >&2
    printf '  Install Rust via rustup, then re-run this script:\n' >&2
    printf '    curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh\n' >&2
    exit 1
  fi
  printf 'Installing railguard via cargo...\n'
  if ! "$CARGO_BIN" install railguard; then
    printf '\nerror: cargo install railguard failed — see output above.\n' >&2
    exit 1
  fi
  printf 'Installed: railguard\n'
fi

# Always configure railguard (idempotent; picks up policy changes on re-run)
# railguard install rewrites the live settings.json with machine-specific
# absolute paths; redeploy the template afterwards so portable ~ paths win.
printf 'Configuring railguard...\n'
"$RAILGUARD_BIN" install
cp "$REPO_DIR/settings.json" "$SETTINGS"

# Warn on Ubuntu 24.04+ if the bwrap AppArmor profile isn't set up
if grep -qi 'ubuntu' /etc/os-release 2>/dev/null && ! [[ -f /etc/apparmor.d/bwrap ]]; then
  printf '\n'
  printf '⚠  Ubuntu detected: run setup-linux-sandbox.sh (with sudo) to enable sandboxing.\n'
  printf '   bash %s/setup-linux-sandbox.sh\n' "$REPO_DIR"
fi

printf '\nDone. Restart Claude Code for changes to take effect.\n'
