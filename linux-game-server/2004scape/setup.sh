#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
game_dir="$repo_root/linux-game-server"

for dir in "$game_dir/2004scape" "$game_dir/lostcity" "$game_dir/rs-sdk"; do
  if [[ ! -f "$dir/.env" ]]; then
    install -m 600 /dev/null "$dir/.env"
    sed "s|/home/<username>|$HOME|g" "$dir/.env.example" > "$dir/.env"
  fi
done

# Validate interpolation and source paths before building either image.
docker compose --project-directory "$game_dir/rs-sdk" -f "$game_dir/rs-sdk/docker-compose.yml" config --quiet
docker compose --project-directory "$game_dir/lostcity" -f "$game_dir/lostcity/docker-compose.yml" config --quiet

printf '%s\n' 'Initializing the vanilla Lost City runtime (interactive; does not start the game).'
bash "$game_dir/lostcity/bootstrap.sh"

printf '%s\n' 'Building the RS-SDK image from the cloned upstream checkout (does not start it).'
docker compose --project-directory "$game_dir/rs-sdk" -f "$game_dir/rs-sdk/docker-compose.yml" build rs-sdk

printf '%s\n' 'Both images are built. The game services remain stopped; use activate.sh after reviewing the LAN/Tailscale-only firewall gate.'
