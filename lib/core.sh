#!/usr/bin/env bash
# Shared engine for the unified root setup.sh (UNIFICATION.md, issue #36).
# Sourced by setup.sh after SETUP_ROOT is set. Platform modules in
# platforms/<platform>.sh provide platform_main() plus the hooks used by
# linux_main(): platform_bootstrap, platform_install_tier,
# platform_pyenv_build_deps, platform_tailscale_step, platform_docker_optional.
# The apt-family hooks (apt_install_tier, platform_tailscale_step,
# platform_docker_optional) default to apt/curl implementations here, shared by
# the Ubuntu desktop and the server profile; arch.sh overrides them for pacman.
# linux_main() runs the shared spine; SERVER_PROFILE gates the desktop-only
# steps off and routes to the server-extras phase.

PACKAGES_JSON="$SETUP_ROOT/packages.json"

PYTHON_VERSION="3.12.13"

PLATFORM=""
SERVER_PROFILE=false
INCLUDE_OPTIONAL=false
INCLUDE_WORK=false
INCLUDE_PERSONAL=false
DRY_RUN=false

core_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --optional) INCLUDE_OPTIONAL=true ;;
      --work)     INCLUDE_WORK=true ;;
      --personal) INCLUDE_PERSONAL=true ;;
      --dry-run)  DRY_RUN=true ;;
      --distro|--platform)
        if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
          printf 'ERROR: %s requires a value (macos|ubuntu|arch|server).\n' "$1" >&2
          exit 1
        fi
        PLATFORM="$2"; shift ;;
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

core_detect_platform() {
  if [[ -z "$PLATFORM" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      PLATFORM="macos"
    else
      local id="" id_like=""
      if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && echo "${ID:-}")"
        # shellcheck disable=SC1091
        id_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
      fi
      case "$id" in
        ubuntu|debian|linuxmint|pop) PLATFORM="ubuntu" ;;
        arch|cachyos|manjaro|endeavouros|garuda|arcolinux) PLATFORM="arch" ;;
        *)
          case "$id_like" in
            *debian*|*ubuntu*) PLATFORM="ubuntu" ;;
            *arch*)            PLATFORM="arch" ;;
          esac ;;
      esac
    fi
  fi
  case "$PLATFORM" in
    macos|ubuntu|arch|server) ;;
    *)
      printf 'ERROR: Unsupported platform (got %s).\n' "${PLATFORM:-unknown}" >&2
      printf '       Re-run with --platform macos|ubuntu|arch|server to override.\n' >&2
      exit 1 ;;
  esac
  if [[ "$PLATFORM" == "server" ]]; then SERVER_PROFILE=true; fi
}

# ── Run helpers ───────────────────────────────────────────────────────────────

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

run_eval() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] eval: %s\n' "$1"
  else
    eval "$1"
  fi
}

# npm supply-chain cooldown: refuse to install package versions younger than
# NPM_MIN_RELEASE_AGE days. Compromised releases of popular packages (e.g. the
# axios RAT, Mar 2026) are typically caught and yanked within hours, so a short
# cooldown blocks them while barely delaying legit updates. See issue #23.
NPM_MIN_RELEASE_AGE=7

configure_npm_cooldown() {
  local npmrc="$HOME/.npmrc" key="min-release-age" tmp
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] set %s=%s in %s\n' "$key" "$NPM_MIN_RELEASE_AGE" "$npmrc"
    return 0
  fi
  touch "$npmrc"
  # Drop any existing entry, then append the desired value (idempotent, portable).
  tmp="$(mktemp)"
  grep -v "^${key}=" "$npmrc" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$NPM_MIN_RELEASE_AGE" >> "$tmp"
  mv "$tmp" "$npmrc"
  printf '  ✓ npm %s=%s (%s-day supply-chain cooldown)\n' "$key" "$NPM_MIN_RELEASE_AGE" "$NPM_MIN_RELEASE_AGE"
}

