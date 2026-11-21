#!/usr/bin/env bash
# Deterministic Darkan installer for the game server: writes .env, pins the
# upstream checkout and its cache submodule to DARKAN_SOURCE_REF, creates the
# data directories and builds the image. It never starts a service; run
# activate.sh for that.
# Usage: bash linux-game-server/darkan/setup.sh
set -euo pipefail

if [[ "$(id -u)" == 0 ]]; then
  printf 'error: run as the normal user, not root\n' >&2
  exit 2
fi
for cmd in git docker openssl; do
  command -v "$cmd" >/dev/null || { printf 'error: %s is required\n' "$cmd" >&2; exit 2; }
done

darkan_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$darkan_dir" rev-parse --show-toplevel)"
env_file="$darkan_dir/.env"
compose=(docker compose --project-directory "$darkan_dir" -f "$darkan_dir/docker-compose.yml")

env_get() {
  local line
  line="$(grep -E "^$1=" "$env_file" | tail -n1 || true)"
  printf '%s' "${line#*=}"
}

env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "$env_file.XXXXXX")"
  awk -v k="$key" -v v="$value" 'BEGIN { done = 0 }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' "$env_file" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$env_file"
}

fill_if_blank() {
  [[ -n "$(env_get "$1")" ]] || env_set "$1" "$2"
}

if [[ ! -f "$env_file" ]]; then
  install -m 600 /dev/null "$env_file"
  sed "s|/home/<username>|$HOME|g" "$darkan_dir/.env.example" >"$env_file"
  printf 'Wrote %s\n' "$env_file"
fi
chmod 600 "$env_file"

fill_if_blank DARKAN_UID "$(id -u)"
fill_if_blank DARKAN_GID "$(id -g)"
fill_if_blank DARKAN_LOBBY_OWNER "$(id -un)"
for key in DARKAN_MONGO_PASSWORD DARKAN_SOCIAL_GATEWAY_TOKEN DARKAN_WORLD_LOGIN_TOKEN_SECRET DARKAN_API_KEY; do
  fill_if_blank "$key" "$(openssl rand -hex 32)"
done

if [[ "$(env_get DARKAN_PUBLIC_HOST)" == *'<'* ]]; then
  command -v tailscale >/dev/null || { printf 'error: set DARKAN_PUBLIC_HOST in %s\n' "$env_file" >&2; exit 2; }
  dns_name="$(tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
  [[ -n "$dns_name" ]] || { printf 'error: no Tailscale DNS name; set DARKAN_PUBLIC_HOST\n' >&2; exit 2; }
  env_set DARKAN_PUBLIC_HOST "$dns_name"
fi

source_url="$(env_get DARKAN_SOURCE_URL)"
source_dir="$(env_get DARKAN_SOURCE_DIR)"
source_ref="$(env_get DARKAN_SOURCE_REF)"
cache_url="$(env_get DARKAN_CACHE_SOURCE_URL)"
data_dir="$(env_get DARKAN_DATA_DIR)"

[[ "$source_ref" =~ ^[0-9a-f]{40}$ ]] || {
  printf 'error: DARKAN_SOURCE_REF must be a full 40-character commit id, got %s\n' "$source_ref" >&2
  exit 2
}
for path in "$source_dir" "$data_dir"; do
  [[ "$path" == /* && "$path" != *'<'* ]] || { printf 'error: not an absolute path: %s\n' "$path" >&2; exit 2; }
done

if [[ ! -d "$source_dir/.git" ]]; then
  printf 'Cloning %s into %s\n' "$source_url" "$source_dir"
  git clone --quiet "$source_url" "$source_dir"
fi
[[ "$(git -C "$source_dir" remote get-url origin)" == "$source_url" ]] || {
  printf 'error: %s origin is not %s; refusing to reuse it\n' "$source_dir" "$source_url" >&2
  exit 2
}
if [[ -n "$(git -C "$source_dir" status --porcelain --ignore-submodules=all)" ]]; then
  printf 'error: %s has local changes; the image must build a clean checkout\n' "$source_dir" >&2
  exit 2
fi
git -C "$source_dir" cat-file -e "$source_ref^{commit}" 2>/dev/null || git -C "$source_dir" fetch --quiet origin
git -C "$source_dir" -c advice.detachedHead=false checkout --quiet --detach "$source_ref"
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$source_ref" ]] || { printf 'error: checkout is not at %s\n' "$source_ref" >&2; exit 2; }

git -C "$source_dir" config submodule.cache-source.url "$cache_url"
cache_ref="$(git -C "$source_dir" rev-parse "HEAD:cache-source")"
if [[ "$(git -C "$source_dir/cache-source" rev-parse HEAD 2>/dev/null || true)" != "$cache_ref" ]]; then
  printf 'Fetching cache-source %s (several GB the first time)\n' "$cache_ref"
  git -C "$source_dir" submodule update --init --depth 1 cache-source
fi
[[ "$(git -C "$source_dir/cache-source" rev-parse HEAD)" == "$cache_ref" ]] || {
  printf 'error: cache-source is not at %s\n' "$cache_ref" >&2
  exit 2
}
[[ -f "$source_dir/cache-source/cache.json" && -d "$source_dir/cache-source/gamevals" ]] || {
  printf 'error: %s/cache-source is incomplete\n' "$source_dir" >&2
  exit 2
}

install -d -m 700 "$data_dir"
for sub in mongo lobby lobby/cache world; do
  install -d -m 700 "$data_dir/$sub"
done

[[ -f "$repo_root/server-base/timezone.env" ]] || bash "$repo_root/server-base/timezone.sh"

"${compose[@]}" config --quiet
printf 'Building computer-setup/darkan:local from %s\n' "$source_ref"
"${compose[@]}" build darkan-lobby
"${compose[@]}" pull darkan-mongo

printf 'Built. Services are not started; run activate.sh next.\n'
