#!/usr/bin/env bash
# Ubuntu/Debian desktop quirks: apt + snap tier composition, batcat/fdfind
# symlinks, pyenv build deps. The apt install/Tailscale/Docker hooks and apt
# bootstrap are shared defaults in lib/core.sh.

platform_bootstrap() {
  apt_bootstrap
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

platform_main() {
  linux_main
}