# Enable pnpm (our daily-driver package manager) via corepack — corepack ships
# with Node — and apply the same supply-chain cooldown. pnpm measures
# minimumReleaseAge in MINUTES and enforces it strictly only when set explicitly
# (the built-in 1-day default is non-strict), so we set it on purpose. Issue #23.
configure_pnpm() {
  local age_minutes=$((NPM_MIN_RELEASE_AGE * 24 * 60))
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] corepack enable && corepack prepare pnpm@latest --activate\n'
    printf '  [dry-run] pnpm config set minimumReleaseAge %s --location=user\n' "$age_minutes"
    return 0
  fi
  if ! command -v corepack &>/dev/null; then
    printf '  ⚠ corepack not found (needs Node ≥16) — skipping pnpm setup\n'
    return 0
  fi
  corepack enable
  corepack prepare pnpm@latest --activate
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$PNPM_HOME/bin:$PATH"
  if command -v pnpm &>/dev/null; then
    pnpm config set minimumReleaseAge "$age_minutes" --location=user
    printf '  ✓ pnpm enabled, minimumReleaseAge=%s min (%s-day cooldown)\n' "$age_minutes" "$NPM_MIN_RELEASE_AGE"
  else
    printf '  ⚠ pnpm not on PATH after corepack — skipped cooldown config\n'
  fi
}

# ── Package selection (unified packages.json) ─────────────────────────────────

# shellcheck disable=SC2016  # $vars below are jq variables, not shell expansions
CORE_JQ_DEFS='
def envok($w; $p):
  (.environment == null) or
  (($w == "true") and (.environment | index("work"))) or
  (($p == "true") and (.environment | index("personal")));
def icfor($plat):
  (.install_command | if type == "object" then .[$plat] else . end);
def pname($plat): (.[$plat + "_name"] // .name);
'

# Space-joined install tokens for one manager × priority tier.
pkg_names() {
  local manager="$1" priority="$2"
  # shellcheck disable=SC2016
  jq -r --arg plat "$PLATFORM" --arg m "$manager" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'[.[] | select(
        .package_manager[$plat] == $m and .priority == $pr and envok($w; $p)
      ) | pname($plat)] | join(" ")' "$PACKAGES_JSON"
}

# install_command of a single package for this platform.
custom_cmd() {
  # shellcheck disable=SC2016
  jq -r --arg plat "$PLATFORM" --arg n "$1" \
    "$CORE_JQ_DEFS"'.[] | select(.name == $n and .package_manager[$plat] != null)
      | icfor($plat) // empty' "$PACKAGES_JSON"
}

# Manual-install reminders for one tier's custom packages that the engine does
# not run itself (handled_by_setup != true).
print_custom_reminders() {
  local priority="$1" items
  # shellcheck disable=SC2016
  items=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'.[] | select(
        .package_manager[$plat] == "custom" and .priority == $pr and
        (.handled_by_setup != true) and envok($w; $p)
      ) | "  - \(.name)\n    \(.description)\n    Install: \(icfor($plat))"' \
    "$PACKAGES_JSON")
  [[ -n "$items" ]] && printf '%s\n' "$items"
  return 0
}

custom_reminders_section() {
  local reminders extra
  reminders="$(print_custom_reminders medium)"
  # priority "none" entries are never auto-installed — always surface them.
  extra="$(print_custom_reminders none)"
  if [[ -n "$extra" ]]; then
    [[ -n "$reminders" ]] && reminders+=$'\n'
    reminders+="$extra"
  fi
  if [[ "$INCLUDE_OPTIONAL" == true ]]; then
    extra="$(print_custom_reminders low)"
    if [[ -n "$extra" ]]; then
      [[ -n "$reminders" ]] && reminders+=$'\n'
      reminders+="$extra"
    fi
  fi
  if [[ -n "$reminders" ]]; then
    printf '\n'
    printf 'Install these manually (require their own repo setup):\n'
    printf '%s\n' "$reminders"
  fi
  return 0
}

pipx_install_tier() {
  local priority="$1"
  # shellcheck disable=SC2016
  jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'.[] | select(
        .package_manager[$plat] == "pipx" and .priority == $pr and envok($w; $p)
      ) | (icfor($plat) // ("pipx install " + .name))' "$PACKAGES_JSON" |
  while read -r cmd; do
    run_eval "$cmd"
  done
}

pnpm_install_tier() {
  local priority="$1" names
  # shellcheck disable=SC2016
  names=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'[.[] | select(
        .package_manager[$plat] == "pnpm" and .priority == $pr and envok($w; $p)
      ) | .name] | join(" ")' "$PACKAGES_JSON")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  run pnpm add -g $names
}

# ── Shared post-install steps ─────────────────────────────────────────────────

