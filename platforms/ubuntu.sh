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
