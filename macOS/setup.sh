#!/usr/bin/env bash
# macOS initial setup script
# Usage: bash macOS/setup.sh [--optional] [--work] [--dry-run]
#   --optional  also install low-priority optional packages
#   --work      also install work packages (Slack, Zoom, Outlook)
#   --dry-run   print all commands without executing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/macOS_packages.json"

# Other repo setup scripts to advertise at the end of a run. Each entry is
# "<path relative to repo root>|<one-line description>". To advertise a new
# script, just add a line here — only scripts that exist on disk are shown.
RELATED_SCRIPTS=(
  "agentic-ai/Claude/install.sh|Claude Code config — symlink settings, hooks, and CLAUDE.md into ~/.claude"
  "SSH_and_GPG/create_ssh_key.sh|Generate an SSH key (and add it to GitHub)"
  "SSH_and_GPG/create_gpg_key.sh|Generate a GPG key for signed commits"
  "macOS/verify.sh|Verify this install (read-only health check)"
)

INCLUDE_OPTIONAL=false
INCLUDE_WORK=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --optional) INCLUDE_OPTIONAL=true ;;
    --work)     INCLUDE_WORK=true ;;
    --dry-run)  DRY_RUN=true ;;
  esac
done

ZSHRC="$HOME/.zshrc"

# ── Run helpers ───────────────────────────────────────────────────────────────

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

run_eval() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] eval: %s\n' "$1"
  else
    eval "$1"
  fi
}

# npm supply-chain cooldown: refuse to install package versions younger than
# NPM_MIN_RELEASE_AGE days. Compromised releases of popular packages (e.g. the
# axios RAT, Mar 2026) are typically caught and yanked within hours, so a short
# cooldown blocks them while barely delaying legit updates. See issue #23.
NPM_MIN_RELEASE_AGE=7

configure_npm_cooldown() {
  local npmrc="$HOME/.npmrc" key="min-release-age" tmp
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] set %s=%s in %s\n' "$key" "$NPM_MIN_RELEASE_AGE" "$npmrc"
    return 0
  fi
  touch "$npmrc"
  # Drop any existing entry, then append the desired value (idempotent, portable).
  tmp="$(mktemp)"
  grep -v "^${key}=" "$npmrc" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$NPM_MIN_RELEASE_AGE" >> "$tmp"
  mv "$tmp" "$npmrc"
  printf '  ✓ npm %s=%s (%s-day supply-chain cooldown)\n' "$key" "$NPM_MIN_RELEASE_AGE" "$NPM_MIN_RELEASE_AGE"
}

# Enable pnpm (our daily-driver package manager) via corepack — corepack ships
# with Node — and apply the same supply-chain cooldown. pnpm measures
# minimumReleaseAge in MINUTES and enforces it strictly only when set explicitly
# (the built-in 1-day default is non-strict), so we set it on purpose. Issue #23.
configure_pnpm() {
  local age_minutes=$((NPM_MIN_RELEASE_AGE * 24 * 60))
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] corepack enable && corepack prepare pnpm@latest --activate\n'
    printf '  [dry-run] pnpm config set minimumReleaseAge %s --location=user\n' "$age_minutes"
    return 0
  fi
  if ! command -v corepack &>/dev/null; then
    printf '  ⚠ corepack not found (needs Node ≥16) — skipping pnpm setup\n'
    return 0
  fi
  corepack enable
  corepack prepare pnpm@latest --activate
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$PNPM_HOME/bin:$PATH"
  if command -v pnpm &>/dev/null; then
    pnpm config set minimumReleaseAge "$age_minutes" --location=user
    printf '  ✓ pnpm enabled, minimumReleaseAge=%s min (%s-day cooldown)\n' "$age_minutes" "$NPM_MIN_RELEASE_AGE"
  else
    printf '  ⚠ pnpm not on PATH after corepack — skipped cooldown config\n'
  fi
}

add_to_zshrc() {
  local line="$1"
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] add to .zshrc: %s\n' "$line"
  else
    grep -qF "$line" "$ZSHRC" 2>/dev/null || printf '%s\n' "$line" >> "$ZSHRC"
  fi
}

# ── Package install helpers ───────────────────────────────────────────────────

brew_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "brew" and
        .priority == $p and
        (.work != true) and
        (.install_command == null or .install_command == "") and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run brew install $names
}

brew_cask_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "brew-cask" and
        .priority == $p and
        (.work != true) and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run brew install --cask $names
}

pipx_install() {
  local priority="$1" optional_filter="$2"
  jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "pipx" and
        .priority == $p and
        (.work != true) and
        (if $opt then true else .optional == false end)
      ) | .name' "$PACKAGES_JSON" | while read -r name; do
    run pipx install "$name"
  done
}

pnpm_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "pnpm" and
        .priority == $p and
        (.work != true) and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run pnpm add -g $names
}