# Deploy ~/.zshrc from the shared dotfiles base unless the platform folder
# ships its own zshrc.example override (linux-server does — headless, so its
# zshrc drops Ghostty/fastfetch/notification hooks).
deploy_zshrc() {
  local src="$SETUP_ROOT/dotfiles/zshrc.example" from="dotfiles/zshrc.example"
  if [[ -f "$CONFIG_SRC_DIR/zshrc.example" ]]; then
    src="$CONFIG_SRC_DIR/zshrc.example"
    from="${CONFIG_SRC_DIR##*/}/zshrc.example (platform override)"
  fi
  deploy_config "$src" "$HOME/.zshrc" "$from" yes
}

# Copy a config file into place, backing up a differing existing one.
deploy_config() {
  local src="$1" dst="$2" from="${3:-}" backup="${4:-yes}"
  local label="~${dst#"$HOME"}" suffix="" bkp
  [[ -n "$from" ]] && suffix=" from $from"
  if [[ ! -f "$dst" ]]; then
    run cp "$src" "$dst"
    printf '==> %s installed%s\n' "$label" "$suffix"
  elif ! diff -q "$src" "$dst" &>/dev/null; then
    if [[ "$backup" == yes ]]; then
      bkp="$dst.bak.$(date +%Y%m%d_%H%M%S)"
      run cp "$dst" "$bkp"
      run cp "$src" "$dst"
      printf '==> %s updated (backup saved to %s)\n' "$label" "$bkp"
    else
      run cp "$src" "$dst"
      printf '==> %s updated\n' "$label"
    fi
  else
    printf '==> %s already up to date\n' "$label"
  fi
}

# Use the real login shell from /etc/passwd — $SHELL can be an inherited
# interactive shell (e.g. zsh launched over an SSH session whose login shell is fish).
set_default_shell() {
  local zsh_bin current
  zsh_bin="$(command -v zsh 2>/dev/null || true)"
  [[ -z "$zsh_bin" ]] && return 0
  current="$(getent passwd "$USER" | cut -d: -f7 || true)"
  if [[ "$current" != "$zsh_bin" ]]; then
    printf '\n==> Setting zsh as default shell (was: %s)...\n' "${current:-unknown}"
    run sudo usermod -s "$zsh_bin" "$USER"
  else
    printf '\n==> zsh already the default login shell\n'
  fi
}

# bat / fd-find symlinks (Ubuntu/Debian install them as batcat / fdfind)
setup_bat_fd_symlinks() {
  printf '\n==> Setting up bat and fd symlinks...\n'
  local pair src dst
  for pair in "batcat bat" "fdfind fd"; do
    src="${pair%% *}"; dst="${pair##* }"
    if command -v "$src" &>/dev/null && ! command -v "$dst" &>/dev/null; then
      run sudo ln -sf "$(command -v "$src")" /usr/local/bin/"$dst"
      printf '  linked %s → %s\n' "$dst" "$src"
    else
      printf '  ✓ %s\n' "$dst"
    fi
  done
}

# apt update + jq bootstrap + external apt repos (shared by ubuntu and server).
apt_bootstrap() {
  printf '==> Updating package list...\n'
  run sudo apt update

  if ! command -v jq &>/dev/null; then
    printf '==> Bootstrapping jq...\n'
    run sudo apt install -y jq
  fi

  local need_update=false

  # fastfetch — not in standard Ubuntu repos
  if ! apt-cache show fastfetch &>/dev/null 2>&1; then
    printf '==> Adding fastfetch PPA...\n'
    run sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch
    need_update=true
  fi

  # eza — not in standard Ubuntu repos
  if ! apt-cache show eza &>/dev/null 2>&1; then
    printf '==> Adding eza apt repo...\n'
    if [[ "$DRY_RUN" != true ]]; then
      sudo apt install -y gpg
      wget -qO- https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
      echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
        | sudo tee /etc/apt/sources.list.d/gierens.list > /dev/null
      sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    else
      printf '  [dry-run] add eza community apt repo\n'
    fi
    need_update=true
  fi

  # obs-studio — noble's archive lags; OBS officially recommends their PPA.
  # Ubuntu-only: the server doesn't install obs-studio.
  if [[ "$PLATFORM" == "ubuntu" ]] && ! grep -rq obsproject /etc/apt/sources.list.d/ 2>/dev/null; then
    printf '==> Adding OBS Studio PPA...\n'
    run sudo add-apt-repository -y ppa:obsproject/obs-studio
    need_update=true
  fi

  # gh — GitHub CLI apt repo. Gate on the repo file, not the binary: a stale
  # distro-repo gh (e.g. Ubuntu universe 2.45) must still get migrated (#25).
  if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    printf '==> Adding GitHub CLI apt repo...\n'
    if [[ "$DRY_RUN" != true ]]; then
      wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
      sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    else
      printf '  [dry-run] add GitHub CLI apt repo\n'
    fi
    need_update=true
  fi

  [[ "$need_update" == true ]] && run sudo apt update
  return 0
}

