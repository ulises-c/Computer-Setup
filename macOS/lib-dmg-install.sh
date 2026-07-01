#!/usr/bin/env bash
# Shared helper for installing a macOS app from a .dmg. Sourced (not executed)
# by install-omlx-app.sh and install-cinebench.sh. Each caller resolves the .dmg
# URL its own way (GitHub Releases API + OS-version selection vs a fixed vendor
# URL); this just does the common download → mount → copy → cleanup.

info() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# install_app_from_dmg <dmg_url>
# Downloads the DMG, mounts it, copies the first *.app at the image root into
# /Applications, and cleans up on exit. Dies on any failure.
install_app_from_dmg() {
  local dmg_url="$1"
  local workdir mnt dmg app
  workdir=$(mktemp -d)
  mnt="$workdir/mnt"
  dmg="$workdir/image.dmg"
  # Bake the paths into the trap now: it fires at *script* exit, after this
  # function has returned and its locals are out of scope — a bare "$mnt"
  # reference would then be an unbound-variable error under set -u.
  # shellcheck disable=SC2064  # intentional: expand $mnt/$workdir at register time
  trap "hdiutil detach '$mnt' >/dev/null 2>&1 || true; rm -rf '$workdir'" EXIT

  info "Downloading $(basename "$dmg_url")..."
  curl -fsSL "$dmg_url" -o "$dmg" || die "download failed: $dmg_url"

  info "Mounting disk image..."
  mkdir -p "$mnt"
  hdiutil attach "$dmg" -nobrowse -noverify -mountpoint "$mnt" >/dev/null \
    || die "failed to mount $dmg"

  app=$(find "$mnt" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)
  [[ -n "$app" ]] || die "no .app found inside the disk image"

  info "Installing $(basename "$app") to /Applications..."
  if ! cp -R "$app" /Applications/ 2>/dev/null; then
    die "could not copy to /Applications — drag $(basename "$app") there manually from $dmg_url"
  fi
}
