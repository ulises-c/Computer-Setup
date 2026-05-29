#!/usr/bin/env bash
# Linux desktop install verification (Ubuntu / Arch)
# Usage: bash linux-desktop/verify.sh [--work] [--personal] [--optional] [--all] [--distro <id>]
#   --work          also check work-only packages
#   --personal      also check personal-only packages
#   --optional      also check low-priority optional packages
#   --all           check everything (implies --work --personal --optional + priority "none")
#   --distro <id>   force distro family (ubuntu|arch); default: auto-detect
#
# Mirrors setup.sh's selection logic, so the packages checked here match what
# `setup.sh` with the same flags would install. Read-only — installs nothing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/linux_desktop_packages.json"
DISTRO=""
INCLUDE_OPTIONAL=false
INCLUDE_WORK=false
INCLUDE_PERSONAL=false
INCLUDE_NONE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --optional) INCLUDE_OPTIONAL=true ;;
    --work)     INCLUDE_WORK=true ;;
    --personal) INCLUDE_PERSONAL=true ;;
    --all)      INCLUDE_OPTIONAL=true; INCLUDE_WORK=true; INCLUDE_PERSONAL=true; INCLUDE_NONE=true ;;
    --distro)   DISTRO="${2:-}"; shift ;;
    *)          echo "Unknown argument: $1" >&2 ;;
  esac
  shift
done

# ── Distro detection (same logic as setup.sh) ────────────────────────────────
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

PASS=0
FAIL=0

check() {
  local label="$1" ok="$2"
  if [[ "$ok" == true ]]; then
    echo "  ✅  $label"
    PASS=$(( PASS + 1 ))
  else
    echo "  ❌  $label"
    FAIL=$(( FAIL + 1 ))
  fi
}

# Build the same environment filter setup.sh uses.
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

# ── Installed-check dispatch ─────────────────────────────────────────────────
is_installed() {
  local mgr="$1" name="$2" rname="$3"
  case "$mgr" in
    yay)
      pacman -Qq "$rname" &>/dev/null && return 0
      command -v "$name" &>/dev/null && return 0
      return 1 ;;
    apt)
      dpkg -s "$rname" &>/dev/null && return 0
      command -v "$name" &>/dev/null && return 0
      return 1 ;;
    snap)
      snap list "$rname" &>/dev/null && return 0
      command -v "$name" &>/dev/null && return 0
      return 1 ;;
    pipx)
      pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx "$rname" && return 0
      command -v "$name" &>/dev/null && return 0
      return 1 ;;
    npm)
      npm list -g --depth=0 2>/dev/null | grep -q " ${name}@" && return 0
      command -v "$name" &>/dev/null && return 0
      return 1 ;;
    curl|custom)
      case "$name" in
        pyenv)       [[ -d "$HOME/.pyenv" ]] && return 0 ;;
        nvm)         [[ -s "$HOME/.nvm/nvm.sh" ]] && return 0 ;;
        claude-code) command -v claude &>/dev/null && return 0 ;;
        *)
          command -v "$name" &>/dev/null && return 0
          pacman -Qq "$rname" &>/dev/null && return 0 ;;
      esac
      return 1 ;;
    *)
      return 1 ;;
  esac
}