# Shared by the Ubuntu desktop and the Ubuntu Server profile (both ship snapd).
snap_install_tier() {
  local priority="$1" regular_snaps custom_snaps snap_name name cmd
  # shellcheck disable=SC2016
  regular_snaps=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'[.[] | select(
        .package_manager[$plat] == "snap" and .priority == $pr and
        envok($w; $p) and (icfor($plat) == null)
      ) | pname($plat)] | join(" ")' "$PACKAGES_JSON")
  # Snaps needing flags (e.g. --classic) carry their full install_command.
  # shellcheck disable=SC2016
  custom_snaps=$(jq -r --arg plat "$PLATFORM" --arg pr "$priority" \
     --arg w "$INCLUDE_WORK" --arg p "$INCLUDE_PERSONAL" \
    "$CORE_JQ_DEFS"'.[] | select(
        .package_manager[$plat] == "snap" and .priority == $pr and
        envok($w; $p) and (icfor($plat) != null)
      ) | "\(.name)|\(icfor($plat))"' "$PACKAGES_JSON")

  if [[ -n "$regular_snaps" ]]; then
    for snap_name in $regular_snaps; do
      run sudo snap install "$snap_name"
    done
  fi

  if [[ -n "$custom_snaps" ]]; then
    while IFS='|' read -r name cmd; do
      printf '  %s (custom snap)...\n' "$name"
      run_eval "$cmd"
    done <<< "$custom_snaps"
  fi
}

# apt install tier — shared by the Ubuntu desktop and the server profile.
# arch.sh overrides the install path with yay_install_tier.
apt_install_tier() {
  local priority="$1" names
  names=$(pkg_names apt "$priority")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  run sudo apt install -y $names
}

# apt + snap tier composition — shared by the Ubuntu desktop and the server
# profile. Selection is data-driven (package_manager.<platform> in packages.json),
# so each manager runs at every tier uniformly; a package only installs where it
# declares that platform. arch.sh overrides this with the yay batch.
platform_install_tier() {
  case "$1" in
    high)
      printf '==> Installing high-priority apt packages...\n'
      apt_install_tier high
      ;;
    medium)
      printf '==> Installing medium-priority apt packages...\n'
      apt_install_tier medium
      printf '\n==> Installing snap packages...\n'
      snap_install_tier medium
      setup_bat_fd_symlinks
      ;;
    low)
      apt_install_tier low
      snap_install_tier low
      ;;
  esac
}

# Tailscale via the official curl installer — apt-family default (ubuntu + server).
# arch.sh overrides this (tailscale ships in the yay batch; just enable the daemon).
platform_tailscale_step() {
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    command -v tailscale &>/dev/null \
      && printf '==> Tailscale already installed\n' \
      || printf '  [dry-run] eval: curl -fsSL https://tailscale.com/install.sh | sudo sh\n'
  elif ! command -v tailscale &>/dev/null; then
    printf '==> Installing Tailscale...\n'
    eval "$(custom_cmd tailscale)"
  else
    printf '==> Tailscale already installed (%s)\n' "$(tailscale version | head -1)"
  fi
}

# Docker via get.docker.com — apt-family default (ubuntu + server).
# arch.sh overrides this (docker ships in the yay batch; just enable the daemon).
platform_docker_optional() {
  if ! command -v docker &>/dev/null; then
    printf '==> Installing Docker...\n'
    run_eval "curl -fsSL https://get.docker.com | sudo sh"
    run sudo usermod -aG docker "$USER"
    printf '    Log out and back in for the docker group to take effect.\n'
  else
    printf '==> Docker already installed (%s)\n' "$(docker --version | head -1)"
  fi
}

# Echo the other repo setup scripts (those present on disk) for discoverability.
# One list for all platforms — root verify.sh auto-detects, so nothing diverges.
RELATED_SCRIPTS=(
  "agentic-ai/Claude/install.sh|Claude Code config — deploy settings, hooks, and CLAUDE.md into ~/.claude"
  "SSH_and_GPG/create_ssh_key.sh|Generate an SSH key (and add it to GitHub)"
  "SSH_and_GPG/create_gpg_key.sh|Generate a GPG key for signed commits"
  "verify.sh|Verify this install (read-only health check; auto-detects platform)"
)

