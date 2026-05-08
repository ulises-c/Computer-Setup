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
    '.[] | select(.package_manager == "custom" and .priority == $p) |
     "  - \(.name)\n    \(.description)\n    Install: \(.install_command)"' \
    "$PACKAGES_JSON")
  [[ -n "$items" ]] && echo "$items"
}

# ── Bootstrap: jq ────────────────────────────────────────────────────────────
# jq is needed to parse the packages JSON — install it first if missing.
if ! command -v jq &>/dev/null; then
  echo "==> Bootstrapping jq..."
  run sudo apt update
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
  run chsh -s "$ZSH_BIN"
fi

# ── zshrc ─────────────────────────────────────────────────────────────────────
echo ""
if [[ ! -f "$HOME/.zshrc" ]]; then
  run cp "$SCRIPT_DIR/zshrc.example" "$HOME/.zshrc"
  echo "==> ~/.zshrc installed from zshrc.example"
else
  echo "==> ~/.zshrc already exists — skipping"
  echo "    Reference: $SCRIPT_DIR/zshrc.example"
fi

# ── Manual install reminders ──────────────────────────────────────────────────
echo ""
echo "Install these manually (require their own repo setup):"
print_custom_reminders "medium"
[[ "$INCLUDE_OPTIONAL" == true ]] && print_custom_reminders "low"

echo ""
[[ "$DRY_RUN" == true ]] && echo "Dry run complete — nothing was installed." || echo "Done. Log out and back in to start using zsh."
