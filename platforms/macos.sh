#!/usr/bin/env bash
# macOS quirks: Homebrew bootstrap, brew/brew-cask/custom installs,
# expat-pinned pyenv build (Tahoe fix), App Store reminders.

# Populated by mac_install_list / mac_custom_install_tier; printed at the end.
BREW_FAILURES=()
BREW_TOTAL=0

# mac_install_list <names> <cmd...> — shared [i/N] install loop: prints
# progress, runs "<cmd...> <name>" per package, collects failures into
# BREW_FAILURES instead of aborting the tier.
mac_install_list() {
  local names="$1" name err reason i total label
  shift
  local -a cmd=("$@") list
  label="${cmd[*]}"
  [[ -z "$names" ]] && return 0
  read -ra list <<< "$names"
  total=${#list[@]}
  i=0
  for name in "${list[@]}"; do
    i=$((i + 1))
    if [[ "$DRY_RUN" == true ]]; then
      printf '  [dry-run] [%d/%d] %s %s\n' "$i" "$total" "$label" "$name"
      continue
    fi
    printf '  [%d/%d] %s %s...\n' "$i" "$total" "$label" "$name"
    BREW_TOTAL=$((BREW_TOTAL + 1))
    if ! err=$("${cmd[@]}" "$name" 2>&1); then
      reason=$(printf '%s\n' "$err" | grep -m1 'Error:' | sed 's/^Error: //')
      [[ -z "$reason" ]] && reason=$(printf '%s\n' "$err" | tail -1)
      BREW_FAILURES+=("$label $name: $reason")
      printf '  [FAIL] %s %s — %s\n' "$label" "$name" "$reason"
    fi
  done
}

brew_install_tier() { mac_install_list "$(pkg_names brew "$1")" brew install; }

# --adopt: take ownership of apps already in /Applications (manual installs)
# instead of hard-failing the whole tier (#31)
brew_cask_install_tier() { mac_install_list "$(pkg_names brew-cask "$1")" brew install --cask --adopt; }

mac_custom_install_tier() {
  local priority="$1" cmd
  # Collect failures like the brew tiers (#31) — one failed installer must not
  # abort the rest of the run under set -e. Process substitution (not a pipe)
  # keeps BREW_FAILURES in this shell.
  while read -r cmd; do
    [[ -z "$cmd" ]] && continue
    [[ "$DRY_RUN" == false ]] && BREW_TOTAL=$((BREW_TOTAL + 1))
    if ! run_eval "$cmd"; then
      BREW_FAILURES+=("custom: $cmd")
      printf '  [FAIL] %s\n' "$cmd"
    fi
  done < <(
    # shellcheck disable=SC2016
    jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
       --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
      "$CORE_JQ_DEFS"'.[] | select(
          .package_manager[$plat] == "custom" and prfor($plat) == $pr and
          envok($plat; $w; $p) and (icfor($plat) != null) and (.handled_by_setup == true)
          and .name != "nvm" and tagok($plat)
        ) | icfor($plat)' "$PACKAGES_JSON"
  )
}

mac_pipx_install_tier() { mac_install_list "$(pkg_names pipx "$1")" pipx install; }

# Cache sudo credentials once up front. Homebrew's cask/pkg installers each shell
# out to `sudo`, so without this a fresh install prompts for the password ~6
# times. Prime the timestamp once, then refresh it in the background until this
# script exits so every later sudo call reuses it silently.
mac_prime_sudo() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] sudo -v (cache credentials + background keepalive)\n'
    return 0
  fi
  printf '==> Caching credentials (you may be prompted for your password once)...\n'
  sudo -v || return 0
  # || true: the subshell inherits set -e, and one failed refresh (timestamp
  # revoked mid-run) must not silently kill the keepalive. stdout is redirected
  # so a piped run (setup.sh | tee) sees EOF at exit instead of hanging on the
  # fd this subshell holds for up to 60s.
  ( while true; do sudo -n true || true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) >/dev/null 2>&1 &
}

print_app_store_reminders() {
  local priority="$1" apps
  # shellcheck disable=SC2016
  apps=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'.[] | select(
        .package_manager[$plat] == "app-store" and prfor($plat) == $pr and envok($plat; $w; $p) and tagok($plat)
      ) | "  - \(.name): \(.description)"' "$PACKAGES_JSON")
  [[ -n "$apps" ]] && printf '%s\n' "$apps"
  return 0
}

