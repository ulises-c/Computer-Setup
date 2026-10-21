#!/usr/bin/env bash
set -euo pipefail

service_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$service_dir" rev-parse --show-toplevel)"

if [[ ! -f "$service_dir/.env" ]]; then
  install -m 600 /dev/null "$service_dir/.env"
  sed "s|/home/<username>|$HOME|g" "$service_dir/.env.example" > "$service_dir/.env"
fi
# This file contains only host paths and a public revision selector.
# shellcheck disable=SC1091
source "$service_dir/.env"

source_dir="${LOSTCITY_SOURCE_DIR:-$HOME/github/Server}"
runtime_dir="${LOSTCITY_RUNTIME_DIR:-$HOME/games/lost-city/runtime}"
revision="${LOSTCITY_REVISION:-254}"
case "$revision" in
  225|244|245.2|254|274|289|377-wip) ;;
  *) printf 'Unsupported Lost City revision: %s\n' "$revision" >&2; exit 2 ;;
esac
[[ -d "$source_dir/.git" ]] || { printf 'Missing Lost City checkout: %s\n' "$source_dir" >&2; exit 2; }
[[ -z "$(git -C "$source_dir" status --porcelain=v1)" ]] || {
  printf 'Lost City checkout has changes; refusing to use an uncertain source tree.\n' >&2
  exit 2
}
[[ "$runtime_dir" != "$source_dir" ]] || { printf 'Runtime path must be outside the source checkout.\n' >&2; exit 2; }

install -d -m 700 "$runtime_dir"
[[ -w "$runtime_dir" ]] || { printf 'Runtime directory is not writable: %s\n' "$runtime_dir" >&2; exit 2; }

if [[ ! -f "$runtime_dir/server.json" ]]; then
  python3 - "$runtime_dir/server.json" "$revision" <<'PY'
import json
import os
import sys

path, revision = sys.argv[1:]
with open(path, "x", encoding="utf-8") as stream:
    json.dump({"rev": revision}, stream, indent=2)
    stream.write("\n")
os.chmod(path, 0o600)
PY
fi

cd "$repo_root"
docker compose --project-directory "$service_dir" -f "$service_dir/docker-compose.yml" build bootstrap
printf 'Starting the one-time interactive Lost City setup. It will not start the game server.\n'
docker compose --project-directory "$service_dir" -f "$service_dir/docker-compose.yml" --profile bootstrap run --rm bootstrap

if [[ ! -f "$runtime_dir/engine/data/config/world.json" && ! -f "$runtime_dir/engine/.env" ]]; then
  printf 'Lost City setup did not leave a readable world config; inspect the setup output before activation.\n' >&2
  exit 1
fi
printf 'Lost City runtime initialized at %s. The game server remains stopped.\n' "$runtime_dir"
