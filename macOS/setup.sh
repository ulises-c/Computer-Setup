#!/bin/zsh
# macOS initial setup script
# Usage: zsh macOS/setup.sh [--optional]
#   --optional  also install low-priority optional packages

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/macOS_packages.json"
INCLUDE_OPTIONAL=false
[[ "${1:-}" == "--optional" ]] && INCLUDE_OPTIONAL=true

ZSHRC="$HOME/.zshrc"

add_to_zshrc() {
  local line="$1"
  grep -qF "$line" "$ZSHRC" 2>/dev/null || echo "$line" >> "$ZSHRC"
}

# ── Helpers ───────────────────────────────────────────────────────────────────

brew_install() {
  # Batch install all standard brew formulae for a given priority (no install_command)
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "brew" and
        .priority == $p and
        (.install_command == null or .install_command == "") and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && brew install $names
}

brew_cask_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "brew-cask" and
        .priority == $p and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && brew install --cask $names
}

pipx_install() {
  local priority="$1" optional_filter="$2"
  jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "pipx" and
        .priority == $p and
        (if $opt then true else .optional == false end)
      ) | .name' "$PACKAGES_JSON" | while read -r name; do
    pipx install "$name"
  done
}

npm_install() {
  local priority="$1" optional_filter="$2"
  local names
  names=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '[.[] | select(
        .package_manager == "npm" and
        .priority == $p and
        (if $opt then true else .optional == false end)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -n "$names" ]] && npm install -g $names
}

brew_custom_install() {
  # Packages with a custom install_command (e.g. brew tap + install)
  local priority="$1" optional_filter="$2"
  jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "brew" and
        .priority == $p and
        (.install_command != null and .install_command != "") and
        (if $opt then true else .optional == false end)
      ) | .install_command' "$PACKAGES_JSON" | while read -r cmd; do
    eval "$cmd"
  done
}

print_app_store_reminders() {
  local priority="$1" optional_filter="$2"
  local apps
  apps=$(jq -r --arg p "$priority" --argjson opt "$optional_filter" \
    '.[] | select(
        .package_manager == "app-store" and
        .priority == $p and
        (if $opt then true else .optional == false end)
      ) | "  - \(.name): \(.description)"' "$PACKAGES_JSON")
  [[ -n "$apps" ]] && echo "$apps"
}

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "==> Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ── Bootstrap: jq (required to parse macOS_packages.json) ────────────────────
brew install jq

# ── High-priority brew formulae (includes pyenv, expat, pipx) ────────────────
echo "==> Installing high-priority brew formulae..."
brew_install "high" false

# ── Python (pyenv) ────────────────────────────────────────────────────────────
# pyenv compiles Python from source using brew's expat, bypassing broken
# Homebrew Python bottles on macOS Tahoe (missing libexpat symbols).
PYTHON_VERSION="3.12.13"
PYENV_PYTHON="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "==> Installing Python $PYTHON_VERSION via pyenv..."
  LDFLAGS="-L/opt/homebrew/opt/expat/lib" \
  CPPFLAGS="-I/opt/homebrew/opt/expat/include" \
  PKG_CONFIG_PATH="/opt/homebrew/opt/expat/lib/pkgconfig" \
    pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"

add_to_zshrc 'export PYENV_ROOT="$HOME/.pyenv"'
add_to_zshrc 'export PATH="$PYENV_ROOT/bin:$PATH"'
add_to_zshrc 'eval "$(pyenv init -)"'
add_to_zshrc "export PIPX_DEFAULT_PYTHON=\"$PYENV_PYTHON\""

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
export PIPX_DEFAULT_PYTHON="$PYENV_PYTHON"

# ── Node (nvm) ────────────────────────────────────────────────────────────────
# nvm installed via curl per nvm's own recommendation — brew install nvm causes
# PATH issues. nvm is kept last in .zshrc so it wins over brew's node.
if [ ! -d "$HOME/.nvm" ]; then
  echo "==> Installing nvm..."
  INSTALL_CMD=$(jq -r '.[] | select(.name == "nvm") | .install_command' "$PACKAGES_JSON")
  eval "$INSTALL_CMD"
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 'lts/*'
nvm alias default 'lts/*'
nvm use default

add_to_zshrc 'export NVM_DIR="$HOME/.nvm"'
add_to_zshrc '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
add_to_zshrc 'nvm use --delete-prefix default --silent 2>/dev/null'

# ── Medium-priority brew casks ────────────────────────────────────────────────
echo "==> Installing brew casks..."
brew_cask_install "medium" false

# ── Ghostty config ────────────────────────────────────────────────────────────
# Written to the XDG path (~/.config/ghostty/) which works on both macOS and
# Linux. On macOS the platform-specific path is loaded after XDG and will
# override it, so we rename it if it exists to keep XDG as the single source.
GHOSTTY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
mkdir -p "$GHOSTTY_CONFIG_DIR"
cp "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG_DIR/config.ghostty"
echo "==> Ghostty config written to $GHOSTTY_CONFIG_DIR/config.ghostty"

MACOS_GHOSTTY_CONFIG="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
if [[ -f "$MACOS_GHOSTTY_CONFIG" ]]; then
  mv "$MACOS_GHOSTTY_CONFIG" "${MACOS_GHOSTTY_CONFIG}.bak"
  echo "==> Renamed macOS-specific Ghostty config to .bak (XDG config takes precedence)"
fi

# ── Medium-priority pipx packages ─────────────────────────────────────────────
echo "==> Installing pipx packages..."
rm -rf ~/.local/pipx/shared
pipx ensurepath
pipx_install "medium" false

# ── Medium-priority npm packages ──────────────────────────────────────────────
echo "==> Installing npm packages..."
npm_install "medium" false

# Post-install: codeburn menubar (macOS native Swift app)
codeburn menubar

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

# ── App Store reminders ───────────────────────────────────────────────────────
echo ""
echo "Install these manually from the App Store:"
print_app_store_reminders "medium" false
[[ "$INCLUDE_OPTIONAL" == true ]] && print_app_store_reminders "low" true

echo ""
echo "Done! Restart your terminal or open a new tab."