brew_custom_install() {
  local priority="$1" optional_filter="$2"
  jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "brew" and
        .priority == $p and
        (.work != true) and
        (.install_command != null and .install_command != "") and
        (if $opt then true else .optional == false end)
      ) | .install_command' "$PACKAGES_JSON" | while read -r cmd; do
    run_eval "$cmd"
  done
}

print_app_store_reminders() {
  local priority="$1" optional_filter="$2"
  local apps
  apps=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "app-store" and
        .priority == $p and
        (.work != true) and
        (if $opt then true else .optional == false end)
      ) | "  - \(.name): \(.description)"' "$PACKAGES_JSON")
  [[ -n "$apps" ]] && printf '%s\n' "$apps"
}

# Echo the other repo setup scripts (those present on disk) for discoverability.
print_related_scripts() {
  local repo_root entry rel desc shown=false
  repo_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  for entry in "${RELATED_SCRIPTS[@]}"; do
    rel="${entry%%|*}"; desc="${entry#*|}"
    [[ -f "$repo_root/$rel" ]] || continue
    if [[ "$shown" == false ]]; then
      printf '  Other setup scripts in this repo:\n'
      shown=true
    fi
    printf '    • %s\n' "$desc"
    printf '        bash %s\n' "$rel"
  done
}

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  printf '==> Installing Homebrew...\n'
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  run_eval 'eval "$(/opt/homebrew/bin/brew shellenv)"'
fi

# ── Bootstrap: jq (required to parse macOS_packages.json) ────────────────────
# jq is system-provided on macOS; only install via brew if missing.
command -v jq &>/dev/null || run brew install jq

# ── High-priority brew formulae (pyenv, expat, pipx) ─────────────────────────
printf '==> Installing high-priority brew formulae...\n'
brew_install "high" false

# ── Python (pyenv) ────────────────────────────────────────────────────────────
# pyenv compiles Python from source using brew's expat, bypassing broken
# Homebrew Python bottles on macOS Tahoe (missing libexpat symbols).
PYTHON_VERSION="3.12.13"
PYENV_PYTHON="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

if [[ "$DRY_RUN" == true ]]; then
  printf '  [dry-run] pyenv install %s\n' "$PYTHON_VERSION"
  printf '  [dry-run] pyenv global %s\n' "$PYTHON_VERSION"
elif ! pyenv versions 2>/dev/null | grep -q "$PYTHON_VERSION"; then
  printf '==> Installing Python %s via pyenv...\n' "$PYTHON_VERSION"
  LDFLAGS="-L/opt/homebrew/opt/expat/lib" \
  CPPFLAGS="-I/opt/homebrew/opt/expat/include" \
  PKG_CONFIG_PATH="/opt/homebrew/opt/expat/lib/pkgconfig" \
    pyenv install "$PYTHON_VERSION"
  pyenv global "$PYTHON_VERSION"
fi

add_to_zshrc 'export PYENV_ROOT="$HOME/.pyenv"'
add_to_zshrc 'export PATH="$PYENV_ROOT/bin:$PATH"'
add_to_zshrc 'eval "$(pyenv init -)"'
add_to_zshrc "export PIPX_DEFAULT_PYTHON=\"$PYENV_PYTHON\""

if [[ "$DRY_RUN" == false ]]; then
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"
  export PIPX_DEFAULT_PYTHON="$PYENV_PYTHON"
fi

# ── Node (nvm) ────────────────────────────────────────────────────────────────
# nvm installed via curl — brew install nvm causes PATH issues.
# nvm is kept last in .zshrc so it wins over brew's node.
if [[ "$DRY_RUN" == true ]]; then
  printf '  [dry-run] install nvm via curl\n'
  printf '  [dry-run] nvm install lts/* && nvm alias default lts/*\n'
elif [[ ! -d "$HOME/.nvm" ]]; then
  printf '==> Installing nvm...\n'
  INSTALL_CMD=$(jq -r '.[] | select(.name == "nvm") | .install_command' "$PACKAGES_JSON")
  eval "$INSTALL_CMD"
fi

if [[ "$DRY_RUN" == false ]]; then
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
  nvm install 'lts/*'
  nvm alias default 'lts/*'
  nvm use default
fi

# Apply the supply-chain cooldown before any package install runs below.
configure_npm_cooldown
configure_pnpm

add_to_zshrc 'export NVM_DIR="$HOME/.nvm"'
add_to_zshrc '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
add_to_zshrc 'nvm use --delete-prefix default --silent 2>/dev/null'
# pnpm global bin dir (corepack provides the pnpm shim; PNPM_HOME holds global CLIs)
add_to_zshrc 'export PNPM_HOME="$HOME/.local/share/pnpm"'
add_to_zshrc '[ -d "$PNPM_HOME/bin" ] && export PATH="$PNPM_HOME/bin:$PATH"'

