#!/usr/bin/env bash
set -euo pipefail

# Updates the running 2004Scape stacks whose upstream checkouts have moved on.
# Run nightly by 2004scape-update.timer as the login user (docker group), or by
# hand. For each stack with an update it:
#   1. announces a countdown in game (the client's "System update in m:ss"
#      timer plus chat broadcasts) through the engine's friend-server relay;
#   2. lets the engine shut itself down at zero, which saves and logs out every
#      player (Docker's restart policy is off meanwhile so it stays down);
#   3. takes a fresh game backup (game-backup.service, allowed by a polkit rule);
#   4. fast-forwards the checkouts, rebuilds, starts and waits for healthy;
#   5. on failure rolls the stack back to its previous commits, image and
#      database, and does not retry that target until upstream moves again.
# Stopped stacks are left alone. A manual `git pull` skips the backup, the
# migrations and the rebuild: update through this script.
#
# Usage: bash linux-game-server/2004scape/update.sh [--check]
#   --check  report pending updates and exit without changing anything

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GAME_DIR="$(dirname -- "$SCRIPT_DIR")"
readonly BACKUP_UNIT=game-backup.service
readonly HEALTH_TIMEOUT_SECONDS=900
# The engine force-removes players still logging out after 1024 ticks (~10 min).
readonly STOP_GRACE_SECONDS=700
readonly RS_SDK_IMAGE=computer-setup/rs-sdk:local
readonly RS_SDK_ROLLBACK_IMAGE=computer-setup/rs-sdk:rollback

log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*"; }
die() { log "error: $*" >&2; exit 1; }

CHECK_ONLY=false
case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=true ;;
  *) die "unknown argument: $1 (use --check)" ;;
esac

for env_file in "$SCRIPT_DIR/.env" "$GAME_DIR/lostcity/.env" "$GAME_DIR/rs-sdk/.env"; do
  [[ -f "$env_file" ]] || die "missing $env_file; run linux-game-server/2004scape/setup.sh first"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
done
: "${AUTO_UPDATE:=true}"
: "${UPDATE_COUNTDOWN_MINUTES:=10}"
: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"
[[ "$UPDATE_COUNTDOWN_MINUTES" =~ ^[1-9][0-9]?$ ]] || die "UPDATE_COUNTDOWN_MINUTES must be 1-99"
for path in "$LOSTCITY_RUNTIME_DIR" "$RS_SDK_SOURCE_DIR" "$RS_SDK_DATA_DIR"; do
  [[ "$path" =~ ^/[[:alnum:]_./-]+$ && "$path" != *//* && "$path" != */./* && "$path" != */../* && "$path" != */ ]] \
    || die "unsupported path in a 2004Scape .env: $path"
done
[[ "$(dirname -- "$RS_SDK_DATA_DIR")" != / ]] || die "RS_SDK_DATA_DIR must not sit directly under /"
[[ "$LOSTCITY_REVISION" =~ ^[0-9][0-9a-z.-]*$ ]] || die "unsupported LOSTCITY_REVISION: $LOSTCITY_REVISION"

command -v flock >/dev/null || die "flock is required"
export GIT_TERMINAL_PROMPT=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/computer-setup/2004scape-update"
install -d -m 700 "$STATE_DIR"
exec {LOCK_FD}>"$STATE_DIR/lock"
flock -n "$LOCK_FD" || { log "another update run is in progress"; exit 0; }

notify() {
  local title="$1" body="$2" priority="${3:-default}"
  [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
  local -a auth=()
  [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 "${auth[@]}" \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: video_game" \
    -d "$body" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 \
    || log "warning: ntfy notification failed"
}

# Hooks and fsmonitor are repository config the game containers can write; never run them.
git_() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"; }
compose() {
  local stack="$1"
  shift
  docker compose --project-directory "$GAME_DIR/$stack" -f "$GAME_DIR/$stack/docker-compose.yml" "$@"
}
container_of() { case "$1" in lostcity) printf 'lostcity' ;; rs-sdk) printf 'rs-sdk-server' ;; esac; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }

declare -A OLD=() NEW=() TARGET=()
declare -a PENDING=()
repos_of() {
  case "$1" in
    lostcity) printf '%s\n' "$LOSTCITY_RUNTIME_DIR/engine" "$LOSTCITY_RUNTIME_DIR/content" "$LOSTCITY_RUNTIME_DIR/webclient" ;;
    rs-sdk) printf '%s\n' "$RS_SDK_SOURCE_DIR" ;;
  esac
}
branch_of() {
  case "$1" in
    lostcity) printf '%s' "$LOSTCITY_REVISION" ;;
    rs-sdk) git_ -C "$RS_SDK_SOURCE_DIR" symbolic-ref --short -q HEAD ;;
  esac
}

