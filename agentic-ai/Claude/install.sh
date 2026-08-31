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

  # ~/.codex/rules is Codex's own execpolicy directory (*.rules files); linking
  # over it would drop that sandbox policy. Codex concatenates AGENTS.md instead
  # of resolving @-imports, so it never needs the sibling rules/ anyway.
  if [[ "$agents_dir" == "$HOME/.codex" ]]; then
    printf 'Linked: AGENTS.md → %s (rules/ skipped: Codex execpolicy dir)\n' "$agents_dir"
    continue
  fi

  rules_dst="$agents_dir/rules"
  if [[ -e "$rules_dst" && ! -L "$rules_dst" ]]; then
    backup="$rules_dst.bak.$(date +%Y%m%d%H%M%S)"
    printf 'Backing up existing %s → %s\n' "$rules_dst" "$backup"
    mv "$rules_dst" "$backup"
  fi
  ln -sfn "$AGENTIC_DIR/rules" "$rules_dst"
  printf 'Linked: AGENTS.md + rules/ → %s\n' "$agents_dir"
done

# Symlink docs directory (on-demand references pointed at by rules, e.g.
# ~/.claude/docs/RAILGUARD.md — not @imported, read only when needed)
rm -f "$CLAUDE_DIR/docs"
ln -sf "$REPO_DIR/docs" "$CLAUDE_DIR/docs"
printf 'Linked: docs/\n'

# Symlink each cross-agent skill into every installed harness's global skill
# root. Linked per-skill rather than as a whole directory: these roots also
# receive skills from plugins and hand-authored ones, and linking the parent
# would shadow all of them. -n so a re-run replaces the existing link instead
# of nesting inside it.
#
# Roots are the documented global skill directories of each harness. A root is
# only populated when its parent config dir already exists, so this never
# creates a config tree for a harness that is not installed. ~/.claude is
# unconditional: this script owns that directory.
SKILLS_SRC="$AGENTIC_DIR/skills"
if [[ -d "$SKILLS_SRC" ]]; then
  skill_roots=("$CLAUDE_DIR/skills")
  [[ -d "$HOME/.codex" ]]                    && skill_roots+=("$HOME/.codex/skills")
  [[ -d "$HOME/.hermes" ]]                   && skill_roots+=("$HOME/.hermes/skills")
  [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/opencode" ]] \
                                             && skill_roots+=("${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills")
  [[ -d "$HOME/.cursor" ]]                   && skill_roots+=("$HOME/.cursor/skills")
  [[ -d "$HOME/.gemini" ]]                   && skill_roots+=("$HOME/.gemini/skills")

  for skill_root in "${skill_roots[@]}"; do
    mkdir -p "$skill_root"
    for skill in "$SKILLS_SRC"/*/; do
      [[ -d "$skill" ]] || continue
      skill_name="$(basename "$skill")"
      skill_dst="$skill_root/$skill_name"
      if [[ -e "$skill_dst" && ! -L "$skill_dst" ]]; then
        printf 'warning: %s exists and is not a symlink; skipping\n' "$skill_dst" >&2
        continue
      fi
      ln -sfn "${skill%/}" "$skill_dst"
      printf 'Linked: skills/%s → %s\n' "$skill_name" "$skill_root"
    done
  done
fi

# Symlink each output style into ~/.claude/output-styles/. Unlike a skill (which
# loads only when a task matches), an output style applies to every reply, so it
# stays opt-in: this only puts the file where Claude Code can find it. Turn one
# on with /config → Output style. Claude-Code-only feature; no other harness
# reads this directory.
STYLES_SRC="$REPO_DIR/output-styles"
if [[ -d "$STYLES_SRC" ]]; then
  mkdir -p "$CLAUDE_DIR/output-styles"
  for style in "$STYLES_SRC"/*.md; do
    [[ -f "$style" ]] || continue
    style_name="$(basename "$style")"
    style_dst="$CLAUDE_DIR/output-styles/$style_name"
    if [[ -e "$style_dst" && ! -L "$style_dst" ]]; then
      printf 'warning: %s exists and is not a symlink; skipping\n' "$style_dst" >&2
      continue
    fi
    ln -sfn "$style" "$style_dst"
    printf 'Linked: output-styles/%s\n' "$style_name"
  done
fi

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
  # rustup ships no toolchain: cargo is a proxy that errors until a default is
  # picked, so an -x test passes on a machine that can't build anything.
  if command -v rustup &>/dev/null && ! rustup show active-toolchain &>/dev/null; then
    printf 'No default Rust toolchain; running rustup default stable...\n'
    rustup default stable
  fi
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