print_related_scripts() {
  local entry rel desc shown=false
  for entry in "${RELATED_SCRIPTS[@]}"; do
    rel="${entry%%|*}"; desc="${entry#*|}"
    [[ -f "$SETUP_ROOT/$rel" ]] || continue
    if [[ "$shown" == false ]]; then
      printf '  Other setup scripts in this repo:\n'
      shown=true
    fi
    printf '    • %s\n' "$desc"
    printf '        bash %s\n' "$rel"
  done
}

# ── Linux desktop flow (shared by ubuntu and arch modules) ────────────────────

linux_pyenv_flow() {
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf '==> pyenv...\n'
    printf '  [dry-run] eval: curl https://pyenv.run | bash\n'
    printf '  [dry-run] pyenv install %s && pyenv global %s\n' "$PYTHON_VERSION" "$PYTHON_VERSION"
    return 0
  fi
  if [[ ! -d "$HOME/.pyenv" ]]; then
    printf '==> Installing pyenv...\n'
    eval "$(custom_cmd pyenv)"
  else
    printf '==> pyenv already installed\n'
  fi

  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  if command -v pyenv &>/dev/null; then
    # Force bash output — pyenv otherwise detects the shell from $SHELL and may
    # emit fish/zsh syntax that this bash script's eval rejects (aborts under set -e).
    eval "$(pyenv init - bash)"
    if ! pyenv versions 2>/dev/null | grep -qF "$PYTHON_VERSION"; then
      printf '==> Installing pyenv build dependencies...\n'
      platform_pyenv_build_deps
      printf '==> Installing Python %s via pyenv...\n' "$PYTHON_VERSION"
      pyenv install "$PYTHON_VERSION"
      pyenv global "$PYTHON_VERSION"
    else
      printf '==> Python %s already installed\n' "$PYTHON_VERSION"
    fi
  fi
}

linux_nvm_flow() {
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf '==> nvm...\n'
    printf '  [dry-run] install nvm via curl\n'
    printf '  [dry-run] nvm install lts/* && nvm alias default lts/*\n'
    configure_npm_cooldown
    configure_pnpm
    return 0
  fi
  if [ ! -d "$HOME/.nvm" ]; then
    printf '==> Installing nvm...\n'
    eval "$(custom_cmd nvm)"
  else
    printf '==> nvm already installed\n'
  fi

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  if command -v nvm &>/dev/null; then
    nvm install 'lts/*'
    nvm alias default 'lts/*'
    nvm use default
  fi

  # Apply the supply-chain cooldown before any package install runs below.
  configure_npm_cooldown
  configure_pnpm
}

# rustup ships no toolchain — rustc/cargo are proxies that error until
# 'rustup default stable' picks one.
rust_toolchain_step() {
  command -v rustup &>/dev/null || return 0
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] rustup default stable (if no default toolchain)\n'
  elif ! rustup show active-toolchain &>/dev/null; then
    printf '==> Installing stable Rust toolchain...\n'
    run rustup default stable
  else
    printf '==> Rust toolchain already configured (%s)\n' "$(rustup show active-toolchain 2>/dev/null | head -1)"
  fi
}

claude_code_step() {
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    command -v claude &>/dev/null \
      && printf '==> claude-code already installed\n' \
      || printf '  [dry-run] eval: curl -fsSL https://claude.ai/install.sh | bash\n'
  elif ! command -v claude &>/dev/null; then
    printf '==> Installing claude-code...\n'
    eval "$(custom_cmd claude-code)"
  else
    printf '==> claude-code already installed\n'
  fi
}

ghostty_deploy_linux() {
  local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
  local cfg="$cfg_dir/config"
  local src="$SETUP_ROOT/dotfiles/ghostty.config"
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] mkdir -p %s\n' "$cfg_dir"
    printf '  [dry-run] cp ghostty.config → %s\n' "$cfg"
    return 0
  fi
  mkdir -p "$cfg_dir"
  if [[ -f "$cfg" ]] && ! diff -q "$src" "$cfg" &>/dev/null; then
    cp "$cfg" "${cfg}.bak"
    cp "$src" "$cfg"
    printf '==> Ghostty config updated (backup saved)\n'
  elif [[ ! -f "$cfg" ]]; then
    cp "$src" "$cfg"
    printf '==> Ghostty config installed to %s\n' "$cfg"
  else
    printf '==> Ghostty config already up to date\n'
  fi
}

