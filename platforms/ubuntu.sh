#!/usr/bin/env bash
# Ubuntu/Debian desktop quirks: apt + snap, external apt repos, batcat/fdfind
# symlinks, curl-based Tailscale/Docker installs.

platform_bootstrap() {
  apt_bootstrap
}

apt_install_tier() {
  local priority="$1" names
  names=$(pkg_names apt "$priority")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  run sudo apt install -y $names
}

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

platform_pyenv_build_deps() {
  sudo apt install -y libssl-dev libffi-dev libncurses-dev libreadline-dev \
    libbz2-dev libsqlite3-dev liblzma-dev zlib1g-dev tk-dev
}

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

platform_main() {
  desktop_main
}
