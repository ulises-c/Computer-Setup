#!/usr/bin/env bash
# Linux server initial setup script
# Usage: bash linux-server/setup.sh [--optional] [--dry-run]
#   --optional  also install low-priority optional packages
#   --dry-run   print all commands without executing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/linux_server_packages.json"
INCLUDE_OPTIONAL=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --optional) INCLUDE_OPTIONAL=true ;;
    --dry-run)  DRY_RUN=true ;;
  esac
done

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

apt_install() {
  local priority="$1"
  local names
  names=$(jq -r --arg p "$priority" \
    '[.[] | select(.package_manager == "apt" and .priority == $p) | .name] | join(" ")' \
    "$PACKAGES_JSON")
  [[ -n "$names" ]] && run sudo apt install -y $names
}

print_custom_reminders() {
  local priority="$1"
  local items
  items=$(jq -r --arg p "$priority" \
    '.[] | select(.package_manager == "custom" and .priority == $p and (.handled_by_setup != true)) |
     "  - \(.name)\n    \(.description)\n    Install: \(.install_command)"' \
    "$PACKAGES_JSON")
  [[ -n "$items" ]] && echo "$items"
}


# ── apt update ───────────────────────────────────────────────────────────────
echo "==> Updating package list..."
run sudo apt update

# ── Bootstrap: jq ────────────────────────────────────────────────────────────
# jq is needed to parse the packages JSON — install it first if missing.
if ! command -v jq &>/dev/null; then
  echo "==> Bootstrapping jq..."
  run sudo apt install -y jq
fi

# ── External apt repos (idempotent) ──────────────────────────────────────────
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
  run sudo apt install -y gpg
  wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
  echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
    | sudo tee /etc/apt/sources.list.d/gierens.list > /dev/null
  sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
  NEED_UPDATE=true
fi

# gh — GitHub CLI apt repo
if ! command -v gh &>/dev/null; then
  echo "==> Adding GitHub CLI apt repo..."
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  NEED_UPDATE=true
fi

[[ "$NEED_UPDATE" == true ]] && run sudo apt update

# ── apt packages ──────────────────────────────────────────────────────────────
echo ""
echo "==> Installing high-priority packages..."
apt_install "high"

echo ""
echo "==> Installing medium-priority packages..."
apt_install "medium"

if [[ "$INCLUDE_OPTIONAL" == true ]]; then
  echo ""
  echo "==> Installing optional (low) packages..."
  apt_install "low"
fi

# ── bat / fd-find symlinks ────────────────────────────────────────────────────
# Ubuntu installs bat as batcat and fd-find as fdfind due to naming conflicts.
# Symlinks let scripts and tools that expect bat/fd work without aliases.
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

# ── zsh as default shell ──────────────────────────────────────────────────────
ZSH_BIN="$(command -v zsh 2>/dev/null || true)"
if [[ -n "$ZSH_BIN" && "$SHELL" != "$ZSH_BIN" ]]; then
  echo ""
  echo "==> Setting zsh as default shell..."
  run sudo usermod -s "$ZSH_BIN" "$USER"
fi

# ── zshrc ─────────────────────────────────────────────────────────────────────
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

# ── tmux config ───────────────────────────────────────────────────────────────
echo ""
if [[ ! -f "$HOME/.tmux.conf" ]]; then
  run cp "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf"
  echo "==> ~/.tmux.conf installed from tmux.conf"
elif ! diff -q "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf" &>/dev/null; then
  TMUX_BACKUP="$HOME/.tmux.conf.bak.$(date +%Y%m%d_%H%M%S)"
  run cp "$HOME/.tmux.conf" "$TMUX_BACKUP"
  run cp "$SCRIPT_DIR/tmux.conf" "$HOME/.tmux.conf"
  echo "==> ~/.tmux.conf updated (backup saved to $TMUX_BACKUP)"
else
  echo "==> ~/.tmux.conf already up to date"
fi

# ── Tailscale ─────────────────────────────────────────────────────────────────
echo ""
if ! command -v tailscale &>/dev/null; then
  echo "==> Installing Tailscale..."
  run curl -fsSL https://tailscale.com/install.sh | sudo sh
else
  echo "==> Tailscale already installed ($(tailscale version | head -1))"
fi
echo "    Run 'sudo tailscale up' to authenticate and connect to your Tailnet."

# ── Docker ────────────────────────────────────────────────────────────────────
echo ""
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker..."
  run curl -fsSL https://get.docker.com | sudo sh
  run sudo usermod -aG docker "$USER"
  echo "    Docker installed. Log out and back in for the docker group to take effect."
else
  echo "==> Docker already installed ($(docker --version | head -1))"
fi

# ── Cockpit ───────────────────────────────────────────────────────────────────
echo ""
if systemctl is-active --quiet cockpit.socket 2>/dev/null; then
  echo "==> Cockpit already running"
else
  echo "==> Enabling cockpit..."
  run sudo systemctl enable --now cockpit.socket
fi

# ── Manual install reminders ──────────────────────────────────────────────────
CUSTOM_REMINDERS="$(print_custom_reminders "medium")"
[[ "$INCLUDE_OPTIONAL" == true ]] && CUSTOM_REMINDERS+="$(print_custom_reminders "low")"
if [[ -n "$CUSTOM_REMINDERS" ]]; then
  echo ""
  echo "Install these manually (require their own repo setup):"
  echo "$CUSTOM_REMINDERS"
fi

# ── Post-install steps ────────────────────────────────────────────────────────
echo ""
if [[ "$DRY_RUN" == true ]]; then
  echo "Dry run complete — nothing was installed."
else
  echo "================================================================"
  echo " Done. Next steps:"
  echo "================================================================"
  echo ""
  echo "  1. Log out and back in — activates zsh and the docker group"
  echo ""
  echo "  2. Authenticate Tailscale and enable the web UI service:"
  echo "       sudo tailscale up"
  echo "       sudo tailscale set --operator=\$USER"
  echo "       mkdir -p ~/.config/systemd/user"
  echo "       cp linux-server/tailscale-web.service ~/.config/systemd/user/"
  echo "       systemctl --user enable --now tailscale-web"
  echo "       loginctl enable-linger \$USER"
  echo ""
  echo "  3. Set up SSH / GPG keys:"
  echo "       bash SSH_and_GPG/create_ssh_key.sh"
  echo "       bash SSH_and_GPG/create_gpg_key.sh"
  echo ""
  echo "  4. Install nvm + Node, then claude-code:"
  echo "       curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"
  echo "       # re-open shell, then:"
  echo "       nvm install lts/* && nvm alias default lts/*"
  echo "       npm install -g @anthropic-ai/claude-code"
  echo ""
  echo "  5. Start Docker services — see linux-server/README.md for full details"
  echo "       cd linux-server/homepage && cp .env.example .env && docker compose up -d"
  echo ""
  echo "  See linux-server/post-install.md for the complete checklist."
  echo ""
  echo "================================================================"
fi