desktop_pipx_section() {
  printf '\n==> Installing pipx packages...\n'
  if command -v pipx &>/dev/null; then
    pipx ensurepath
    pipx_install_tier "medium"
  else
    printf '  pipx not found — skipping\n'
  fi
}

desktop_pnpm_section() {
  printf '\n==> Installing pnpm packages...\n'
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  export PNPM_HOME="$HOME/.local/share/pnpm"
  export PATH="$PNPM_HOME/bin:$PATH"
  if command -v pnpm &>/dev/null; then
    pnpm_install_tier "medium"
  else
    printf '  pnpm not found — skipping\n'
  fi
}

desktop_footer() {
  printf '\n'
  if [[ "$DRY_RUN" == true ]]; then
    printf 'Dry run complete — nothing was installed.\n'
    return 0
  fi
  printf '================================================================\n'
  printf ' Done. A few manual steps remain:\n'
  printf '================================================================\n'
  printf '\n'
  printf '  1. Log out and back in — activates zsh (and docker group if installed)\n'
  printf '\n'
  printf '  2. Open a new Ghostty terminal — antidote will clone plugins\n'
  printf '     on first launch (takes ~10 seconds)\n'
  printf '\n'
  printf '  3. Authenticate Tailscale:\n'
  printf '       sudo tailscale up\n'
  printf '\n'
  printf '  4. Optional — run these from the repo root as needed:\n'
  printf '\n'
  print_related_scripts
  printf '\n'
  printf '================================================================\n'
}

# Shared Linux install spine for the apt/yay desktops and the server profile.
# nvm/node and the rust toolchain run on both (claude-hud's statusline needs
# node; the server installs rustup for cargo tools like railguard); pyenv and
# the remaining desktop-only steps (pipx/pnpm, ghostty) are gated off under
# SERVER_PROFILE, which instead routes to the server-extras phase. The zsh
# stack — zshrc, zsh_plugins.txt, and the p10k config — deploys from dotfiles on
# both (the desktop-only zshrc bits self-disable headless).
linux_main() {
  printf '==> Detected distro family: %s\n' "$PLATFORM"
  if [[ "$SERVER_PROFILE" == true ]]; then
    CONFIG_SRC_DIR="$SETUP_ROOT/linux-server"
  else
    CONFIG_SRC_DIR="$SETUP_ROOT/linux-desktop"
  fi
  platform_bootstrap

  printf '\n'
  platform_install_tier high

  linux_nvm_flow

  if [[ "$SERVER_PROFILE" != true ]]; then
    linux_pyenv_flow
  fi

  printf '\n'
  platform_install_tier medium

  platform_tailscale_step
  [[ "$SERVER_PROFILE" == true ]] && \
    printf "    Run 'sudo tailscale up' to authenticate and connect to your Tailnet.\n"
  claude_code_step
  rust_toolchain_step

  if [[ "$SERVER_PROFILE" != true ]]; then
    desktop_pipx_section
    desktop_pnpm_section
  fi

  set_default_shell
  printf '\n'
  deploy_zshrc
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/tmux.conf" "$HOME/.tmux.conf" "tmux.conf" yes
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/zsh_plugins.txt" "$HOME/.zsh_plugins.txt" "" no
  printf '\n'
  deploy_config "$SETUP_ROOT/dotfiles/p10k.zsh.example" "$HOME/.p10k.zsh" "p10k.zsh.example" yes
  if [[ "$SERVER_PROFILE" == true ]]; then
    # Plugins/prompt are the shared dotfiles set; pre-clone now while the
    # network is provably up rather than lazily on first interactive login.
    server_preclone_antidote
  else
    ghostty_deploy_linux
  fi

  if [[ "$SERVER_PROFILE" == true ]]; then
    printf '\n'
    platform_docker_optional
    if [[ "$INCLUDE_OPTIONAL" == true ]]; then
      printf '\n==> Installing optional (low) packages...\n'
      platform_install_tier low
    fi
    server_extras
    custom_reminders_section
    server_footer
    return 0
  fi

  if [[ "$INCLUDE_OPTIONAL" == true ]]; then
    printf '\n==> Installing optional (low) packages...\n'
    platform_install_tier low
    pipx_install_tier low
    pnpm_install_tier low
    platform_docker_optional
  fi

  custom_reminders_section

  desktop_footer
}
