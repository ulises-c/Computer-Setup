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

source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib-dmg-install.sh"

command -v curl    >/dev/null || die "curl is required"
command -v hdiutil >/dev/null || die "hdiutil is required (macOS only)"

if [[ -d "/Applications/Cinebench.app" ]]; then
  info "Cinebench.app already in /Applications — skipping download"
  exit 0
fi

install_app_from_dmg "$DMG_URL"

printf '\033[32m✓\033[0m Cinebench installed. Launch it from /Applications (Gatekeeper may prompt on first run).\n'
