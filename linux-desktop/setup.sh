#!/usr/bin/env bash
# Linux desktop initial setup script (Ubuntu / Arch)
# Usage: bash linux-desktop/setup.sh [--optional] [--work] [--personal] [--dry-run] [--distro <id>]
#   --optional      also install low-priority optional packages
#   --work          also install work-only packages (Slack, Zoom, Teams, Chromium)
#   --personal      also install personal-only packages (Discord, VLC, Spotify, Steam)
#   --dry-run       print all commands without executing anything
#   --distro <id>   force distro family (ubuntu|arch); default: auto-detect from /etc/os-release
#
# Distro support:
#   ubuntu → apt + snap + curl installers
#   arch   → yay (repo + AUR) + curl installers (CachyOS, Arch, Manjaro, EndeavourOS, …)
#
# Environment filtering:
#   No flags     → installs packages with no environment tag (shared across all)
#   --work       → adds packages tagged environment=["work"]
#   --personal   → adds packages tagged environment=["personal"]
#   Both flags   → installs everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/linux_desktop_packages.json"
DISTRO=""
INCLUDE_OPTIONAL=false
INCLUDE_WORK=false
INCLUDE_PERSONAL=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --optional) INCLUDE_OPTIONAL=true ;;
    --work)     INCLUDE_WORK=true ;;
    --personal) INCLUDE_PERSONAL=true ;;
    --dry-run)  DRY_RUN=true ;;
    --distro)   DISTRO="${2:-}"; shift ;;
    *)          echo "Unknown argument: $1" >&2 ;;
  esac
  shift
done

# ── Distro detection ───────────────────────────────────────────────────────────
detect_distro() {
  [[ -n "$DISTRO" ]] && return
  local id="" id_like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id="$(. /etc/os-release && echo "${ID:-}")"
    # shellcheck disable=SC1091
    id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
  fi
  case "$id" in
    ubuntu|debian|linuxmint|pop) DISTRO="ubuntu" ;;
    arch|cachyos|manjaro|endeavouros|garuda|arcolinux) DISTRO="arch" ;;
    *)
      case "$id_like" in
        *debian*|*ubuntu*) DISTRO="ubuntu" ;;
        *arch*)            DISTRO="arch" ;;
        *)
          echo "ERROR: Unsupported distro (ID='$id' ID_LIKE='$id_like')." >&2
          echo "       Re-run with --distro ubuntu|arch to override." >&2
          exit 1 ;;
      esac ;;
  esac
}
detect_distro

if [[ "$DISTRO" != "ubuntu" && "$DISTRO" != "arch" ]]; then
  echo "ERROR: --distro must be 'ubuntu' or 'arch' (got '$DISTRO')." >&2
  exit 1
fi
echo "==> Detected distro family: $DISTRO"

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# Build a jq filter for environment tags.
# Packages with no environment field always install.
# Packages with environment=["work"] only install if --work is passed, etc.
env_filter() {
  local work="$INCLUDE_WORK" personal="$INCLUDE_PERSONAL"
  cat <<JQEOF
    (
      (.environment == null) or
      (("$work" == "true") and (.environment | index("work"))) or
      (("$personal" == "true") and (.environment | index("personal")))
    )
JQEOF
}

# Query packages by distro package manager and priority, respecting environment + <distro>_name
pkg_names() {
  local manager="$1" priority="$2"
  local ef
  ef=$(env_filter)
  jq -r --arg m "$manager" --arg p "$priority" --arg d "$DISTRO" \
    "[.[] | select(
        .package_manager[\$d] == \$m and
        .priority == \$p and
        $ef
      ) | (.[\$d + \"_name\"] // .name)] | join(\" \")" \
    "$PACKAGES_JSON"
}

# Query packages that have install_command for this distro
custom_installs() {
  local priority="$1"
  local ef
  ef=$(env_filter)
  jq -r --arg p "$priority" --arg d "$DISTRO" \
    ".[] | select(
        .package_manager[\$d] == \"custom\" and
        .priority == \$p and
        .install_command[\$d] != null and
        $ef
      ) | \"\(.name)|\(.install_command[\$d])\"" \
    "$PACKAGES_JSON"
}