# Records OLD/NEW for a repo that can fast-forward. Fails on anything that is
# not a clean fast-forward of the checked-out branch.
check_repo() {
  local repo="$1" branch="$2" head upstream
  [[ -n "$branch" && "$(git_ -C "$repo" symbolic-ref --short -q HEAD)" == "$branch" ]] \
    || { log "warning: $repo is not on branch ${branch:-<none>}"; return 1; }
  [[ -z "$(git_ -C "$repo" status --porcelain=v1 --untracked-files=no)" ]] \
    || { log "warning: $repo has local changes"; return 1; }
  git_ -C "$repo" fetch --quiet origin "$branch" || { log "warning: cannot fetch $repo"; return 1; }
  head="$(git_ -C "$repo" rev-parse HEAD)"
  upstream="$(git_ -C "$repo" rev-parse FETCH_HEAD)"
  [[ "$head" != "$upstream" ]] || return 0
  git_ -C "$repo" merge-base --is-ancestor "$head" "$upstream" \
    || { log "warning: $repo has diverged from origin/$branch"; return 1; }
  OLD[$repo]="$head"
  NEW[$repo]="$upstream"
}

# The fresh backup must actually cover the stack; a backup unit installed before
# the stack existed would succeed without its data.
backup_covers() {
  local env
  env="$(systemctl show "$BACKUP_UNIT" -p Environment --value)" || return 1
  case "$1" in
    lostcity) [[ " $env " == *" BACKUP_LOSTCITY_RUNTIME_DIR=$LOSTCITY_RUNTIME_DIR "* ]] ;;
    rs-sdk) [[ " $env " == *" BACKUP_RS_SDK_DATA_DIR=$RS_SDK_DATA_DIR "* ]] ;;
  esac
}

for stack in lostcity rs-sdk; do
  container="$(container_of "$stack")"
  if ! is_running "$container"; then
    log "$stack: not running; left alone"
    continue
  fi
  branch="$(branch_of "$stack")" || branch=""
  mapfile -t repos < <(repos_of "$stack")
  usable=true
  for repo in "${repos[@]}"; do
    check_repo "$repo" "$branch" </dev/null || usable=false
  done
  [[ "$usable" == true ]] || { log "$stack: skipped (see warnings above)"; continue; }
  target=""
  for repo in "${repos[@]}"; do
    [[ -n "${NEW[$repo]:-}" ]] && target+="${repo##*/}@${NEW[$repo]:0:12} "
  done
  target="${target% }"
  if [[ -z "$target" ]]; then
    log "$stack: up to date"
    continue
  fi
  TARGET[$stack]="$target"
  failed=""
  [[ -r "$STATE_DIR/$stack.failed" ]] && read -r failed <"$STATE_DIR/$stack.failed" || true
  if [[ "$failed" == "$target" ]]; then
    log "$stack: update to $target failed before; waiting for upstream to move or for $STATE_DIR/$stack.failed to be removed"
    continue
  fi
  log "$stack: update available ($target)"
  PENDING+=("$stack")
done

