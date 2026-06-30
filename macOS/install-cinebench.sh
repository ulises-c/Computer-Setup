#!/usr/bin/env bash
# Installs Maxon Cinebench from its official .dmg.
#
# Why not the Homebrew cask: Maxon serves a rolling build at a stable URL, so
# the cask's pinned SHA256 routinely goes stale and `brew install --cask
# cinebench` dies with "SHA256 mismatch". This downloads the same DMG directly
# and skips the checksum, which is the only reliable unattended install.
#
# Usage: bash macOS/install-cinebench.sh
set -euo pipefail

DMG_URL="https://mx-app-blob-prod.maxon.net/mx-package-production/website/macos/maxon/cinebench/Cinebench2026_macOS.dmg"

info() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl    >/dev/null || die "curl is required"
command -v hdiutil >/dev/null || die "hdiutil is required (macOS only)"

if [[ -d "/Applications/Cinebench.app" ]]; then
  info "Cinebench.app already in /Applications — skipping download"
  exit 0
fi

workdir=$(mktemp -d)
mnt="$workdir/mnt"
dmg="$workdir/cinebench.dmg"
cleanup() {
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT

info "Downloading $(basename "$DMG_URL")..."
curl -fsSL "$DMG_URL" -o "$dmg" || die "download failed: $DMG_URL"

info "Mounting disk image..."
mkdir -p "$mnt"
hdiutil attach "$dmg" -nobrowse -noverify -mountpoint "$mnt" >/dev/null \
  || die "failed to mount $dmg"

app=$(find "$mnt" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)
[[ -n "$app" ]] || die "no .app found inside the disk image"

info "Installing $(basename "$app") to /Applications..."
if ! cp -R "$app" /Applications/ 2>/dev/null; then
  die "could not copy to /Applications — drag $(basename "$app") there manually from $DMG_URL"
fi

printf '\033[32m✓\033[0m Cinebench installed. Launch it from /Applications (Gatekeeper may prompt on first run).\n'
