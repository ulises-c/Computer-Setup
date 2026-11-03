#!/usr/bin/env bash
set -euo pipefail
cd /opt/server

revision="${LOSTCITY_REVISION:-254}"
config_revision="$(bun -e 'process.stdout.write(JSON.parse(await Bun.file("server.json").text()).rev)')"
[[ "$config_revision" == "$revision" ]] || {
  printf 'Revision mismatch: .env says %s but runtime server.json says %s.\n' "$revision" "$config_revision" >&2
  exit 2
}
case "$revision" in
  225|244|245.2|254|274|289|377-wip) ;;
  *) printf 'Unsupported Lost City revision: %s\n' "$revision" >&2; exit 2 ;;
esac

if [[ -f engine/data/config/world.json || -f engine/.env ]]; then
  printf 'Lost City configuration already exists; refusing to rerun the interactive setup.\n'
  exit 0
fi

clone_project() {
  local project="$1" target="$2"
  if [[ -e "$target" ]]; then
    if [[ ! -d "$target/.git" ]]; then
      printf 'Refusing to overwrite non-git path: %s\n' "$target" >&2
      exit 2
    fi
    local current_branch
    current_branch="$(git -C "$target" branch --show-current)"
    if [[ "$current_branch" != "$revision" ]]; then
      printf 'Expected %s branch %s, found %s; refusing to switch it.\n' "$project" "$revision" "$current_branch" >&2
      exit 2
    fi
    return 0
  fi
  git clone --single-branch --branch "$revision" "https://github.com/LostCityRS/${project}.git" "$target"
}

clone_project Engine-TS engine
clone_project Content content
clone_project Client-TS webclient

cd /opt/server/engine
bun install
bun run setup

if [[ ! -f data/config/world.json && ! -f .env ]]; then
  printf 'Setup completed without creating engine/data/config/world.json or engine/.env.\n' >&2
  exit 1
fi
printf 'Lost City bootstrap complete. The game server was not started.\n'
