#!/usr/bin/env bash
# macOS initial setup script
# Usage: bash macOS/setup.sh [--optional] [--work] [--dry-run]
#   --optional  also install low-priority optional packages
#   --work      also install work packages (Slack, Zoom, Outlook)
#   --dry-run   print all commands without executing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/macOS_packages.json"
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
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

run_eval() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] eval: $1"
  else
    eval "$1"
  fi
}

add_to_zshrc() {
  local line="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] add to .zshrc: $line"
  else
    grep -qF "$line" "$ZSHRC" 2>/dev/null || echo "$line" >> "$ZSHRC"
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

npm_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "npm" and
        .priority == $p and
        (.work != true) and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && run npm install -g $names
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
  [[ -n "$apps" ]] && echo "$apps"
}

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "==> Installing Homebrew..."
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  run_eval 'eval "$(/opt/homebrew/bin/brew shellenv)"'
fi

# ── Bootstrap: jq (required to parse macOS_packages.json) ────────────────────
# jq is system-provided on macOS; only install via brew if missing.
command -v jq &>/dev/null || run brew install jq

# ── High-priority brew formulae (pyenv, expat, pipx) ─────────────────────────
echo "==> Installing high-priority brew formulae..."
brew_install "high" false

# ── Python (pyenv) ────────────────────────────────────────────────────────────
# pyenv compiles Python from source using brew's expat, bypassing broken
# Homebrew Python bottles on macOS Tahoe (missing libexpat symbols).
PYTHON_VERSION="3.12.13"
PYENV_PYTHON="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

if [[ "$DRY_RUN" == true ]]; then
  echo "  [dry-run] pyenv install $PYTHON_VERSION"
  echo "  [dry-run] pyenv global $PYTHON_VERSION"
elif ! pyenv versions 2>/dev/null | grep -q "$PYTHON_VERSION"; then
  echo "==> Installing Python $PYTHON_VERSION via pyenv..."
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
  echo "  [dry-run] install nvm via curl"
  echo "  [dry-run] nvm install lts/* && nvm alias default lts/*"
elif [ ! -d "$HOME/.nvm" ]; then
  echo "==> Installing nvm..."
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

add_to_zshrc 'export NVM_DIR="$HOME/.nvm"'
add_to_zshrc '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
add_to_zshrc 'nvm use --delete-prefix default --silent 2>/dev/null'

# ── Medium-priority brew casks ────────────────────────────────────────────────
echo "==> Installing brew casks..."
brew_cask_install "medium" false

# ── Ghostty config ────────────────────────────────────────────────────────────
# Written to XDG path (~/.config/ghostty/) — works on both macOS and Linux.
# On macOS the platform-specific path loads after XDG and overrides it,
# so we rename it if it exists to keep XDG as the single source of truth.
GHOSTTY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
GHOSTTY_CONFIG="$GHOSTTY_CONFIG_DIR/config.ghostty"
MACOS_GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"

if [[ "$DRY_RUN" == true ]]; then
  echo "  [dry-run] mkdir -p $GHOSTTY_CONFIG_DIR"
  [[ -f "$GHOSTTY_CONFIG" ]] && echo "  [dry-run] backup $GHOSTTY_CONFIG → ${GHOSTTY_CONFIG}.bak"
  echo "  [dry-run] cp ghostty.config → $GHOSTTY_CONFIG"
  [[ -f "$MACOS_GHOSTTY_CONFIG" ]] && echo "  [dry-run] rename macOS-specific config to .bak"
else
  mkdir -p "$GHOSTTY_CONFIG_DIR"
  [[ -f "$GHOSTTY_CONFIG" ]] && cp "$GHOSTTY_CONFIG" "${GHOSTTY_CONFIG}.bak"
  cp "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG"
  echo "==> Ghostty config written to $GHOSTTY_CONFIG"
  if [[ -f "$MACOS_GHOSTTY_CONFIG" ]]; then
    mv "$MACOS_GHOSTTY_CONFIG" "${MACOS_GHOSTTY_CONFIG}.bak"
    echo "==> Renamed macOS-specific Ghostty config to .bak (XDG takes precedence)"
  fi
fi

# ── Medium-priority pipx packages ─────────────────────────────────────────────
echo "==> Installing pipx packages..."
if [[ "$DRY_RUN" == false ]]; then
  rm -rf ~/.local/pipx/shared
  pipx ensurepath
fi
pipx_install "medium" false

# ── Medium-priority npm packages ──────────────────────────────────────────────
echo "==> Installing npm packages..."
npm_install "medium" false

# Post-install: codeburn menubar (macOS native Swift app)
run codeburn menubar

# ── Medium-priority brew formulae ─────────────────────────────────────────────
echo "==> Installing brew formulae..."
brew_install "medium" false

# ── Optional low-priority packages (--optional flag) ──────────────────────────
# priority "none" packages are never auto-installed regardless of flags
if [[ "$INCLUDE_OPTIONAL" == true ]]; then
  echo "==> Installing optional (low) packages..."
  brew_install "low" true
  brew_custom_install "low" true
  brew_cask_install "low" true
  pipx_install "low" true
  npm_install "low" true
fi

# ── Work packages (--work flag) ───────────────────────────────────────────────
if [[ "$INCLUDE_WORK" == true ]]; then
  echo "==> Installing work packages..."
  names=$(jq -r '[.[] | select(.work == true and .package_manager == "brew-cask") | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && run brew install --cask $names
  names=$(jq -r '[.[] | select(.work == true and .package_manager == "brew") | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && run brew install $names
  work_app_store=$(jq -r '.[] | select(.work == true and .package_manager == "app-store") | "  - \(.name): \(.description)"' "$PACKAGES_JSON")
  if [[ -n "$work_app_store" ]]; then
    echo "Install these work apps from the App Store:"
    echo "$work_app_store"
  fi
fi

# ── App Store reminders ───────────────────────────────────────────────────────
echo ""
echo "Install these manually from the App Store:"
print_app_store_reminders "medium" false
[[ "$INCLUDE_OPTIONAL" == true ]] && print_app_store_reminders "low" true

echo ""
[[ "$DRY_RUN" == true ]] && echo "Dry run complete — nothing was installed." || echo "Done! Restart your terminal or open a new tab."
