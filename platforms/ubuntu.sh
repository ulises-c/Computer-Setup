#!/usr/bin/env bash
# Ubuntu/Debian desktop quirks: pyenv build deps. The apt bootstrap, install
# tiers, snap, symlinks, and Tailscale/Docker hooks are all shared defaults in
# lib/core.sh.

platform_bootstrap() {
  apt_bootstrap
}

platform_pyenv_build_deps() {
  sudo apt install -y libssl-dev libffi-dev libncurses-dev libreadline-dev \
    libbz2-dev libsqlite3-dev liblzma-dev zlib1g-dev tk-dev
}

platform_main() {
  linux_main
}
