#!/usr/bin/env bash
# Shared read-only verify engine for the unified root verify.sh (UNIFICATION.md
# Phase 3, issue #36). Sourced by verify.sh after lib/core.sh — reuses
# CORE_JQ_DEFS, PACKAGES_JSON, PLATFORM, INCLUDE_* and core_detect_platform.
# Check semantics are ported from macOS/verify.sh and linux-desktop/verify.sh;
# where they differ per manager (e.g. command -v fallbacks), each platform's
# legacy behavior is preserved.

INCLUDE_NONE=false

verify_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --optional) INCLUDE_OPTIONAL=true ;;
      --work)     INCLUDE_WORK=true ;;
      --personal) INCLUDE_PERSONAL=true ;;
      --all)      INCLUDE_OPTIONAL=true; INCLUDE_WORK=true; INCLUDE_PERSONAL=true; INCLUDE_NONE=true ;;
      --distro|--platform) PLATFORM="${2:-}"; shift ;;
      --profile)
        case "${2:-}" in
          server)  PLATFORM="server" ;;
          desktop) ;;
          *) printf 'ERROR: --profile must be desktop or server (got %s).\n' "${2:-}" >&2; exit 1 ;;
        esac
        shift ;;
      *) printf 'Unknown argument: %s\n' "$1" >&2 ;;
    esac
    shift
  done
}

PASS=0
FAIL=0

check() {
  local label="$1" ok="$2"
  if [[ "$ok" == true ]]; then
    printf '  ✅  %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ❌  %s\n' "$label"
    FAIL=$((FAIL + 1))
  fi
}

# Sets INSTALLED (true|false) and LABEL_NOTE (appended to the check label).
probe_pkg() {
  local mgr="$1" name="$2" rname="$3"
  INSTALLED=false
  LABEL_NOTE=""
  case "$mgr" in
    brew)
      if brew list --formula "$rname" &>/dev/null; then
        INSTALLED=true
      elif command -v "$rname" &>/dev/null; then
        INSTALLED=true
        LABEL_NOTE=" (via system/other)"
      fi ;;
    brew-cask)
      brew list --cask "$rname" &>/dev/null && INSTALLED=true ;;
    app-store)
      [[ -d "/Applications/${rname}.app" || -d "$HOME/Applications/${rname}.app" ]] && INSTALLED=true
      [[ "$INSTALLED" == false ]] && LABEL_NOTE=" (check App Store manually)" ;;
    yay)
      { pacman -Qq "$rname" || command -v "$name"; } &>/dev/null && INSTALLED=true ;;
    apt)
      { dpkg -s "$rname" || command -v "$name"; } &>/dev/null && INSTALLED=true ;;
    snap)
      { snap list "$rname" || command -v "$name"; } &>/dev/null && INSTALLED=true ;;
    pipx)
      pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx "$rname" && INSTALLED=true
      if [[ "$INSTALLED" == false && "$PLATFORM" != "macos" ]]; then
        command -v "$name" &>/dev/null && INSTALLED=true
      fi ;;
    pnpm)
      pnpm list -g --depth=0 2>/dev/null | grep -q " ${rname}@" && INSTALLED=true
      [[ "$INSTALLED" == false ]] && command -v "$name" &>/dev/null && INSTALLED=true ;;
    custom)
      case "$name" in
        pyenv)       [[ -d "$HOME/.pyenv" ]] && INSTALLED=true ;;
        nvm)         [[ -s "$HOME/.nvm/nvm.sh" ]] && INSTALLED=true ;;
        claude-code) command -v claude &>/dev/null && INSTALLED=true ;;
        forgejo-cli) command -v fj &>/dev/null && INSTALLED=true ;;
        zen-browser) flatpak info app.zen_browser.zen &>/dev/null && INSTALLED=true ;;
        *)
          if [[ "$PLATFORM" == "macos" ]]; then
            { brew list --formula "$rname" || command -v "$rname"; } &>/dev/null && INSTALLED=true
          else
            { command -v "$name" || pacman -Qq "$rname"; } &>/dev/null && INSTALLED=true
          fi ;;
      esac ;;
    *)
      LABEL_NOTE=" (unknown manager: $mgr)" ;;
  esac
  return 0
}

verify_section() {
  local section_label="$1" priority="$2" rows
  # shellcheck disable=SC2016
  rows=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'.[] | select(
        .package_manager[$plat] != null and .priority == $pr and envok($w; $p)
      ) | [.name, .package_manager[$plat], pname($plat), (.optional | tostring)] | @tsv' \
    "$PACKAGES_JSON")

  [[ -z "$rows" ]] && return 0

  printf '\n── %s ──────────────────────────────────────────\n' "$section_label"

  local name mgr rname opt_flag label
  while IFS=$'\t' read -r name mgr rname opt_flag; do
    [[ -z "$name" ]] && continue
    label="$name ($mgr"
    [[ "$rname" != "$name" ]] && label="$label:$rname"
    label="$label)"
    [[ "$opt_flag" == "true" ]] && label="$label [optional]"
    probe_pkg "$mgr" "$name" "$rname"
    check "$label$LABEL_NOTE" "$INSTALLED"
  done <<< "$rows"
}

# ── Runtime environment + config checks (ported per platform) ─────────────────