# Query packages installed via curl (have install_command)
curl_installs() {
  local priority="$1"
  local ef
  ef=$(env_filter)
  jq -r --arg p "$priority" --arg d "$DISTRO" \
    ".[] | select(
        .package_manager[\$d] == \"curl\" and
        .priority == \$p and
        .install_command[\$d] != null and
        $ef
      ) | \"\(.name)|\(.install_command[\$d])\"" \
    "$PACKAGES_JSON"
}

apt_install() {
  local priority="$1"
  local names
  names=$(pkg_names "apt" "$priority")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run sudo apt install -y $names
}

# Install repo + AUR packages on Arch via yay (handles both uniformly).
# If the batch fails (e.g. a single AUR build breaks), retry one package at a
# time so one failure can't abort the whole run (and skip shell/config steps).
yay_install() {
  local priority="$1"
  local names
  names=$(pkg_names "yay" "$priority")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  if ! run yay -S --needed --noconfirm $names; then
    echo "  batch install errored — retrying packages individually..."
    local pkg
    for pkg in $names; do
      run yay -S --needed --noconfirm "$pkg" || echo "  ✗ failed: $pkg"
    done
  fi
}

snap_install() {
  local priority="$1"
  local ef
  ef=$(env_filter)
  # Regular snaps
  local names
  names=$(pkg_names "snap" "$priority")
  # Handle snaps with install_command (e.g. --classic) separately
  local custom_snaps
  custom_snaps=$(jq -r --arg p "$priority" --arg d "$DISTRO" \
    ".[] | select(
        .package_manager[\$d] == \"snap\" and
        .priority == \$p and
        .install_command[\$d] != null and
        $ef
      ) | \"\(.name)|\(.install_command[\$d])\"" \
    "$PACKAGES_JSON")

  local regular_snaps
  regular_snaps=$(jq -r --arg p "$priority" --arg d "$DISTRO" \
    "[.[] | select(
        .package_manager[\$d] == \"snap\" and
        .priority == \$p and
        .install_command[\$d] == null and
        $ef
      ) | (.[\$d + \"_name\"] // .name)] | join(\" \")" \
    "$PACKAGES_JSON")

  if [[ -n "$regular_snaps" ]]; then
    # shellcheck disable=SC2086
    for snap_name in $regular_snaps; do
      run sudo snap install "$snap_name"
    done
  fi

  if [[ -n "$custom_snaps" ]]; then
    while IFS='|' read -r name cmd; do
      echo "  $name (custom snap)..."
      run_eval "$cmd"
    done <<< "$custom_snaps"
  fi
}

pipx_install() {
  local priority="$1"
  local ef
  ef=$(env_filter)
  jq -r --arg p "$priority" --arg d "$DISTRO" \
    ".[] | select(
        .package_manager[\$d] == \"pipx\" and
        .priority == \$p and
        $ef
      ) | if .install_command[\$d] != null then .install_command[\$d] else \"pipx install \" + .name end" \
    "$PACKAGES_JSON" | while read -r cmd; do
    run_eval "$cmd"
  done
}

npm_install() {
  local priority="$1"
  local ef names
  ef=$(env_filter)
  names=$(jq -r --arg p "$priority" --arg d "$DISTRO" \
    "[.[] | select(
        .package_manager[\$d] == \"npm\" and
        .priority == \$p and
        $ef
      ) | .name] | join(\" \")" \
    "$PACKAGES_JSON")
  # shellcheck disable=SC2086
  [[ -n "$names" ]] && run npm install -g $names
}

# Bootstrap the AUR helper on Arch (yay lives in the CachyOS/Arch repos, so pacman
# installs it directly — the one place pacman is required instead of yay).
ensure_yay() {
  if ! command -v yay &>/dev/null; then
    echo "==> Bootstrapping yay (via pacman)..."
    run sudo pacman -S --needed --noconfirm base-devel git yay
  else
    echo "==> yay already installed ($(yay --version 2>/dev/null | head -1))"
  fi
}

