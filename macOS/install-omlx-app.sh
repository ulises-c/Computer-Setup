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

info() { printf '  %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl   >/dev/null || die "curl is required"
command -v hdiutil >/dev/null || die "hdiutil is required (macOS only)"

if [[ -d "/Applications/oMLX.app" ]]; then
  info "oMLX.app already in /Applications — it self-updates in-app; skipping download"
  exit 0
fi

info "Resolving latest oMLX release..."
dmg_urls=$(curl -fsSL "$API" \
  | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.dmg"' \
  | grep -oE 'https://[^"]+\.dmg' || true)
[[ -n "$dmg_urls" ]] || die "could not find a .dmg asset in the latest release of $REPO"

# oMLX ships one DMG per macOS generation (e.g. macos15-sequoia vs macos26-27),
# with no architecture variants. Pick the build matching this Mac's major
# version; fall back to the first asset if nothing matches.
os_major=$(sw_vers -productVersion | cut -d. -f1)
if (( os_major >= 26 )); then
  dmg_url=$(grep -iE "macos(26|27)|tahoe" <<< "$dmg_urls" | head -1 || true)
elif (( os_major == 15 )); then
  dmg_url=$(grep -iE "macos15|sequoia" <<< "$dmg_urls" | head -1 || true)
fi
[[ -n "${dmg_url:-}" ]] || dmg_url=$(head -1 <<< "$dmg_urls")
info "Selected DMG for macOS $os_major: $(basename "$dmg_url")"

workdir=$(mktemp -d)
mnt="$workdir/mnt"
dmg="$workdir/omlx.dmg"
cleanup() {
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT

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

printf '\033[32m✓\033[0m oMLX app installed. Launch it from /Applications (Gatekeeper may prompt on first run).\n'