[[ ${#PENDING[@]} -gt 0 ]] || exit 0
[[ "$CHECK_ONLY" == false ]] || exit 0
if [[ "$AUTO_UPDATE" != true ]]; then
  for stack in "${PENDING[@]}"; do
    notified=""
    [[ -r "$STATE_DIR/$stack.notified" ]] && read -r notified <"$STATE_DIR/$stack.notified" || true
    if [[ "$notified" != "${TARGET[$stack]}" ]]; then
      notify "2004Scape update available" "$stack: ${TARGET[$stack]}. AUTO_UPDATE is off; run linux-game-server/2004scape/update.sh to apply it."
      printf '%s\n' "${TARGET[$stack]}" >"$STATE_DIR/$stack.notified"
    fi
  done
  log "AUTO_UPDATE is off; not applying"
  exit 0
fi

[[ "$(systemctl show "$BACKUP_UNIT" -p LoadState --value)" == loaded ]] \
  || die "$BACKUP_UNIT is not installed; refusing to update without a backup"
for stack in "${PENDING[@]}"; do
  backup_covers "$stack" \
    || die "$BACKUP_UNIT does not cover $stack; rerun sudo bash linux-game-server/backup/setup.sh first"
done

# --- countdown and graceful shutdown ----------------------------------------
# PHASE drives the exit trap: what an interrupted run must put back.
PHASE=countdown
declare -a HELPER_PIDS=()
restore_after_abort() {
  local rc=$? stack container
  [[ "$PHASE" != finished ]] || return 0
  for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  case "$PHASE" in
    countdown)
      # A pending engine countdown still fires; with the restart policy back it
      # comes straight back up on the current code.
      for stack in "${PENDING[@]}"; do
        container="$(container_of "$stack")"
        if is_running "$container"; then
          docker update --restart=unless-stopped "$container" >/dev/null 2>&1 || true
        else
          compose "$stack" up -d --no-build --force-recreate >/dev/null 2>&1 || true
        fi
      done
      ;;
    stopped)
      for stack in "${PENDING[@]}"; do
        compose "$stack" up -d --no-build --force-recreate >/dev/null 2>&1 || true
      done
      ;;
  esac
  notify "2004Scape update aborted" "The update run stopped during the $PHASE phase (exit $rc). Check the stacks: docker ps; journalctl -u 2004scape-update.service" high
}
trap restore_after_abort EXIT

countdown_seconds=$((UPDATE_COUNTDOWN_MINUTES * 60))
deadline=$(( $(date +%s) + countdown_seconds ))
started="$(date +%s)"
helper="$(<"$SCRIPT_DIR/countdown.js")"
for stack in "${PENDING[@]}"; do
  container="$(container_of "$stack")"
  docker update --restart=no "$container" >/dev/null
  tick=()
  # Lost City's tick is a fixed 600 ms; RS-SDK reads NODE_TICKRATE from its env.
  [[ "$stack" == lostcity ]] && tick=(-e COUNTDOWN_TICK_MS=600)
  docker exec -e COUNTDOWN_DEADLINE_MS="$((deadline * 1000))" "${tick[@]}" "$container" bun -e "$helper" \
    >"$STATE_DIR/$stack.countdown.log" 2>&1 &
  HELPER_PIDS+=("$!")
done
for stack in "${PENDING[@]}"; do
  announced=false
  for _ in $(seq 1 30); do
    if grep -qx announced "$STATE_DIR/$stack.countdown.log"; then announced=true; break; fi
    sleep 1
  done
  [[ "$announced" == true ]] \
    || die "$stack: could not announce the countdown: $(tr '\n' ' ' <"$STATE_DIR/$stack.countdown.log")"
done
log "countdown announced for ${PENDING[*]}; going down at $(date -d "@$deadline" '+%T %Z') for ${TARGET[*]}"

now="$(date +%s)"
(( deadline > now )) && sleep "$((deadline - now))"
for stack in "${PENDING[@]}"; do
  container="$(container_of "$stack")"
  for _ in $(seq 1 "$STOP_GRACE_SECONDS"); do
    is_running "$container" || break
    sleep 1
  done
  if is_running "$container"; then
    log "$stack: engine did not shut down on its countdown; stopping it"
    compose "$stack" stop -t 120 || die "$stack: could not stop"
  fi
done
PHASE=stopped
for pid in "${HELPER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
HELPER_PIDS=()
for stack in "${PENDING[@]}"; do
  container="$(container_of "$stack")"
  state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$container")"
  [[ "$state" == "false 0 false" ]] && docker logs --since "$started" "$container" 2>&1 | grep -q 'Server shutdown complete' \
    || die "$stack: did not shut down cleanly ($state); not updating"
done

# --- backup ------------------------------------------------------------------
log "backing up before the update"
systemctl --no-ask-password restart --wait "$BACKUP_UNIT" \
  || die "$BACKUP_UNIT failed; stacks restarted on their current code without updating"

# --- update, with rollback ------------------------------------------------------
PHASE=updating
wait_healthy() {
  local container="$1" status
  for _ in $(seq 1 $((HEALTH_TIMEOUT_SECONDS / 10))); do
    status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null)" || status=""
    [[ "$status" == "running healthy" ]] && return 0
    sleep 10
  done
  return 1
}