# ── Medium-priority brew casks ────────────────────────────────────────────────
printf '==> Installing brew casks...\n'
brew_cask_install "medium" false

# ── Ghostty config ────────────────────────────────────────────────────────────
# Written to XDG path (~/.config/ghostty/) — works on both macOS and Linux.
# On macOS the platform-specific path loads after XDG and overrides it,
# so we rename it if it exists to keep XDG as the single source of truth.
GHOSTTY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
GHOSTTY_CONFIG="$GHOSTTY_CONFIG_DIR/config.ghostty"
MACOS_GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"

if [[ "$DRY_RUN" == true ]]; then
  printf '  [dry-run] mkdir -p %s\n' "$GHOSTTY_CONFIG_DIR"
  [[ -f "$GHOSTTY_CONFIG" ]] && printf '  [dry-run] backup %s → %s.bak\n' "$GHOSTTY_CONFIG" "$GHOSTTY_CONFIG"
  printf '  [dry-run] cp ghostty.config → %s\n' "$GHOSTTY_CONFIG"
  [[ -f "$MACOS_GHOSTTY_CONFIG" ]] && printf '  [dry-run] rename macOS-specific config to .bak\n'
else
  mkdir -p "$GHOSTTY_CONFIG_DIR"
  [[ -f "$GHOSTTY_CONFIG" ]] && cp "$GHOSTTY_CONFIG" "${GHOSTTY_CONFIG}.bak"
  cp "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG"
  printf '==> Ghostty config written to %s\n' "$GHOSTTY_CONFIG"
  if [[ -f "$MACOS_GHOSTTY_CONFIG" ]]; then
    mv "$MACOS_GHOSTTY_CONFIG" "${MACOS_GHOSTTY_CONFIG}.bak"
    printf '==> Renamed macOS-specific Ghostty config to .bak (XDG takes precedence)\n'
  fi
fi

# ── Git: GPG signing ─────────────────────────────────────────────────────────
run git config --global gpg.program /opt/homebrew/bin/gpg
add_to_zshrc 'export GPG_TTY=$(tty)'

# ── Medium-priority pipx packages ─────────────────────────────────────────────
printf '==> Installing pipx packages...\n'
if [[ "$DRY_RUN" == false ]]; then
  rm -rf ~/.local/pipx/shared
  pipx ensurepath
fi
pipx_install "medium" false

# ── Medium-priority pnpm packages ─────────────────────────────────────────────
printf '==> Installing pnpm packages...\n'
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$PATH"
if [[ "$DRY_RUN" == true ]] || command -v pnpm &>/dev/null; then
  pnpm_install "medium" false

  # Post-install: codeburn menubar (macOS native Swift app)
  run codeburn menubar
else
  printf '  pnpm not found — skipping (run corepack enable)\n'
fi

# ── Medium-priority brew formulae ─────────────────────────────────────────────
printf '==> Installing brew formulae...\n'
brew_install "medium" false

# ── Optional low-priority packages (--optional flag) ──────────────────────────
# priority "none" packages are never auto-installed regardless of flags
if [[ "$INCLUDE_OPTIONAL" == true ]]; then
  printf '==> Installing optional (low) packages...\n'
  brew_install "low" true
  brew_custom_install "low" true
  brew_cask_install "low" true
  pipx_install "low" true
  command -v pnpm &>/dev/null && pnpm_install "low" true
fi

# ── Work packages (--work flag) ───────────────────────────────────────────────
if [[ "$INCLUDE_WORK" == true ]]; then
  printf '==> Installing work packages...\n'
  names=$(jq -r '[.[] | select(.work == true and .package_manager == "brew-cask") | .name] | join(" ")' "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run brew install --cask $names
  names=$(jq -r '[.[] | select(.work == true and .package_manager == "brew") | .name] | join(" ")' "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run brew install $names
  work_app_store=$(jq -r '.[] | select(.work == true and .package_manager == "app-store") | "  - \(.name): \(.description)"' "$PACKAGES_JSON")
  if [[ -n "$work_app_store" ]]; then
    printf 'Install these work apps from the App Store:\n'
    printf '%s\n' "$work_app_store"
  fi
fi

# ── App Store reminders ───────────────────────────────────────────────────────
printf '\n'
printf 'Install these manually from the App Store:\n'
print_app_store_reminders "medium" false
[[ "$INCLUDE_OPTIONAL" == true ]] && print_app_store_reminders "low" true

printf '\n'
printf 'Optional — run these from the repo root as needed:\n'
print_related_scripts

printf '\n'
[[ "$DRY_RUN" == true ]] && printf 'Dry run complete — nothing was installed.\n' || printf 'Done! Restart your terminal or open a new tab.\n'
