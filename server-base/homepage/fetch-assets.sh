#!/usr/bin/env bash
set -euo pipefail

# Download the official RuneScape: Dragonwilds artwork (Jagex) from Steam's CDN,
# the 2004Scape title art and logo from Lost City's content repo, the RS-SDK
# Lava Maze art, the Lost City avatar and the OpenRGB logo into a host's
# gitignored homepage/assets dir. Not committed: the repo is public and the
# artwork is trademarked. Game repos are pinned to commits so a moved file
# cannot silently swap the art. Homepage serves assets/icons at /icons and
# assets/images at /images; restart Homepage after the first fetch.
#
#   bash server-base/homepage/fetch-assets.sh <host-dir> [--force]

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly HERE
readonly APP=1374490
readonly COMMUNITY="https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/$APP"
readonly STORE="https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/$APP"
readonly OPENRGB="https://gitlab.com/CalcProgrammer1/OpenRGB/-/raw/release_1.0/qt/OpenRGB.ico"
readonly LOSTCITY_CONTENT="https://raw.githubusercontent.com/LostCityRS/Content/0561dddd04f371869781513166c560436ee2d832"
readonly RS_SDK="https://raw.githubusercontent.com/MaxBittker/rs-sdk/b565f2d920bf6f5ec427bc6f66dc6fd64a2e15c1"
# <dest>|<url>|<content-type prefix>[|colorkey: make the sprite's #ff00ff transparent]
readonly ASSETS=(
  "icons/dragonwilds.ico|$COMMUNITY/8fd9d936c9900ff18eef407ae208b8557c8ab517.ico|image/"
  "images/dragonwilds-logo.png|$STORE/5f325bd6474f5d4390aca80e935bb2f28556992b/logo.png|image/png"
  "images/dragonwilds-hero.jpg|$STORE/library_hero.jpg|image/jpeg"
  "icons/openrgb.ico|$OPENRGB|image/"
  "icons/lostcity.jpg|https://avatars.githubusercontent.com/u/162514437?s=128&v=4|image/"
  "images/lostcity-title.jpg|$LOSTCITY_CONTENT/binary/title.jpg|image/jpeg"
  "images/runescape-logo.png|$LOSTCITY_CONTENT/title/logo.png|image/png|colorkey"
  "images/rs-sdk-lava-maze.jpg|$RS_SDK/server/engine/public/img/lava_maze_runite.jpg|image/jpeg"
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
trap 'rm -f "$tmp" "$tmp.keyed"' EXIT

for entry in "${ASSETS[@]}"; do
  IFS='|' read -r rel url want transform <<< "$entry"
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
  if [[ "$transform" == colorkey ]] && ! python3 "$HERE/png_colorkey.py" "$tmp" "$tmp.keyed"; then
    printf 'warning: could not key out the background of %s; skipped\n' "$rel" >&2
    continue
  fi
  [[ "$transform" == colorkey ]] && mv "$tmp.keyed" "$tmp"
  install -m 644 "$tmp" "$dest/$rel"
  printf '  fetched %s\n' "$rel"
done
