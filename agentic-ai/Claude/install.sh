#!/usr/bin/env bash
# Idempotent setup: deploys this repo's Claude config into ~/.claude/
# (settings.json is copied, everything else symlinked).
# Safe to re-run. Backs up any existing settings.json before replacing it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTIC_DIR="$(cd "$REPO_DIR/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

if [[ -d "$CLAUDE_DIR/docs" && ! -L "$CLAUDE_DIR/docs" ]]; then
  printf 'error: %s is a directory; move or remove it before installing\n' "$CLAUDE_DIR/docs" >&2
  exit 1
fi

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

# Deploy the shared cross-agent AGENTS.md + rules/ to every global location that
# reads one. Claude Code resolves @-imports against the *deployed* directory of
# the importing file and will not follow "../", so AGENTS.md and rules/ must sit
# as siblings of each instruction file — ~/AGENTS.md alone would leave its
# @rules/... imports pointing at a nonexistent ~/rules.
for agents_dir in "$CLAUDE_DIR" "$HOME/.codex" "$HOME"; do
  mkdir -p "$agents_dir"
  agents_dst="$agents_dir/AGENTS.md"
  if [[ -e "$agents_dst" && ! -L "$agents_dst" ]]; then
    backup="$agents_dst.bak.$(date +%Y%m%d%H%M%S)"
    printf 'Backing up existing %s → %s\n' "$agents_dst" "$backup"
    mv "$agents_dst" "$backup"
  fi
  ln -sf "$AGENTIC_DIR/AGENTS.md" "$agents_dst"
  rm -f "$agents_dir/rules"
  ln -sf "$AGENTIC_DIR/rules" "$agents_dir/rules"
  printf 'Linked: AGENTS.md + rules/ → %s\n' "$agents_dir"
done

# Symlink docs directory (on-demand references pointed at by rules, e.g.
# ~/.claude/docs/RAILGUARD.md — not @imported, read only when needed)
rm -f "$CLAUDE_DIR/docs"
ln -sf "$REPO_DIR/docs" "$CLAUDE_DIR/docs"
printf 'Linked: docs/\n'

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

# Install (or migrate) the railguard binary from the GitHub source.
# cargo install --git reinstalls whenever the installed source/commit differs,
# so this both provisions fresh machines and switches existing crates.io
# installs over to the fork, while staying a no-op when already up to date.
RAILGUARD_BIN="${CARGO_HOME:-$HOME/.cargo}/bin/railguard"
CARGO_BIN="$(command -v cargo 2>/dev/null || echo "${CARGO_HOME:-$HOME/.cargo}/bin/cargo")"
if [[ -x "$CARGO_BIN" ]]; then
  printf 'Installing railguard from GitHub...\n'
  if ! "$CARGO_BIN" install --git https://github.com/ulises-c/railguard; then
    printf '\nerror: cargo install railguard failed — see output above.\n' >&2
    exit 1
  fi
  printf 'Installed: railguard\n'
elif [[ -x "$RAILGUARD_BIN" ]]; then
  printf 'warning: cargo not found; keeping existing railguard binary (not migrated to the fork).\n' >&2
else
  printf '\nerror: railguard is not installed and cargo was not found.\n' >&2
  printf '  Install Rust via rustup, then re-run this script:\n' >&2
  printf '    curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh\n' >&2
  exit 1
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