# ── Section printer ───────────────────────────────────────────────────────────
verify_section() {
  local section_label="$1" priority="$2"
  local ef rows
  ef=$(env_filter)
  rows=$(jq -r --arg p "$priority" --arg d "$DISTRO" \
    "[.[] | select(
        .package_manager[\$d] != null and
        .priority == \$p and
        $ef
      ) | [.name, .package_manager[\$d], (.[\$d + \"_name\"] // .name), (.optional | tostring)] | @tsv]
     | .[]" \
    "$PACKAGES_JSON")

  [[ -z "$rows" ]] && return

  echo ""
  echo "── $section_label ──────────────────────────────────────────"

  local name mgr rname opt_flag label
  while IFS=$'\t' read -r name mgr rname opt_flag; do
    [[ -z "$name" ]] && continue
    label="$name ($mgr"
    [[ "$rname" != "$name" ]] && label="$label:$rname"
    label="$label)"
    [[ "$opt_flag" == "true" ]] && label="$label [optional]"
    if is_installed "$mgr" "$name" "$rname"; then
      check "$label" true
    else
      check "$label" false
    fi
  done <<< "$rows"
}

# ── Runtime environment + config checks ──────────────────────────────────────
verify_extras() {
  echo ""
  echo "── Runtime environment & configs ────────────────────────────"

  # Login shell
  local login_shell zsh_bin
  login_shell="$(getent passwd "$USER" | cut -d: -f7)"
  zsh_bin="$(command -v zsh 2>/dev/null || true)"
  if [[ -n "$zsh_bin" && "$login_shell" == "$zsh_bin" ]]; then
    check "login shell is zsh ($login_shell)" true
  else
    check "login shell is zsh (currently ${login_shell:-unknown})" false
  fi

  # pyenv + active Python
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv &>/dev/null; then
    local py_ver
    py_ver=$(pyenv version-name 2>/dev/null || echo "")
    if [[ -n "$py_ver" && "$py_ver" != "system" ]]; then
      check "python via pyenv ($py_ver)" true
    else
      check "python via pyenv (no version active — run: pyenv global <ver>)" false
    fi
  else
    check "pyenv on PATH" false
  fi

  # nvm + Node
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null
  if command -v nvm &>/dev/null; then
    local node_ver
    node_ver=$(node --version 2>/dev/null || echo "")
    if [[ -n "$node_ver" ]]; then
      check "node via nvm ($node_ver)" true
    else
      check "node via nvm (run: nvm install 'lts/*')" false
    fi
  else
    check "nvm loadable" false
  fi

  # npm supply-chain cooldown (issue #23)
  if grep -q '^min-release-age=' "$HOME/.npmrc" 2>/dev/null; then
    local mra
    mra=$(grep '^min-release-age=' "$HOME/.npmrc" | tail -1 | cut -d= -f2)
    check "npm min-release-age set (${mra}-day cooldown)" true
  else
    check "npm min-release-age set (run setup.sh)" false
  fi

  # pnpm (daily-driver package manager) + its supply-chain cooldown (issue #23)
  export PNPM_HOME="$HOME/.local/share/pnpm"
  [[ -d "$PNPM_HOME" ]] && export PATH="$PNPM_HOME:$PATH"
  if command -v pnpm &>/dev/null; then
    check "pnpm ($(pnpm --version 2>/dev/null))" true
    local pmra
    pmra=$(pnpm config get minimumReleaseAge 2>/dev/null)
    if [[ -n "$pmra" && "$pmra" != "undefined" && "$pmra" -gt 0 ]] 2>/dev/null; then
      check "pnpm minimumReleaseAge set (${pmra} min)" true
    else
      check "pnpm minimumReleaseAge set (run setup.sh)" false
    fi
  else
    check "pnpm (run setup.sh — corepack enable)" false
  fi

  # Shell config files
  [[ -f "$HOME/.zshrc" ]]            && check "zshrc present (~/.zshrc)" true                  || check "zshrc present (~/.zshrc)" false
  [[ -f "$HOME/.zsh_plugins.txt" ]] && check "antidote plugin list present (~/.zsh_plugins.txt)" true || check "antidote plugin list present (~/.zsh_plugins.txt)" false

  # antidote (Arch AUR package puts it under /usr/share/zsh-antidote)
  if [[ -f /usr/share/zsh-antidote/antidote.zsh ]] || command -v antidote &>/dev/null; then
    check "antidote available" true
  else
    check "antidote available" false
  fi

  # Ghostty config
  local ghostty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config"
  [[ -f "$ghostty_cfg" ]] && check "ghostty config present" true || check "ghostty config present" false

  # Tailscale daemon
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      check "tailscaled service active" true
    else
      check "tailscaled service active (run: sudo systemctl enable --now tailscaled)" false
    fi
  fi
}

# ── Run ───────────────────────────────────────────────────────────────────────
echo "==> Verifying $DISTRO package installs against $PACKAGES_JSON"

verify_extras
verify_section "High priority"   "high"
verify_section "Medium priority" "medium"
[[ "$INCLUDE_OPTIONAL" == true ]] && verify_section "Low priority (optional)" "low"
[[ "$INCLUDE_NONE" == true ]]     && verify_section "Priority none (manual only)" "none"

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────"
echo "  ✅  $PASS ok    ❌  $FAIL missing"
echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "Run setup.sh (with matching flags) to install missing items, or install manually."
else
  echo "All checked items are present."
fi