# ── Package-manager bootstrap ────────────────────────────────────────────────
if [[ "$DISTRO" == "ubuntu" ]]; then
  echo "==> Updating package list..."
  run sudo apt update

  # Bootstrap jq
  if ! command -v jq &>/dev/null; then
    echo "==> Bootstrapping jq..."
    run sudo apt install -y jq
  fi

  # External apt repos (idempotent)
  NEED_UPDATE=false

  # fastfetch — not in standard Ubuntu repos
  if ! apt-cache show fastfetch &>/dev/null 2>&1; then
    echo "==> Adding fastfetch PPA..."
    run sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    NEED_UPDATE=true
  fi

  # eza — not in standard Ubuntu repos
  if ! apt-cache show eza &>/dev/null 2>&1; then
    echo "==> Adding eza apt repo..."
    if [[ "$DRY_RUN" != true ]]; then
      sudo apt install -y gpg
      wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
      echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list > /dev/null
      sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    else
      echo "  [dry-run] add eza community apt repo"
    fi
    NEED_UPDATE=true
  fi

  # gh — GitHub CLI apt repo
  if ! command -v gh &>/dev/null; then
    echo "==> Adding GitHub CLI apt repo..."
    if [[ "$DRY_RUN" != true ]]; then
      wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    else
      echo "  [dry-run] add GitHub CLI apt repo"
    fi
    NEED_UPDATE=true
  fi

  [[ "$NEED_UPDATE" == true ]] && run sudo apt update
else
  # Arch: yay covers repo + AUR, so no external repos needed.
  ensure_yay
  if ! command -v jq &>/dev/null; then
    echo "==> Bootstrapping jq..."
    run sudo pacman -S --needed --noconfirm jq
  fi
fi

# ── High-priority packages ───────────────────────────────────────────────────
echo ""
if [[ "$DISTRO" == "ubuntu" ]]; then
  echo "==> Installing high-priority apt packages..."
  apt_install "high"
else
  echo "==> Installing high-priority packages (yay)..."
  yay_install "high"
fi

# ── pyenv ────────────────────────────────────────────────────────────────────
PYTHON_VERSION="3.12.13"

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "==> pyenv..."
  echo "  [dry-run] eval: curl https://pyenv.run | bash"
  echo "  [dry-run] pyenv install $PYTHON_VERSION && pyenv global $PYTHON_VERSION"
else
  if [[ ! -d "$HOME/.pyenv" ]]; then
    echo "==> Installing pyenv..."
    curl_installs "high" | while IFS='|' read -r name cmd; do
      [[ "$name" == "pyenv" ]] && eval "$cmd"
    done
  else
    echo "==> pyenv already installed"
  fi

  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv &>/dev/null; then
    # Force bash output — pyenv otherwise detects the shell from $SHELL and may
    # emit fish/zsh syntax that this bash script's eval rejects (aborts under set -e).
    eval "$(pyenv init - bash)"
    if ! pyenv versions 2>/dev/null | grep -q "$PYTHON_VERSION"; then
      echo "==> Installing pyenv build dependencies..."
      if [[ "$DISTRO" == "ubuntu" ]]; then
        sudo apt install -y libssl-dev libffi-dev libncurses-dev libreadline-dev \
          libbz2-dev libsqlite3-dev liblzma-dev zlib1g-dev tk-dev
      else
        sudo pacman -S --needed --noconfirm base-devel openssl zlib xz tk
      fi
      echo "==> Installing Python $PYTHON_VERSION via pyenv..."
      pyenv install "$PYTHON_VERSION"
      pyenv global "$PYTHON_VERSION"
    else
      echo "==> Python $PYTHON_VERSION already installed"
    fi
  fi
fi

# ── nvm + Node ───────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "==> nvm..."
  echo "  [dry-run] install nvm via curl"
  echo "  [dry-run] nvm install lts/* && nvm alias default lts/*"
else
  if [ ! -d "$HOME/.nvm" ]; then
    echo "==> Installing nvm..."
    curl_installs "high" | while IFS='|' read -r name cmd; do
      [[ "$name" == "nvm" ]] && eval "$cmd"
    done
  else
    echo "==> nvm already installed"
  fi

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  if command -v nvm &>/dev/null; then
    nvm install 'lts/*'
    nvm alias default 'lts/*'
    nvm use default
  fi
