#!/bin/zsh
# macOS initial setup script
# Run once on a fresh machine: zsh macOS/setup.sh

set -e

ZSHRC="$HOME/.zshrc"

add_to_zshrc() {
  local line="$1"
  grep -qF "$line" "$ZSHRC" 2>/dev/null || echo "$line" >> "$ZSHRC"
}

# ── Homebrew ──────────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
  echo "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# ── Top-level dependencies ────────────────────────────────────────────────────
# Install version managers and their build deps before anything else.
# Other tools (pipx, codeburn, etc.) depend on these being set up first.

# Python — pyenv + expat must come before pipx.
# Homebrew Python bottles link against macOS system libexpat, which is missing
# symbols on macOS Tahoe, causing ensurepip/venv to fail. pyenv compiles
# Python from source using brew's expat instead, which works correctly.
brew install pyenv expat

# Node — nvm must come before any npm/node-dependent tools (e.g. codeburn).
# Installed via curl per nvm's own recommendation — brew install nvm causes
# PATH issues because nvm injects itself into the shell rather than placing
# binaries in a static location.
if [ ! -d "$HOME/.nvm" ]; then
  echo "Installing nvm..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# nvm appended last in .zshrc so it wins over brew's node on every source
add_to_zshrc 'export NVM_DIR="$HOME/.nvm"'
add_to_zshrc '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
add_to_zshrc 'nvm use --delete-prefix default --silent 2>/dev/null'

# Install current LTS (v24 "Krypton" as of 2025) and set as default
nvm install 'lts/*'
nvm alias default 'lts/*'
nvm use default

# ── Python version ────────────────────────────────────────────────────────────
PYTHON_VERSION="3.12.13"

if ! pyenv versions | grep -q "$PYTHON_VERSION"; then
  echo "Installing Python $PYTHON_VERSION via pyenv..."
  LDFLAGS="-L/opt/homebrew/opt/expat/lib" \
  CPPFLAGS="-I/opt/homebrew/opt/expat/include" \
  PKG_CONFIG_PATH="/opt/homebrew/opt/expat/lib/pkgconfig" \
    pyenv install "$PYTHON_VERSION"
fi
pyenv global "$PYTHON_VERSION"

PYENV_PYTHON="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

add_to_zshrc 'export PYENV_ROOT="$HOME/.pyenv"'
add_to_zshrc 'export PATH="$PYENV_ROOT/bin:$PATH"'
add_to_zshrc 'eval "$(pyenv init -)"'
add_to_zshrc "export PIPX_DEFAULT_PYTHON=\"$PYENV_PYTHON\""

export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
export PIPX_DEFAULT_PYTHON="$PYENV_PYTHON"

# ── Brew formulae ─────────────────────────────────────────────────────────────
brew install \
  fastfetch \
  gh \
  git-lfs \
  git-xet \
  gnupg \
  hf \
  htop \
  llama.cpp \
  mactop \
  micro \
  nvtop \
  pipx \
  sshpass \
  tmux \
  zsh-autosuggestions \
  zsh-syntax-highlighting

# Clear any stale pipx shared venv created with the wrong Python
rm -rf ~/.local/pipx/shared
pipx ensurepath

# Node-dependent tools — installed after nvm/node is set up
# codeburn installed via npm (not brew tap) to avoid pulling in brew's node,
# which conflicts with nvm and causes PATH issues
npm install -g codeburn

# Installs and launches the native macOS menubar app (Swift, macOS only)
# The codeburn CLI itself is cross-platform; the menubar is a separate install
codeburn menubar

# ── Brew casks ────────────────────────────────────────────────────────────────
brew install --cask \
  claude \
  claude-code \
  firefox \
  ghostty \
  mac-mouse-fix \
  readdle-spark \
  rectangle \
  visual-studio-code

# ── App Store apps (manual) ───────────────────────────────────────────────────
echo ""
echo "Install these manually from the App Store:"
echo "  - Bitwarden   (browser integration requires App Store version)"
echo "  - Tailscale   (network extension requires App Store version)"
echo "  - Photomator"
echo "  - Goodnotes"

echo ""
echo "Done! Restart your terminal or run: source ~/.zshrc"
