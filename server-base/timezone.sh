#!/usr/bin/env bash
# Writes the host's time zone to server-base/timezone.env, which every
# compose service loads as env_file. Run after changing the host zone with
# timedatectl; --apply then recreates the running compose services whose TZ is
# stale or unset.
# Usage: bash server-base/timezone.sh [--apply] [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TIMEZONE_ENV="${TIMEZONE_ENV:-$SCRIPT_DIR/timezone.env}"
ZONEINFO_DIR="${ZONEINFO_DIR:-/usr/share/zoneinfo}"
LOCALTIME_PATH="${LOCALTIME_PATH:-/etc/localtime}"

APPLY=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      printf 'Usage: %s [--apply] [--dry-run]\n' "$0"
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

host_zone() {
  local zone="" target
  if command -v timedatectl &>/dev/null; then
    zone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [[ -z "$zone" && -L "$LOCALTIME_PATH" ]]; then
    target="$(readlink "$LOCALTIME_PATH")"
    if [[ "$target" == *zoneinfo/* ]]; then
      zone="${target#*zoneinfo/}"
    fi
  fi
  printf '%s' "$zone"
}

ZONE="$(host_zone)"
if [[ -z "$ZONE" ]]; then
  printf 'error: cannot determine the host time zone (timedatectl, %s)\n' "$LOCALTIME_PATH" >&2
  exit 1
fi
if [[ ! "$ZONE" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ || ! -f "$ZONEINFO_DIR/$ZONE" ]]; then
  printf 'error: invalid time zone %q (not under %s)\n' "$ZONE" "$ZONEINFO_DIR" >&2
  exit 1
fi

CONTENT="TZ=$ZONE"
if [[ -f "$TIMEZONE_ENV" && "$(<"$TIMEZONE_ENV")" == "$CONTENT" ]]; then
  printf 'unchanged: %s (%s)\n' "$TIMEZONE_ENV" "$CONTENT"
elif [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] write %s: %s\n' "$TIMEZONE_ENV" "$CONTENT"
else
  tmp="$(mktemp "$TIMEZONE_ENV.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$CONTENT" >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$TIMEZONE_ENV"
  printf 'wrote %s: %s\n' "$TIMEZONE_ENV" "$CONTENT"
fi

[[ "$APPLY" == true ]] || exit 0

if ! command -v docker &>/dev/null; then
  printf 'error: docker not found; cannot --apply\n' >&2
  exit 1
fi
if ! ids="$(docker ps -q)"; then
  printf 'error: cannot list containers (needs the docker group or sudo)\n' >&2
  exit 1
fi

containers=""
if [[ -n "$ids" ]]; then
  # shellcheck disable=SC2086 # one container ID per word
  containers="$(docker inspect $ids | jq -r '
    .[]
    | (.Config.Labels // {}) as $l
    | ([.Config.Env[]? | select(startswith("TZ=")) | .[3:]] | last // "") as $tz
    | [.Name[1:], $tz,
       ($l["com.docker.compose.project"] // ""),
       ($l["com.docker.compose.project.working_dir"] // ""),
       ($l["com.docker.compose.project.config_files"] // ""),
       ($l["com.docker.compose.service"] // "")]
    | join("\u001f")' | sort -t $'\x1f' -k3,3 -k6,6)"
fi

run_compose() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run]'
    printf ' %q' docker "$@"
    printf '\n'
  else
    docker "$@"
  fi
}

recreate() {
  local project="$1" workdir="$2" config_files="$3"
  shift 3
  local -a args=(compose -p "$project" --project-directory "$workdir")
  local file
  local IFS=,
  for file in $config_files; do
    args+=(-f "$file")
  done
  run_compose "${args[@]}" up -d --no-deps "$@"
}

current=0 skipped=0 projects=0 recreated=0
project="" workdir="" config_files=""
services=()
flush() {
  if (( ${#services[@]} > 0 )); then
    recreate "$project" "$workdir" "$config_files" "${services[@]}"
    projects=$((projects + 1))
    recreated=$((recreated + ${#services[@]}))
  fi
  services=()
}

while IFS=$'\x1f' read -r name tz c_project c_workdir c_files c_service; do
  [[ -n "$name" ]] || continue
  if [[ "$tz" == "$ZONE" ]]; then
    current=$((current + 1))
    continue
  fi
  if [[ -z "$c_project" || -z "$c_workdir" || -z "$c_files" || -z "$c_service" ]]; then
    printf 'skip %s: TZ=%s but not a compose service; recreate it by hand\n' "$name" "${tz:-(unset)}"
    skipped=$((skipped + 1))
    continue
  fi
  if [[ "$c_project" != "$project" ]]; then
    flush
    project="$c_project" workdir="$c_workdir" config_files="$c_files"
  fi
  if (( ${#services[@]} == 0 )) || [[ "${services[${#services[@]}-1]}" != "$c_service" ]]; then
    services+=("$c_service")
  fi
  printf 'stale %s (%s/%s): TZ=%s\n' "$name" "$c_project" "$c_service" "${tz:-(unset)}"
done <<< "$containers"
flush

printf 'apply: %d service(s) recreated in %d project(s), %d container(s) already on %s, %d skipped\n' \
  "$recreated" "$projects" "$current" "$ZONE" "$skipped"
