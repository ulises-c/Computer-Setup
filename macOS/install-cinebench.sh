#!/usr/bin/env bash
# Installs Maxon Cinebench from its official .dmg.
#
# Why not the Homebrew cask: Maxon serves a rolling build at a stable URL, so
# the cask's pinned SHA256 routinely goes stale and `brew install --cask
# cinebench` dies with "SHA256 mismatch". This downloads the same DMG directly
# and skips the checksum, which is the only reliable unattended install.
#
# Usage: bash macOS/install-cinebench.sh
#   Override the DMG when Maxon ships a new major version:
#   CINEBENCH_DMG_URL=https://.../Cinebench20XX_macOS.dmg bash macOS/install-cinebench.sh
set -euo pipefail

DMG_URL="${CINEBENCH_DMG_URL:-https://mx-app-blob-prod.maxon.net/mx-package-production/website/macos/maxon/cinebench/Cinebench2026_macOS.dmg}"

source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib-dmg-install.sh"

install_app_from_dmg Cinebench "$DMG_URL"
