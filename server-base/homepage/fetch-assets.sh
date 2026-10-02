#!/usr/bin/env bash
set -euo pipefail

# Download the official RuneScape: Dragonwilds artwork (Jagex) from Steam's CDN
# into a host's gitignored homepage/assets dir. Not committed: the repo is
# public and the artwork is trademarked. Homepage serves assets/icons at
# /icons and assets/images at /images; restart Homepage after the first fetch.
#
#   bash server-base/homepage/fetch-assets.sh <host-dir> [--force]

readonly APP=1374490
readonly COMMUNITY="https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/$APP"
readonly STORE="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/$APP"
readonly ASSETS=(
  "icons/dragonwilds.ico|$COMMUNITY/8fd9d936c9900ff18eef407ae208b8557c8ab517.ico|image/"
  "images/dragonwilds-logo.png|$STORE/5f325bd6474f5d4390aca80e935bb2f28556992b/logo.png|image/png"
  "images/dragonwilds-hero.jpg|$STORE/library_hero.jpg|image/jpeg"
)

host_dir="${1:-}"
force="${2:-}"
[[ -n "$host_dir" && -d "$host_dir/homepage" ]] || {
  printf 'usage: bash %s <host-dir> [--force]\n' "$0" >&2
  exit 1
}
[[ -z "$force" || "$force" == --force ]] || { printf 'error: unknown argument: %s\n' "$force" >&2; exit 1; }

dest="$host_dir/homepage/assets"
mkdir -p "$dest/icons" "$dest/images"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for entry in "${ASSETS[@]}"; do
  IFS='|' read -r rel url want <<< "$entry"
  if [[ -s "$dest/$rel" && "$force" != --force ]]; then
    printf '  ✓ %s\n' "$rel"
    continue
  fi
  type="$(curl -fsSL --max-time 30 -o "$tmp" -w '%{content_type}' "$url")" || {
    printf 'warning: could not fetch %s (Steam asset moved?); card falls back to no artwork\n' "$rel" >&2
    continue
  }
  if [[ "$type" != "$want"* ]]; then
    printf 'warning: %s returned %s, expected %s; skipped\n' "$url" "$type" "$want" >&2
    continue
  fi
  install -m 644 "$tmp" "$dest/$rel"
  printf '  fetched %s\n' "$rel"
done
