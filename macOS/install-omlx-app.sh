#!/usr/bin/env bash
# Installs the oMLX macOS menu-bar app from its GitHub Releases .dmg.
# oMLX ships no Homebrew cask — the native app is .dmg-only (it self-updates
# in-app afterward). Do NOT also install the `omlx` brew formula: the app
# bundles its own server and they collide on port 8000 and ~/.omlx/.
#
# Usage: bash macOS/install-omlx-app.sh
set -euo pipefail

REPO="jundot/omlx"
API="https://api.github.com/repos/${REPO}/releases/latest"

source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib-dmg-install.sh"

# Guard before install_app_from_dmg's own check: skip the GitHub API call
# (rate-limited) on idempotent re-runs
if app_installed oMLX; then
  info "oMLX.app already in /Applications — it self-updates in-app; skipping download"
  exit 0
fi

info "Resolving latest oMLX release..."
dmg_urls=$(curl -fsSL "$API" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.dmg"' \
  | grep -oE 'https://[^"]+\.dmg' || true)
[[ -n "$dmg_urls" ]] || die "could not find a .dmg asset in the latest release of $REPO"

# oMLX ships one DMG per macOS generation (e.g. macos15-sequoia, macos26-27),
# with no architecture variants. Each filename embeds a macosNN token; pick the
# build whose NN is the highest that does not exceed this Mac's major version
# (the newest build that still targets ≤ this OS). Fall back to the first asset
# if none carry a parseable version.
os_major=$(sw_vers -productVersion | cut -d. -f1)
best_ver=-1
dmg_url=""
while IFS= read -r url; do
  [[ -n "$url" ]] || continue
  v=$(grep -oE 'macos[0-9]+' <<< "$url" | grep -oE '[0-9]+' | sort -n | tail -1 || true)
  [[ -n "$v" ]] || continue
  if (( v <= os_major && v > best_ver )); then
    best_ver="$v"
    dmg_url="$url"
  fi
done <<< "$dmg_urls"
[[ -n "$dmg_url" ]] || dmg_url=$(head -1 <<< "$dmg_urls")
info "Selected DMG for macOS $os_major: $(basename "$dmg_url")"

install_app_from_dmg oMLX "$dmg_url"