verify_extras_macos() {
  printf '\n── Runtime environments ──────────────────────────────────────\n'

  command -v brew &>/dev/null && check "homebrew (brew)" true || check "homebrew (brew)" false

  command -v pyenv &>/dev/null && check "pyenv" true || check "pyenv" false

  local py_ver
  py_ver=$(pyenv version-name 2>/dev/null || echo "")
  if [[ -n "$py_ver" && "$py_ver" != "system" ]]; then
    check "python via pyenv ($py_ver)" true
  else
    check "python via pyenv (no pyenv version active)" false
  fi

  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1091
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null
  command -v nvm &>/dev/null && check "nvm" true || check "nvm" false

  local node_ver nvm_cur
  node_ver=$(node --version 2>/dev/null || echo "")
  nvm_cur=$(nvm current 2>/dev/null || echo "")
  if [[ -n "$node_ver" && "$nvm_cur" != "system" && -n "$nvm_cur" ]]; then
    check "node via nvm ($node_ver)" true
  else
    check "node via nvm (run: nvm install 'lts/*')" false
  fi

  verify_npm_pnpm_cooldowns

  [[ -f "$HOME/.zshrc" ]]           && check "zshrc present (~/.zshrc)" true                  || check "zshrc present (~/.zshrc)" false
  [[ -f "$HOME/.zsh_plugins.txt" ]] && check "antidote plugin list present (~/.zsh_plugins.txt)" true || check "antidote plugin list present (~/.zsh_plugins.txt)" false
  [[ -f "$HOME/.tmux.conf" ]]       && check "tmux config present (~/.tmux.conf)" true            || check "tmux config present (~/.tmux.conf)" false

  # antidote (brew formula puts antidote.zsh under /opt/homebrew/opt/antidote)
  if [[ -f /opt/homebrew/opt/antidote/share/antidote/antidote.zsh ]]; then
    check "antidote available" true
  else
    check "antidote available" false
  fi

  local ghostty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty"
  [[ -f "$ghostty_cfg" ]] && check "ghostty config at XDG path" true || check "ghostty config at XDG path" false

  if [[ -n "${PIPX_DEFAULT_PYTHON:-}" && -f "${PIPX_DEFAULT_PYTHON:-}" ]]; then
    check "PIPX_DEFAULT_PYTHON → pyenv ($PIPX_DEFAULT_PYTHON)" true
  else
    check "PIPX_DEFAULT_PYTHON → pyenv (set in .zshrc, source it first)" false
  fi
}

verify_extras_linux() {
  printf '\n── Runtime environment & configs ────────────────────────────\n'

  local login_shell zsh_bin
  login_shell="$(getent passwd "$USER" | cut -d: -f7)"
  zsh_bin="$(command -v zsh 2>/dev/null || true)"
  if [[ -n "$zsh_bin" && "$login_shell" == "$zsh_bin" ]]; then
    check "login shell is zsh ($login_shell)" true
  else
    check "login shell is zsh (currently ${login_shell:-unknown})" false
  fi

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

  verify_npm_pnpm_cooldowns

  [[ -f "$HOME/.zshrc" ]]           && check "zshrc present (~/.zshrc)" true                  || check "zshrc present (~/.zshrc)" false
  [[ -f "$HOME/.zsh_plugins.txt" ]] && check "antidote plugin list present (~/.zsh_plugins.txt)" true || check "antidote plugin list present (~/.zsh_plugins.txt)" false
  [[ -f "$HOME/.tmux.conf" ]]       && check "tmux config present (~/.tmux.conf)" true            || check "tmux config present (~/.tmux.conf)" false

  # antidote (Arch AUR package puts it under /usr/share/zsh-antidote)
  if [[ -f /usr/share/zsh-antidote/antidote.zsh ]] || command -v antidote &>/dev/null; then
    check "antidote available" true
  else
    check "antidote available" false
  fi

  local ghostty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config"
  [[ -f "$ghostty_cfg" ]] && check "ghostty config present" true || check "ghostty config present" false

  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      check "tailscaled service active" true
    else
      check "tailscaled service active (run: sudo systemctl enable --now tailscaled)" false
    fi
  fi
}

# npm + pnpm supply-chain cooldown checks (issue #23) — identical on every platform.
verify_npm_pnpm_cooldowns() {
  if grep -q '^min-release-age=' "$HOME/.npmrc" 2>/dev/null; then
    local mra
    mra=$(grep '^min-release-age=' "$HOME/.npmrc" | tail -1 | cut -d= -f2)
    check "npm min-release-age set (${mra}-day cooldown)" true
  else
    check "npm min-release-age set (run setup.sh)" false
  fi

  export PNPM_HOME="$HOME/.local/share/pnpm"
  [[ -d "$PNPM_HOME/bin" ]] && export PATH="$PNPM_HOME/bin:$PATH"
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
}

verify_main() {
  if [[ "$PLATFORM" == "server" ]]; then
    printf 'ERROR: no verify checks for the server profile yet (linux-server has no legacy verify.sh).\n' >&2
    exit 1
  fi

  printf '==> Verifying %s package installs against %s\n' "$PLATFORM" "$PACKAGES_JSON"

  case "$PLATFORM" in
    macos)       verify_extras_macos ;;
    ubuntu|arch) verify_extras_linux ;;
  esac

  verify_section "High priority"   "high"
  verify_section "Medium priority" "medium"
  [[ "$INCLUDE_OPTIONAL" == true ]] && verify_section "Low priority (optional)" "low"
  [[ "$INCLUDE_NONE" == true ]]     && verify_section "Priority none (manual only)" "none"

  printf '\n────────────────────────────────────────────────────────────\n'
  printf '  ✅  %s ok    ❌  %s missing\n\n' "$PASS" "$FAIL"
  if [[ $FAIL -gt 0 ]]; then
    printf 'Run setup.sh (with matching flags) to install missing items, or install manually.\n'
  else
    printf 'All checked items are present.\n'
  fi
}
