#!/bin/zsh
# macOS initial setup script
# Run once on a fresh machine: bash macOS/setup.sh

set -e

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ── Python (via pyenv) ────────────────────────────────────────────────────────
# Install pyenv and expat before anything that depends on Python.
# Homebrew Python bottles (3.12, 3.14, etc.) link against the macOS system
# libexpat, which is missing symbols on macOS Tahoe — causing pipx/ensurepip
# to fail. pyenv compiles Python from source using brew's expat instead.
PYTHON_VERSION="3.12.13"

brew install pyenv expat

if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "Installing Python $PYTHON_VERSION via pyenv..."
  LDFLAGS="-L/opt/homebrew/opt/expat/lib" \
  CPPFLAGS="-I/opt/homebrew/opt/expat/include" \
  PKG_CONFIG_PATH="/opt/homebrew/opt/expat/lib/pkgconfig" \
    pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"

PYENV_PYTHON="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

# ── Shell config (.zshrc) ─────────────────────────────────────────────────────
ZSHRC="$HOME/.zshrc"

add_to_zshrc() {
  local line="$1"
  grep -qF "$line" "$ZSHRC" 2>/dev/null || echo "$line" >> "$ZSHRC"
}

add_to_zshrc 'export PYENV_ROOT="$HOME/.pyenv"'
add_to_zshrc 'export PATH="$PYENV_ROOT/bin:$PATH"'
add_to_zshrc 'eval "$(pyenv init -)"'
add_to_zshrc "export PIPX_DEFAULT_PYTHON=\"$PYENV_PYTHON\""

# Apply pyenv to current session
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
export PIPX_DEFAULT_PYTHON="$PYENV_PYTHON"

# ── Core brew packages ────────────────────────────────────────────────────────
brew install \
  pipx \
  gh \
  git-lfs \
  fastfetch \
  zsh-autosuggestions \
  zsh-syntax-highlighting \
  gnupg \
  mactop \
  micro

# Clear any stale pipx shared venv that may have been created with the wrong Python
rm -rf ~/.local/pipx/shared

pipx ensurepath

# ── Casks ─────────────────────────────────────────────────────────────────────
brew install --cask \
  ghostty \
  mac-mouse-fix \
  claude \
  claude-code

echo ""
echo "Done! Restart your terminal or run: source ~/.zshrc"