fi

# ── Medium-priority packages ─────────────────────────────────────────────────
echo ""
if [[ "$DISTRO" == "ubuntu" ]]; then
  echo "==> Installing medium-priority apt packages..."
  apt_install "medium"

  echo ""
  echo "==> Installing snap packages..."
  snap_install "medium"

  # bat / fd-find symlinks (Ubuntu installs them as batcat / fdfind)
  echo ""
  echo "==> Setting up bat and fd symlinks..."
  for pair in "batcat bat" "fdfind fd"; do
    src="${pair%% *}"; dst="${pair##* }"
    if command -v "$src" &>/dev/null && ! command -v "$dst" &>/dev/null; then
      run sudo ln -sf "$(command -v "$src")" /usr/local/bin/"$dst"
      echo "  linked $dst → $src"
    else
      echo "  ✓ $dst"
    fi
  done
else
  echo "==> Installing medium-priority packages (yay)..."
  yay_install "medium"
  # Arch ships bat and fd under their real names — no symlinks needed.
fi

# ── Tailscale ────────────────────────────────────────────────────────────────
echo ""
if [[ "$DISTRO" == "ubuntu" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    command -v tailscale &>/dev/null \
      && echo "==> Tailscale already installed" \
      || echo "  [dry-run] eval: curl -fsSL https://tailscale.com/install.sh | sudo sh"
  elif ! command -v tailscale &>/dev/null; then
    echo "==> Installing Tailscale..."
    custom_installs "medium" | while IFS='|' read -r name cmd; do
      [[ "$name" == "tailscale" ]] && eval "$cmd"
    done
  else
    echo "==> Tailscale already installed ($(tailscale version | head -1))"
  fi
else
  # Arch: tailscale was installed in the yay medium batch; just enable the daemon.
  echo "==> Enabling tailscaled service..."
  run sudo systemctl enable --now tailscaled
fi

# ── claude-code ──────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == true ]]; then
  command -v claude &>/dev/null \
    && echo "==> claude-code already installed" \
    || echo "  [dry-run] eval: curl -fsSL https://claude.ai/install.sh | bash"
elif ! command -v claude &>/dev/null; then
  echo "==> Installing claude-code..."
  curl_installs "medium" | while IFS='|' read -r name cmd; do
    [[ "$name" == "claude-code" ]] && eval "$cmd"
  done
else
  echo "==> claude-code already installed"
fi

# ── pipx packages ────────────────────────────────────────────────────────────
# (No-op on Arch: poetry/hf are installed via yay there; nothing maps to pipx.)
echo ""
echo "==> Installing pipx packages..."
if command -v pipx &>/dev/null; then
  pipx ensurepath
  pipx_install "medium"
else
  echo "  pipx not found — skipping"
fi

# ── npm packages ─────────────────────────────────────────────────────────────
echo ""
echo "==> Installing npm packages..."
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
if command -v npm &>/dev/null; then
  npm_install "medium"
else
  echo "  npm not found — skipping"
fi

# ── zsh as default shell ─────────────────────────────────────────────────────
# Use the real login shell from /etc/passwd — $SHELL can be an inherited
# interactive shell (e.g. zsh launched over an SSH session whose login shell is fish).
ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
if [[ -n "$ZSH_BIN" ]]; then
  CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
  if [[ "$CURRENT_SHELL" != "$ZSH_BIN" ]]; then
    echo ""
    echo "==> Setting zsh as default shell (was: ${CURRENT_SHELL:-unknown})..."
    run sudo usermod -s "$ZSH_BIN" "$USER"
  else
    echo ""
    echo "==> zsh already the default login shell"
  fi
fi

# ── zshrc ────────────────────────────────────────────────────────────────────
echo ""
if [[ ! -f "$HOME/.zshrc" ]]; then
  run cp "$SCRIPT_DIR/zshrc.example" "$HOME/.zshrc"
  echo "==> ~/.zshrc installed from zshrc.example"
elif ! diff -q "$SCRIPT_DIR/zshrc.example" "$HOME/.zshrc" &>/dev/null; then
  BACKUP="$HOME/.zshrc.bak.$(date +%Y%m%d_%H%M%S)"
  run cp "$HOME/.zshrc" "$BACKUP"
  run cp "$SCRIPT_DIR/zshrc.example" "$HOME/.zshrc"
  echo "==> ~/.zshrc updated (backup saved to $BACKUP)"
else
  echo "==> ~/.zshrc already up to date"
fi

# ── antidote plugins file ────────────────────────────────────────────────────
echo ""
if [[ ! -f "$HOME/.zsh_plugins.txt" ]]; then
  run cp "$SCRIPT_DIR/zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
  echo "==> ~/.zsh_plugins.txt installed"
elif ! diff -q "$SCRIPT_DIR/zsh_plugins.txt" "$HOME/.zsh_plugins.txt" &>/dev/null; then
  run cp "$SCRIPT_DIR/zsh_plugins.txt" "$HOME/.zsh_plugins.txt"
  echo "==> ~/.zsh_plugins.txt updated"
else
  echo "==> ~/.zsh_plugins.txt already up to date"
fi

# ── Ghostty config ───────────────────────────────────────────────────────────
GHOSTTY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
GHOSTTY_CONFIG="$GHOSTTY_CONFIG_DIR/config"

echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "  [dry-run] mkdir -p $GHOSTTY_CONFIG_DIR"
  echo "  [dry-run] cp ghostty.config → $GHOSTTY_CONFIG"
else
  mkdir -p "$GHOSTTY_CONFIG_DIR"
  if [[ -f "$GHOSTTY_CONFIG" ]] && ! diff -q "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG" &>/dev/null; then
    cp "$GHOSTTY_CONFIG" "${GHOSTTY_CONFIG}.bak"
    cp "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG"
    echo "==> Ghostty config updated (backup saved)"
  elif [[ ! -f "$GHOSTTY_CONFIG" ]]; then
    cp "$SCRIPT_DIR/ghostty.config" "$GHOSTTY_CONFIG"
    echo "==> Ghostty config installed to $GHOSTTY_CONFIG"
  else
    echo "==> Ghostty config already up to date"
  fi
fi

# ── Optional low-priority packages (--optional flag) ─────────────────────────
if [[ "$INCLUDE_OPTIONAL" == true ]]; then
  echo ""
  echo "==> Installing optional (low) packages..."
  if [[ "$DISTRO" == "ubuntu" ]]; then
    apt_install "low"
    snap_install "low"
  else
    yay_install "low"
  fi
  pipx_install "low"
  npm_install "low"

  # Docker (optional)
  if [[ "$DISTRO" == "ubuntu" ]]; then
    if ! command -v docker &>/dev/null; then
      echo "==> Installing Docker..."
      run_eval "curl -fsSL https://get.docker.com | sudo sh"
      run sudo usermod -aG docker "$USER"
      echo "    Log out and back in for the docker group to take effect."
    else
      echo "==> Docker already installed ($(docker --version | head -1))"
    fi
  else
    # Arch: docker was installed in the yay low batch; enable the daemon + group.
    if command -v docker &>/dev/null || [[ "$DRY_RUN" == true ]]; then
      echo "==> Enabling Docker..."
      run sudo systemctl enable --now docker.service
      run sudo usermod -aG docker "$USER"
      echo "    Log out and back in for the docker group to take effect."
    fi
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run complete — nothing was installed."
else
  echo "================================================================"
  echo " Done. A few manual steps remain:"
  echo "================================================================"
  echo ""
  echo "  1. Log out and back in — activates zsh (and docker group if installed)"
  echo ""
  echo "  2. Open a new Ghostty terminal — antidote will clone plugins"
  echo "     on first launch (takes ~10 seconds)"
  echo ""
  echo "  3. Authenticate Tailscale:"
  echo "       sudo tailscale up"
  echo ""
  echo "  4. SSH / GPG keys:"
  echo "       bash SSH_and_GPG/create_ssh_key.sh"
  echo "       bash SSH_and_GPG/create_gpg_key.sh"
  echo ""
  echo "================================================================"
fi