lostcity_snapshot="$LOSTCITY_RUNTIME_DIR.pre-update"
mapfile -t LOSTCITY_REPOS < <(repos_of lostcity)
lostcity_rebuild() {
  docker rm -f lostcity-update >/dev/null 2>&1 || true
  local steps='cd engine && bun install && bun run build'
  [[ "$1" == migrate ]] && steps='cd engine && bun install && bun run sqlite:migrate && bun run build'
  compose lostcity run --rm --no-deps -T --name lostcity-update lostcity bash -c "$steps" </dev/null
}
# Called from `if`, where set -e is off: every step checks its own status.
update_lostcity() {
  local repo f
  rm -rf "$lostcity_snapshot" "$lostcity_snapshot.complete" || return 1
  install -d -m 700 "$lostcity_snapshot" || return 1
  for f in db.sqlite db.sqlite-journal db.sqlite-wal db.sqlite-shm; do
    if [[ -e "$LOSTCITY_RUNTIME_DIR/engine/$f" ]]; then
      cp -a "$LOSTCITY_RUNTIME_DIR/engine/$f" "$lostcity_snapshot/" || return 1
    fi
  done
  touch "$lostcity_snapshot.complete" || return 1
  for repo in "${LOSTCITY_REPOS[@]}"; do
    [[ -z "${NEW[$repo]:-}" ]] || git_ -C "$repo" merge --ff-only --quiet "${NEW[$repo]}" </dev/null || return 1
  done
  lostcity_rebuild migrate || return 1
  compose lostcity up -d --no-build --force-recreate lostcity || return 1
  wait_healthy lostcity
}
rollback_lostcity() {
  local repo f
  compose lostcity stop -t 120 lostcity || true
  for repo in "${LOSTCITY_REPOS[@]}"; do
    [[ -z "${OLD[$repo]:-}" ]] || git_ -C "$repo" reset --hard --quiet "${OLD[$repo]}" </dev/null || return 1
  done
  [[ -e "$lostcity_snapshot.complete" ]] || return 1
  for f in db.sqlite-journal db.sqlite-wal db.sqlite-shm; do rm -f "$LOSTCITY_RUNTIME_DIR/engine/$f" || return 1; done
  cp -a "$lostcity_snapshot/." "$LOSTCITY_RUNTIME_DIR/engine/" || return 1
  lostcity_rebuild no-migrate || return 1
  compose lostcity up -d --no-build --force-recreate lostcity || return 1
  wait_healthy lostcity
}

# The RS-SDK data dir is root-owned (the upstream entrypoint runs as root), so
# its pre-update copy is made and restored by a root container from the image.
rs_sdk_data_op() {
  docker run --rm --network none --entrypoint sh \
    -e NAME="$(basename -- "$RS_SDK_DATA_DIR")" -v "$(dirname -- "$RS_SDK_DATA_DIR")":/parent \
    "$RS_SDK_ROLLBACK_IMAGE" -c "$1"
}
update_rs_sdk() {
  docker image inspect "$RS_SDK_IMAGE" >/dev/null || return 1
  docker tag "$RS_SDK_IMAGE" "$RS_SDK_ROLLBACK_IMAGE" || return 1
  rs_sdk_data_op 'set -e; cd /parent; rm -rf "$NAME.pre-update" "$NAME.pre-update.complete"
    cp -a "$NAME" "$NAME.pre-update"; touch "$NAME.pre-update.complete"' || return 1
  git_ -C "$RS_SDK_SOURCE_DIR" merge --ff-only --quiet "${NEW[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
  compose rs-sdk build rs-sdk </dev/null || return 1
  compose rs-sdk up -d --no-build --force-recreate rs-sdk || return 1
  wait_healthy rs-sdk-server
}
rollback_rs_sdk() {
  compose rs-sdk stop -t 120 rs-sdk || true
  git_ -C "$RS_SDK_SOURCE_DIR" reset --hard --quiet "${OLD[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
  docker image inspect "$RS_SDK_ROLLBACK_IMAGE" >/dev/null || return 1
  docker tag "$RS_SDK_ROLLBACK_IMAGE" "$RS_SDK_IMAGE" || return 1
  rs_sdk_data_op 'set -e; cd /parent; [ -e "$NAME.pre-update.complete" ]
    find "$NAME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a "$NAME.pre-update/." "$NAME/"' || return 1
  compose rs-sdk up -d --no-build --force-recreate rs-sdk || return 1
  wait_healthy rs-sdk-server
}

failures=0
for stack in "${PENDING[@]}"; do
  log "$stack: updating to ${TARGET[$stack]}"
  if "update_${stack//-/_}"; then
    rm -f "$STATE_DIR/$stack.failed" "$STATE_DIR/$stack.notified"
    log "$stack: updated and healthy"
    notify "2004Scape updated" "$stack is back up on ${TARGET[$stack]}." low
    continue
  fi
  failures=$((failures + 1))
  printf '%s\n' "${TARGET[$stack]}" >"$STATE_DIR/$stack.failed"
  log "$stack: update failed; rolling back"
  if "rollback_${stack//-/_}"; then
    log "$stack: rolled back and healthy"
    notify "2004Scape update FAILED" "$stack could not update to ${TARGET[$stack]} and was rolled back; it is back up on its previous code. Not retried until upstream moves." high
  else
    log "$stack: rollback failed; the stack is down"
    notify "2004Scape update FAILED, server DOWN" "$stack failed to update to ${TARGET[$stack]} and the rollback failed. The pre-update database copy is next to its data directory and in tonight's backup. Check: docker ps -a; journalctl -u 2004scape-update.service" urgent
  fi
done
PHASE=finished
exit $(( failures > 0 ))
