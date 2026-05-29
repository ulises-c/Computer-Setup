#!/bin/zsh
# macOS install verification script
# Usage: zsh macOS/verify.sh [--optional] [--all]
#   --optional  also check low-priority optional packages
#   --all       check every package including priority "none"

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGES_JSON="$SCRIPT_DIR/macOS_packages.json"
INCLUDE_OPTIONAL=false
INCLUDE_NONE=false

for arg in "$@"; do
  case "$arg" in
    --optional) INCLUDE_OPTIONAL=true ;;
    --all)      INCLUDE_NONE=true; INCLUDE_OPTIONAL=true ;;
  esac
done

PASS=0
FAIL=0

# ── Check helpers ─────────────────────────────────────────────────────────────

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

brew_installed()      { brew list --formula "$1" &>/dev/null }
cask_installed()      { brew list --cask "$1" &>/dev/null }
npm_installed()       { npm list -g --depth=0 2>/dev/null | grep -q " $1@" }
pipx_installed()      { pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx "$1" }
app_installed()       { [[ -d "/Applications/${1}.app" || -d "$HOME/Applications/${1}.app" ]] }

# ── Section printer ───────────────────────────────────────────────────────────

verify_section() {
  local section_label="$1" priority_filter="$2" opt_filter="$3"

  # Output tab-separated: name <TAB> package_manager <TAB> optional
  local rows
  rows=$(jq -r --arg p "$priority_filter" --argjson opt "$opt_filter" \
    '.[] | select(
        .priority == $p and
        (if $opt then true else .optional == false end)
      ) | [.name, .package_manager, (.optional | tostring)] | @tsv' \
    "$PACKAGES_JSON")

  [[ -z "$rows" ]] && return

  echo ""
  echo "── $section_label ──────────────────────────────────────────────────"

  local name pm opt_flag label_str installed
  while IFS=$'\t' read -r name pm opt_flag; do
    label_str="$name ($pm)"
    [[ "$opt_flag" == "true" ]] && label_str="$label_str [optional]"

    case "$pm" in
      brew)
        if brew_installed "$name"; then
          installed=true
        elif command -v "$name" &>/dev/null; then
          installed=true
          label_str="$label_str (via system/other)"
        else
          installed=false
        fi
        ;;
      brew-cask)
        cask_installed "$name" && installed=true || installed=false ;;
      npm)
        npm_installed "$name" && installed=true || installed=false ;;
      pipx)
        pipx_installed "$name" && installed=true || installed=false ;;
      curl)
        # nvm — check for ~/.nvm directory
        if [[ "$name" == "nvm" ]]; then
          [[ -d "$HOME/.nvm" ]] && installed=true || installed=false
        else
          installed=false
          label_str="$label_str (manual check required)"
        fi
        ;;
      app-store)
        app_installed "$name" && installed=true || installed=false
        [[ "$installed" == "false" ]] && label_str="$label_str (check App Store manually)"
        ;;
      *)
        installed=false
        label_str="$label_str (unknown manager: $pm)"
        ;;
    esac

    check "$label_str" "$installed"
  done <<< "$rows"
}

# ── Extra checks (runtime environments not in JSON) ───────────────────────────

verify_extras() {
  echo ""
  echo "── Runtime environments ──────────────────────────────────────"

  # Homebrew
  command -v brew &>/dev/null && check "homebrew (brew)" true || check "homebrew (brew)" false

  # pyenv
  command -v pyenv &>/dev/null && check "pyenv" true || check "pyenv" false

  # Python via pyenv
  local py_ver
  py_ver=$(pyenv version-name 2>/dev/null || echo "")
  if [[ -n "$py_ver" && "$py_ver" != "system" ]]; then
    check "python via pyenv ($py_ver)" true
  else
    check "python via pyenv (no pyenv version active)" false
  fi

  # nvm
  export NVM_DIR="$HOME/.nvm"
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null
  command -v nvm &>/dev/null && check "nvm" true || check "nvm" false

  # Node (nvm-managed)
  local node_ver nvm_cur
  node_ver=$(node --version 2>/dev/null || echo "")
  nvm_cur=$(nvm current 2>/dev/null || echo "")
  if [[ -n "$node_ver" && "$nvm_cur" != "system" && -n "$nvm_cur" ]]; then
    check "node via nvm ($node_ver)" true
  else
    check "node via nvm (run: nvm install 'lts/*')" false
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

  # Ghostty XDG config
  local ghostty_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty"
  [[ -f "$ghostty_cfg" ]] && check "ghostty config at XDG path" true || check "ghostty config at XDG path" false

  # PIPX_DEFAULT_PYTHON pointing to pyenv python
  if [[ -n "$PIPX_DEFAULT_PYTHON" && -f "$PIPX_DEFAULT_PYTHON" ]]; then
    check "PIPX_DEFAULT_PYTHON → pyenv ($PIPX_DEFAULT_PYTHON)" true
  else
    check "PIPX_DEFAULT_PYTHON → pyenv (set in .zshrc, source it first)" false
  fi
}

# ── Run ───────────────────────────────────────────────────────────────────────

echo "==> Verifying macOS package installs against $PACKAGES_JSON"

verify_extras

verify_section "High priority" "high" false

verify_section "Medium priority" "medium" false

if [[ "$INCLUDE_OPTIONAL" == true ]]; then
  verify_section "Low priority (optional)" "low" true
fi

if [[ "$INCLUDE_NONE" == true ]]; then
  verify_section "Priority none (manual only)" "none" true
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────────────"
echo "  ✅  $PASS installed    ❌  $FAIL missing"
echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "Run setup.sh to install missing packages, or install them manually."
else
  echo "All checked packages are installed."
fi
