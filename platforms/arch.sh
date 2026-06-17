#!/usr/bin/env bash
# Arch (CachyOS/Manjaro/…) desktop quirks: yay bootstrap via pacman, hardened
# yay batch installs, pacman -T pyenv build deps, systemd service enables.

# Bootstrap the AUR helper (yay lives in the CachyOS/Arch repos, so pacman
# installs it directly — the one place pacman is required instead of yay).
ensure_yay() {
  if ! command -v yay &>/dev/null; then
    printf '==> Bootstrapping yay (via pacman)...\n'
    run sudo pacman -S --needed --noconfirm base-devel git yay
  else
    printf '==> yay already installed (%s)\n' "$(yay --version 2>/dev/null | head -1)"
  fi
}

platform_bootstrap() {
  # yay covers repo + AUR, so no external repos needed.
  ensure_yay
  if ! command -v jq &>/dev/null; then
    printf '==> Bootstrapping jq...\n'
    run sudo pacman -S --needed --noconfirm jq
  fi
}

# Install repo + AUR packages via yay (handles both uniformly).
# If the batch fails (e.g. a single AUR build breaks), retry one package at a
# time so one failure can't abort the whole run (and skip shell/config steps).
yay_install_tier() {
  local priority="$1" names pkg
  names=$(pkg_names yay "$priority")
  [[ -z "$names" ]] && return 0
  # shellcheck disable=SC2086
  if ! run yay -S --needed --noconfirm $names; then
    printf '  batch install errored — retrying packages individually...\n'
    for pkg in $names; do
      run yay -S --needed --noconfirm "$pkg" || printf '  ✗ failed: %s\n' "$pkg"
    done
  fi
}

platform_install_tier() {
  case "$1" in
    high)
      printf '==> Installing high-priority packages (yay)...\n'
      yay_install_tier high
      ;;
    medium)
      printf '==> Installing medium-priority packages (yay)...\n'
      yay_install_tier medium
      # Arch ships bat and fd under their real names — no symlinks needed.
      ;;
    low)
      yay_install_tier low
      ;;
  esac
}

platform_pyenv_build_deps() {
  # Only install deps not already satisfied. CachyOS ships zlib-ng-compat
  # (which provides zlib), so explicitly requesting the zlib package would
  # conflict; pacman -T treats it as already satisfied and skips it.
  local _pyenv_deps=(base-devel openssl zlib xz tk) _pyenv_need=() _dep
  for _dep in "${_pyenv_deps[@]}"; do
    pacman -T "$_dep" >/dev/null 2>&1 || _pyenv_need+=("$_dep")
  done
  if [[ ${#_pyenv_need[@]} -gt 0 ]]; then
    sudo pacman -S --needed --noconfirm "${_pyenv_need[@]}"
  else
    printf '  build deps already satisfied\n'
  fi
}

platform_tailscale_step() {
  # tailscale was installed in the yay medium batch; just enable the daemon.
  printf '\n==> Enabling tailscaled service...\n'
  run sudo systemctl enable --now tailscaled
}

platform_docker_optional() {
  # docker was installed in the yay low batch; enable the daemon + group.
  if command -v docker &>/dev/null || [[ "$DRY_RUN" == true ]]; then
    printf '==> Enabling Docker...\n'
    run sudo systemctl enable --now docker.service
    run sudo usermod -aG docker "$USER"
    printf '    Log out and back in for the docker group to take effect.\n'
  fi
}

platform_main() {
  linux_main
}