platform_main() {
  # shellcheck disable=SC2034  # consumed by deploy_zshrc in lib/core.sh
  CONFIG_SRC_DIR="$SETUP_ROOT/macOS"

  # ── sudo priming ──────────────────────────────────────────────────────────────
  mac_prime_sudo

  # ── Homebrew ────────────────────────────────────────────────────────────────
  if ! command -v brew &>/dev/null; then
    printf '==> Installing Homebrew...\n'
    run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    run_eval 'eval "$(/opt/homebrew/bin/brew shellenv)"'
  fi

  # jq is system-provided on macOS; only install via brew if missing.
  command -v jq &>/dev/null || run brew install jq

  # ── High-priority brew formulae (pyenv, expat, pipx) ───────────────────────
  printf '==> Installing high-priority brew formulae...\n'
  brew_install_tier high

  # ── Python (pyenv) ──────────────────────────────────────────────────────────
  # pyenv compiles Python from source using brew's expat, bypassing broken
  # Homebrew Python bottles on macOS Tahoe (missing libexpat symbols).
  local pyenv_python="$HOME/.pyenv/versions/$PYTHON_VERSION/bin/python3.12"

  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] pyenv install %s\n' "$PYTHON_VERSION"
    printf '  [dry-run] pyenv global %s\n' "$PYTHON_VERSION"
  elif ! pyenv versions 2>/dev/null | grep -qF "$PYTHON_VERSION"; then
    printf '==> Installing Python %s via pyenv...\n' "$PYTHON_VERSION"
    LDFLAGS="-L/opt/homebrew/opt/expat/lib" \
    CPPFLAGS="-I/opt/homebrew/opt/expat/include" \
    PKG_CONFIG_PATH="/opt/homebrew/opt/expat/lib/pkgconfig" \
      pyenv install "$PYTHON_VERSION"
    pyenv global "$PYTHON_VERSION"
  fi

  if [[ "$DRY_RUN" == false ]]; then
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init -)"
    export PIPX_DEFAULT_PYTHON="$pyenv_python"
  fi

  # ── Node (nvm) ──────────────────────────────────────────────────────────────
  # nvm installed via curl — brew install nvm causes PATH issues.
  # nvm is kept last in .zshrc so it wins over brew's node.
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] install nvm via curl\n'
    printf '  [dry-run] nvm install lts/* && nvm alias default lts/*\n'
  elif [[ ! -d "$HOME/.nvm" ]]; then
    printf '==> Installing nvm...\n'
    eval "$(custom_cmd nvm)"
  fi

  if [[ "$DRY_RUN" == false ]]; then
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && \. "$NVM_DIR/nvm.sh"
    nvm install 'lts/*'
    nvm alias default 'lts/*'
    nvm use default
  fi

  # Apply the supply-chain cooldown before any package install runs below.
  configure_npm_cooldown
  configure_pnpm

  # ── Medium-priority brew casks ──────────────────────────────────────────────
  printf '==> Installing brew casks...\n'
  brew_cask_install_tier medium

  # ── Claude Code ─────────────────────────────────────────────────────────────
  # Official curl installer instead of brew cask — self-updates in place (#39).
  claude_code_step

  # ── Ghostty config ──────────────────────────────────────────────────────────
  # Written to the XDG path (~/.config/ghostty/) as plain `config`, matching
  # the Linux deploy — Ghostty supports XDG on macOS too. macOS ALSO loads
  # ~/Library/Application Support/com.mitchellh.ghostty/ after XDG with later
  # values overriding, and either location may carry a pre-1.2.3 `config` or a
  # 1.2.3+ `config.ghostty` — rename all of them so the deployed file is the
  # single source of truth.
  local ghostty_cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
  local ghostty_cfg="$ghostty_cfg_dir/config"
  local macos_ghostty_dir="$HOME/Library/Application Support/com.mitchellh.ghostty"
  local stale

  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] mkdir -p %s\n' "$ghostty_cfg_dir"
    [[ -f "$ghostty_cfg" ]] && printf '  [dry-run] backup %s → %s.bak\n' "$ghostty_cfg" "$ghostty_cfg"
    printf '  [dry-run] cp ghostty.config → %s\n' "$ghostty_cfg"
    for stale in "$ghostty_cfg_dir/config.ghostty" "$macos_ghostty_dir/config.ghostty" "$macos_ghostty_dir/config"; do
      [[ -f "$stale" ]] && printf '  [dry-run] rename conflicting config %s → %s.bak\n' "$stale" "$stale"
    done
  else
    mkdir -p "$ghostty_cfg_dir"
    [[ -f "$ghostty_cfg" ]] && cp "$ghostty_cfg" "${ghostty_cfg}.bak"
    cp "$SETUP_ROOT/dotfiles/ghostty.config" "$ghostty_cfg"
    printf '==> Ghostty config written to %s\n' "$ghostty_cfg"
    for stale in "$ghostty_cfg_dir/config.ghostty" "$macos_ghostty_dir/config.ghostty" "$macos_ghostty_dir/config"; do
      if [[ -f "$stale" ]]; then
        mv "$stale" "${stale}.bak"
        printf '==> Renamed conflicting Ghostty config %s → .bak\n' "$stale"
      fi
    done
  fi

  # ── tmux config ─────────────────────────────────────────────────────────────
  # New with the dotfiles consolidation — the legacy macOS setup never deployed
  # a tmux config, so Macs were stuck with the default green status bar.
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/tmux.conf" "$HOME/.tmux.conf" "tmux.conf" yes

  # ── zshrc + antidote plugins ────────────────────────────────────────────────
  # The shared dotfiles zshrc replaces the legacy append-lines approach; the
  # previous ~/.zshrc is backed up. macOS bits in it are guarded on
  # /opt/homebrew and $OSTYPE.
  printf '\n'
  deploy_zshrc
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/zsh_plugins.txt" "$HOME/.zsh_plugins.txt" "" no
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/p10k.zsh.example" "$HOME/.p10k.zsh" "p10k.zsh.example" yes
  printf '\n'

  # ── Git: GPG signing ────────────────────────────────────────────────────────
  run git config --global gpg.program /opt/homebrew/bin/gpg

  # ── Medium-priority pipx packages ───────────────────────────────────────────
  printf '==> Installing pipx packages...\n'
  if [[ "$DRY_RUN" == false ]]; then
    rm -rf ~/.local/pipx/shared
    pipx ensurepath
  fi
  mac_pipx_install_tier medium

  # ── Medium-priority pnpm packages ───────────────────────────────────────────
  printf '==> Installing pnpm packages...\n'
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$PNPM_HOME/bin:$PATH"
  if [[ "$DRY_RUN" == true ]] || command -v pnpm &>/dev/null; then
    pnpm_install_tier medium
    # codeburn's menu-bar app is buggy upstream, so it is NOT installed
    # automatically — the codeburn-menubar packages.json entry surfaces it
    # as a manual reminder instead.
  else
    printf '  pnpm not found — skipping (run corepack enable)\n'
  fi

  # ── Medium-priority brew formulae ───────────────────────────────────────────
  printf '==> Installing brew formulae...\n'
  brew_install_tier medium

  # ── Optional low-priority packages (--optional flag) ────────────────────────
  # priority "none" packages are never auto-installed regardless of flags
  if [[ "$INCLUDE_OPTIONAL" == true ]]; then
    printf '==> Installing optional (low) packages...\n'
    brew_install_tier low
    mac_custom_install_tier low
    brew_cask_install_tier low
    mac_pipx_install_tier low
    command -v pnpm &>/dev/null && pnpm_install_tier low
  fi

  # ── App Store reminders ─────────────────────────────────────────────────────
  printf '\n'
  printf 'Install these manually from the App Store:\n'
  print_app_store_reminders medium
  print_app_store_reminders none
  [[ "$INCLUDE_OPTIONAL" == true ]] && print_app_store_reminders low

  # Custom entries the engine does not run (handled_by_setup != true) —
  # without this they are neither installed nor surfaced (linux_main has it)
  custom_reminders_section

  printf '\n'
  printf 'Optional — run these from the repo root as needed:\n'
  print_related_scripts

  if [[ "$DRY_RUN" == false && $BREW_TOTAL -gt 0 ]]; then
    local ok=$((BREW_TOTAL - ${#BREW_FAILURES[@]}))
    printf '\n==> Brew install summary: %d/%d succeeded\n' "$ok" "$BREW_TOTAL"
    if [[ ${#BREW_FAILURES[@]} -gt 0 ]]; then
      printf '    Failed:\n'
      for f in "${BREW_FAILURES[@]}"; do
        printf '      - %s\n' "$f"
      done
      printf '    Run setup.sh again after resolving the above.\n'
    fi
  fi

  printf '\n'
  [[ "$DRY_RUN" == true ]] && printf 'Dry run complete — nothing was installed.\n' || printf 'Done! Restart your terminal or open a new tab.\n'
}
