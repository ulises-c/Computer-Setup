#!/usr/bin/env bash
set -euo pipefail

# Usage: maintenance.sh [--now | --check | --resume]
# Scheduled maintenance uses the next backup's weekday and shutdown deadline.
# Interrupted updates retain a recovery marker until rollback succeeds.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GAME_DIR="$(dirname -- "$SCRIPT_DIR")"
readonly BACKUP_UNIT=game-backup.service
readonly BACKUP_TIMER=game-backup.timer
readonly VERIFY_UNIT=game-backup-restore-check.service
readonly HEALTH_TIMEOUT_SECONDS=900
# The engine runs its shutdown ticks back to back once the countdown ends, so it
# exits within seconds; one still up after this never got the countdown.
readonly STOP_GRACE_SECONDS=180
readonly DOWN_BEFORE_BACKUP_SECONDS=120
readonly RS_SDK_IMAGE=computer-setup/rs-sdk:local
readonly RS_SDK_ROLLBACK_IMAGE=computer-setup/rs-sdk:rollback
readonly LOSTCITY_IMAGE=computer-setup/lostcity:node24

log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*"; }
die() { log "error: $*" >&2; exit 1; }

MODE=scheduled
case "${1:-}" in
  "") ;;
  --now) MODE=now ;;
  --check) MODE=check ;;
  --resume) MODE=resume ;;
  *) die "unknown argument: $1 (use --now, --check or --resume)" ;;
esac

for env_file in "$SCRIPT_DIR/.env" "$GAME_DIR/lostcity/.env" "$GAME_DIR/rs-sdk/.env"; do
  [[ -f "$env_file" ]] || die "missing $env_file; run linux-game-server/2004scape/setup.sh first"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
done
: "${AUTO_UPDATE:=true}"
# RS-SDK never updates world 1 directly any more (see world.sh): candidate = build
# upstream + this repo's patch scripts into a candidate image and notify; the owner
# tests it on the test world and promotes it. direct = the old in-place update;
# notify = only report.
: "${RS_SDK_UPDATES:=candidate}"
: "${MAINTENANCE_DAY:=Mon}"
: "${COUNTDOWN_MINUTES:=10}"
: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"
[[ "$RS_SDK_UPDATES" =~ ^(candidate|direct|notify)$ ]] || die "RS_SDK_UPDATES must be candidate, direct or notify"
[[ "$MAINTENANCE_DAY" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]] || die "MAINTENANCE_DAY must be one of Mon Tue Wed Thu Fri Sat Sun"
[[ "$COUNTDOWN_MINUTES" =~ ^[1-9][0-9]?$ ]] && (( COUNTDOWN_MINUTES <= 60 )) || die "COUNTDOWN_MINUTES must be 1-60"
for path in "$LOSTCITY_RUNTIME_DIR" "$RS_SDK_SOURCE_DIR" "$RS_SDK_DATA_DIR"; do
  [[ "$path" =~ ^/[[:alnum:]_./-]+$ && "$path" != *//* && "$path" != */./* && "$path" != */. \
     && "$path" != */../* && "$path" != */.. && "$path" != */ ]] \
    || die "unsupported path in a 2004Scape .env: $path"
done
[[ "$(dirname -- "$RS_SDK_DATA_DIR")" != / ]] || die "RS_SDK_DATA_DIR must not sit directly under /"
[[ "$LOSTCITY_REVISION" =~ ^[0-9][0-9a-z.-]*$ ]] || die "unsupported LOSTCITY_REVISION: $LOSTCITY_REVISION"

command -v flock >/dev/null || die "flock is required"
export GIT_TERMINAL_PROMPT=0
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/computer-setup/2004scape-maintenance"
install -d -m 700 "$STATE_DIR"
exec {LOCK_FD}>"$STATE_DIR/lock"
flock -n "$LOCK_FD" || { log "another maintenance run is in progress"; exit 0; }

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

# The game cannot write these .git dirs (read-only in its container); never run
# hooks, fsmonitor or ext:: transports from them all the same.
git_() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never "$@"; }
compose() {
  local stack="$1"
  shift
  docker compose --project-directory "$GAME_DIR/$stack" -f "$GAME_DIR/$stack/docker-compose.yml" "$@"
}
unit_show() { systemctl show "$1" -p "$2" --value; }
unit_busy() { [[ "$(unit_show "$1" ActiveState)" =~ ^(activating|active|deactivating|reloading)$ ]]; }
backup_busy() { unit_busy "$BACKUP_UNIT"; }
# When the unit's current or last run began (epoch). Fails when systemd no
# longer knows: a oneshot unit nothing else references (the restore check) is
# unloaded once it finishes, and then shows its timestamps empty. An empty
# value must never be parsed: `date -d ""` is midnight, not an error.
unit_started_at() {
  local stamp
  stamp="$(unit_show "$1" ExecMainStartTimestamp)" || return 1
  [[ -n "$stamp" && "$stamp" != n/a ]] || return 1
  date -d "$stamp" +%s
}
wait_backup() {
  for _ in $(seq 1 120); do
    backup_busy || return 0
    sleep 30
  done
  return 1
}
container_of() { case "$1" in lostcity) printf 'lostcity' ;; rs-sdk) printf 'rs-sdk-server' ;; esac; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }
image_of() { case "$1" in lostcity) printf '%s' "$LOSTCITY_IMAGE" ;; rs-sdk) printf '%s' "$RS_SDK_IMAGE" ;; esac; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

# The image each stack must (re)start on: the one its container ran before the
# countdown, or the one a verified update built. Compose starts whatever its
# tag points at, and a tag can drift (a manual build, a playtest image), so
# every start retags first. Kept in the state dir too, so the recovery of a
# crashed run still knows it.
declare -A DEPLOY=()
image_file() { printf '%s/%s.image' "$STATE_DIR" "$1"; }
save_image() {
  DEPLOY[$1]="$2"
  printf '%s\n' "$2" >"$(image_file "$1").tmp" && mv "$(image_file "$1").tmp" "$(image_file "$1")"
}
deploy_image() {
  local id="${DEPLOY[$1]:-}"
  if [[ -z "$id" && -r "$(image_file "$1")" ]]; then read -r id <"$(image_file "$1")" || id=""; fi
  printf '%s' "$id"
}
pin_image() {
  local stack="$1" tag want have
  tag="$(image_of "$stack")"
  want="$(deploy_image "$stack")"
  if [[ -z "$want" ]]; then
    log "warning: $stack: no record of the image it ran; starting $tag as it is"
    return 0
  fi
  # Never fall back to whatever the tag holds: that is how a stack comes back on old code.
  docker image inspect "$want" >/dev/null 2>&1 \
    || { log "error: $stack: the image it ran ($want) is gone; not starting it on $tag"; return 1; }
  have="$(image_id "$tag")" || have=""
  [[ "$have" != "$want" ]] || return 0
  log "$stack: $tag is ${have:-missing}, not the image the stack ran ($want); retagging it before the start"
  docker tag "$want" "$tag"
}
start_stack() { pin_image "$1" || return 1; compose "$1" up -d --no-build --force-recreate "$1" </dev/null; }

# Lost City serves the client committed in its engine (public/client), so the
# webclient checkout is not deployed and never needs an update.
repos_of() {
  case "$1" in
    lostcity) printf '%s\n' "$LOSTCITY_RUNTIME_DIR/engine" "$LOSTCITY_RUNTIME_DIR/content" ;;
    rs-sdk) printf '%s\n' "$RS_SDK_SOURCE_DIR" ;;
  esac
}
branch_of() {
  case "$1" in
    lostcity) printf '%s' "$LOSTCITY_REVISION" ;;
    rs-sdk) git_ -C "$RS_SDK_SOURCE_DIR" symbolic-ref --short -q HEAD ;;
  esac
}

wait_healthy() {
  local container="$1" status
  for _ in $(seq 1 $((HEALTH_TIMEOUT_SECONDS / 10))); do
    status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null)" || status=""
    [[ "$status" == "running healthy" ]] && return 0
    sleep 10
  done
  return 1
}

declare -A OLD=() NEW=() TARGET=() CHANGED=()
PROMOTE_IMAGE=""

# --- update and rollback ------------------------------------------------------
# These run from `if`, where set -e is off: every step checks its own status.

# Written before the first change to a stack and removed once it is updated or
# rolled back; one that survives makes the next run roll the stack back.
begin_change() {
  local stack="$1" repo
  {
    printf 'target %s\n' "${TARGET[$stack]}"
    while IFS= read -r repo; do
      [[ -z "${NEW[$repo]:-}" ]] || printf 'repo %s %s %s\n' "$repo" "${OLD[$repo]}" "${NEW[$repo]}"
    done < <(repos_of "$stack")
  } >"$STATE_DIR/$stack.inprogress.tmp" || return 1
  mv "$STATE_DIR/$stack.inprogress.tmp" "$STATE_DIR/$stack.inprogress" || return 1
  CHANGED[$stack]=true
}
load_change() {
  local stack="$1" kind rest repo old new
  CHANGED[$stack]=true
  while read -r kind rest; do
    case "$kind" in
      target) TARGET[$stack]="$rest"; [[ "$rest" != promote\ * ]] || PROMOTE_IMAGE="${rest#promote }" ;;
      repo) read -r repo old new <<<"$rest"; OLD[$repo]="$old"; NEW[$repo]="$new" ;;
    esac
  done <"$STATE_DIR/$stack.inprogress"
}

lostcity_snapshot="$LOSTCITY_RUNTIME_DIR.pre-update"
lostcity_rebuild() {
  pin_image lostcity || return 1
  docker rm -f lostcity-update >/dev/null 2>&1 || true
  local steps='cd engine && bun install && bun run build'
  [[ "$1" == migrate ]] && steps='cd engine && bun install && bun run sqlite:migrate && bun run build'
  compose lostcity run --rm --no-deps -T --name lostcity-update lostcity bash -c "$steps" </dev/null
}
update_lostcity() {
  local engine="$LOSTCITY_RUNTIME_DIR/engine" repo f
  rm -rf "$lostcity_snapshot" "$lostcity_snapshot.complete" || return 1
  install -d -m 700 "$lostcity_snapshot" || return 1
  for f in db.sqlite db.sqlite-journal db.sqlite-wal db.sqlite-shm; do
    if [[ -e "$engine/$f" ]]; then cp -a "$engine/$f" "$lostcity_snapshot/" || return 1; fi
  done
  if [[ -d "$engine/data/players" ]]; then cp -a "$engine/data/players" "$lostcity_snapshot/players" || return 1; fi
  touch "$lostcity_snapshot.complete" || return 1
  begin_change lostcity || return 1
  while IFS= read -r repo; do
    [[ -z "${NEW[$repo]:-}" ]] || git_ -C "$repo" merge --ff-only --quiet "${NEW[$repo]}" </dev/null || return 1
  done < <(repos_of lostcity)
  lostcity_rebuild migrate || return 1
  start_stack lostcity || return 1
  wait_healthy lostcity
}
rollback_lostcity() {
  local engine="$LOSTCITY_RUNTIME_DIR/engine" repo f
  compose lostcity stop -t 120 lostcity </dev/null || true
  while IFS= read -r repo; do
    [[ -z "${OLD[$repo]:-}" ]] || git_ -C "$repo" reset --hard --quiet "${OLD[$repo]}" </dev/null || return 1
  done < <(repos_of lostcity)
  [[ -e "$lostcity_snapshot.complete" ]] || return 1
  for f in db.sqlite db.sqlite-journal db.sqlite-wal db.sqlite-shm; do rm -f "$engine/$f" || return 1; done
  for f in db.sqlite db.sqlite-journal db.sqlite-wal db.sqlite-shm; do
    if [[ -e "$lostcity_snapshot/$f" ]]; then cp -a "$lostcity_snapshot/$f" "$engine/" || return 1; fi
  done
  # Saves written by the new code while it was up go too.
  rm -rf "$engine/data/players" || return 1
  if [[ -d "$lostcity_snapshot/players" ]]; then cp -a "$lostcity_snapshot/players" "$engine/data/players" || return 1; fi
  lostcity_rebuild no-migrate || return 1
  start_stack lostcity || return 1
  wait_healthy lostcity
}

# The RS-SDK data dir is root-owned (the upstream entrypoint runs as root), so
# its pre-update copy is made and restored by a root container from the image.
rs_sdk_data_op() {
  docker run --rm --network none --entrypoint sh \
    -e NAME="$(basename -- "$RS_SDK_DATA_DIR")" -v "$(dirname -- "$RS_SDK_DATA_DIR")":/parent \
    "$RS_SDK_ROLLBACK_IMAGE" -c "$1" </dev/null
}
update_rs_sdk() {
  local running_image built
  # The image the stack last ran, not whatever :local points at by now.
  running_image="$(deploy_image rs-sdk)"
  [[ -n "$running_image" ]] || running_image="$(docker inspect -f '{{.Image}}' rs-sdk-server)" || return 1
  docker tag "$running_image" "$RS_SDK_ROLLBACK_IMAGE" || return 1
  rs_sdk_data_op 'set -e; cd /parent; rm -rf "$NAME.pre-update" "$NAME.pre-update.complete"
    cp -a "$NAME" "$NAME.pre-update"; touch "$NAME.pre-update.complete"' || return 1
  begin_change rs-sdk || return 1
  if [[ -n "$PROMOTE_IMAGE" ]]; then
    # world.sh promote --next-window: the owner-tested candidate, no build.
    built="$PROMOTE_IMAGE"
    docker tag "$built" "$RS_SDK_IMAGE" || return 1
  else
    git_ -C "$RS_SDK_SOURCE_DIR" merge --ff-only --quiet "${NEW[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
    compose rs-sdk build rs-sdk </dev/null || return 1
    # Started on, but only recorded as deployed once it is healthy (see below).
    built="$(image_id "$RS_SDK_IMAGE")" || return 1
  fi
  DEPLOY[rs-sdk]="$built"
  start_stack rs-sdk || return 1
  wait_healthy rs-sdk-server
}
rollback_rs_sdk() {
  compose rs-sdk stop -t 120 rs-sdk </dev/null || true
  # A promotion changed no checkout.
  if [[ -n "${OLD[$RS_SDK_SOURCE_DIR]:-}" ]]; then
    git_ -C "$RS_SDK_SOURCE_DIR" reset --hard --quiet "${OLD[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
  fi
  # start_stack retags :local to it.
  DEPLOY[rs-sdk]="$(image_id "$RS_SDK_ROLLBACK_IMAGE")" || return 1
  rs_sdk_data_op 'set -e; cd /parent; [ -e "$NAME.pre-update.complete" ]
    find "$NAME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a "$NAME.pre-update/." "$NAME/"' || return 1
  start_stack rs-sdk || return 1
  wait_healthy rs-sdk-server
}

# Puts a failed or interrupted stack back up. One that failed before anything
# changed only needs a start.
recover() {
  local stack="$1"
  if [[ "${CHANGED[$stack]:-false}" != true ]]; then
    start_stack "$stack" && wait_healthy "$(container_of "$stack")"
    return
  fi
  "rollback_${stack//-/_}" || return 1
  rm -f "$STATE_DIR/$stack.inprogress"
}

resume_interrupted() {
  local stack found=false
  for stack in lostcity rs-sdk; do
    [[ -f "$STATE_DIR/$stack.inprogress" ]] || continue
    found=true
    wait_backup || die "$BACKUP_UNIT is still running; recovery deferred"
    load_change "$stack"
    printf '%s\n' "${TARGET[$stack]}" >"$STATE_DIR/$stack.failed"
    log "$stack: an update to ${TARGET[$stack]} was interrupted; rolling it back"
    if recover "$stack"; then
      log "$stack: rolled back and healthy"
      notify "2004Scape interrupted update rolled back" "$stack is back up on its previous code; ${TARGET[$stack]} is not retried until upstream moves." high
    else
      notify "2004Scape rollback FAILED, server DOWN" "$stack could not be rolled back from an interrupted update to ${TARGET[$stack]}. Check: docker ps -a; journalctl -u 2004scape-maintenance.service" urgent
      die "$stack: rollback of the interrupted update failed; the stack is down"
    fi
  done
  [[ "$found" == true ]] || log "no interrupted update to roll back"
}

if [[ "$MODE" == check ]]; then
  for stack in lostcity rs-sdk; do
    [[ ! -f "$STATE_DIR/$stack.inprogress" ]] || log "$stack: an interrupted update waits to be rolled back (--resume)"
  done
else
  resume_interrupted
  [[ "$MODE" != resume ]] || exit 0
fi

# --- what goes down, and what updates -------------------------------------------
# Records OLD/NEW for a repo that can fast-forward. Fails on anything that is
# not a clean fast-forward of the checked-out branch.
check_repo() {
  local repo="$1" branch="$2" current head upstream
  current="$(git_ -C "$repo" symbolic-ref --short -q HEAD)" \
    || { log "warning: cannot read the branch of $repo (not a checkout, or not owned by $(id -un))"; return 1; }
  [[ -n "$branch" && "$current" == "$branch" ]] \
    || { log "warning: $repo is on ${current:-<none>}, not ${branch:-<unknown>}"; return 1; }
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

declare -a DOWN=() UPDATE=()
for stack in lostcity rs-sdk; do
  container="$(container_of "$stack")"
  if ! is_running "$container"; then
    log "$stack: not running; left alone"
    continue
  fi
  DOWN+=("$stack")
  running_image="$(docker inspect -f '{{.Image}}' "$container")" || die "$stack: cannot read the image $container runs"
  if [[ "$MODE" == check ]]; then DEPLOY[$stack]="$running_image"; else save_image "$stack" "$running_image"; fi
  # An owner promotion (world.sh promote --next-window) replaces any upstream update.
  if [[ "$stack" == rs-sdk && -r "$STATE_DIR/rs-sdk.promote" ]]; then
    read -r promote <"$STATE_DIR/rs-sdk.promote" || promote=""
    if [[ "$promote" =~ ^sha256:[0-9a-f]{64}$ ]] && docker image inspect "$promote" >/dev/null 2>&1; then
      if [[ "$promote" == "$running_image" ]]; then
        log "rs-sdk: already runs the promoted image"
        [[ "$MODE" == check ]] || rm -f "$STATE_DIR/rs-sdk.promote"
      else
        PROMOTE_IMAGE="$promote"
        TARGET[$stack]="promote $promote"
        log "rs-sdk: owner promotion pending: $promote"
        UPDATE+=("$stack")
      fi
      continue
    fi
    log "warning: rs-sdk: the promotion marker names no local image ($promote); ignored"
    if [[ "$MODE" != check ]]; then
      notify "2004Scape promotion ignored" "rs-sdk.promote names $promote, which is not a local image. Promote again with world.sh promote." high
      rm -f "$STATE_DIR/rs-sdk.promote"
    fi
  fi
  branch="$(branch_of "$stack")" || branch=""
  mapfile -t repos < <(repos_of "$stack")
  usable=true
  for repo in "${repos[@]}"; do
    check_repo "$repo" "$branch" </dev/null || usable=false
  done
  if [[ "$usable" != true ]]; then
    log "$stack: not updated (see warnings above)"
    if [[ "$MODE" != check && ! -e "$STATE_DIR/$stack.skipped" ]]; then
      notify "2004Scape updates skipped" "$stack's checkouts cannot be fast-forwarded (local changes, another branch or diverged); it gets no updates until that is fixed. See: journalctl -u 2004scape-maintenance.service"
      touch "$STATE_DIR/$stack.skipped"
    fi
    continue
  fi
  rm -f "$STATE_DIR/$stack.skipped"
  target=""
  for repo in "${repos[@]}"; do
    [[ -n "${NEW[$repo]:-}" ]] && target+="${repo##*/}@${NEW[$repo]:0:12} "
  done
  target="${target% }"
  [[ -n "$target" ]] || { log "$stack: up to date"; continue; }
  TARGET[$stack]="$target"
  failed=""
  if [[ -r "$STATE_DIR/$stack.failed" ]]; then read -r failed <"$STATE_DIR/$stack.failed" || true; fi
  if [[ "$failed" == "$target" ]]; then
    log "$stack: the update to $target failed before; not retried until upstream moves (or $STATE_DIR/$stack.failed is removed)"
    continue
  fi
  log "$stack: update available ($target)"
  if [[ "$stack" == rs-sdk && "$RS_SDK_UPDATES" != direct ]]; then
    # Never world 1: build a candidate for the test world (world.sh) and say so.
    if [[ "$MODE" != check && "$RS_SDK_UPDATES" == candidate ]]; then
      bash "$SCRIPT_DIR/world.sh" candidate build --if-new </dev/null \
        || log "rs-sdk: candidate build failed (notified); neither world was touched"
    elif [[ "$MODE" != check ]]; then
      notified=""
      if [[ -r "$STATE_DIR/$stack.notified" ]]; then read -r notified <"$STATE_DIR/$stack.notified" || true; fi
      if [[ "$notified" != "$target" ]]; then
        notify "2004Scape update available" "$stack: $target. RS_SDK_UPDATES=notify, so no candidate is built."
        printf '%s\n' "$target" >"$STATE_DIR/$stack.notified"
      fi
    fi
    continue
  fi
  if [[ "$AUTO_UPDATE" != true ]]; then
    notified=""
    if [[ -r "$STATE_DIR/$stack.notified" ]]; then read -r notified <"$STATE_DIR/$stack.notified" || true; fi
    if [[ "$MODE" != check && "$notified" != "$target" ]]; then
      notify "2004Scape update available" "$stack: $target. AUTO_UPDATE is off, so it is not applied."
      printf '%s\n' "$target" >"$STATE_DIR/$stack.notified"
    fi
    continue
  fi
  UPDATE+=("$stack")
done

# A tag that no longer names the running image is restarted from nowhere: the
# start retags it (pin_image), but say so loudly, once per drift.
for stack in ${DOWN[@]+"${DOWN[@]}"}; do
  tag="$(image_of "$stack")"
  have="$(image_id "$tag")" || have=""
  if [[ "$have" == "${DEPLOY[$stack]}" ]]; then
    [[ "$MODE" == check ]] || rm -f "$STATE_DIR/$stack.drift"
    continue
  fi
  if [[ " ${UPDATE[*]} " == *" $stack "* ]]; then
    plan="the update builds a new $tag; a failed update goes back to the running image"
  else
    plan="maintenance restarts it on the running image and points $tag back at it"
  fi
  log "WARNING: $stack: $tag is ${have:-missing} but $(container_of "$stack") runs ${DEPLOY[$stack]}; $plan"
  drift="$tag ${have:-missing} ${DEPLOY[$stack]}"
  noted=""
  if [[ -r "$STATE_DIR/$stack.drift" ]]; then read -r noted <"$STATE_DIR/$stack.drift" || true; fi
  if [[ "$MODE" != check && "$noted" != "$drift" ]]; then
    notify "2004Scape image drift" "$stack: $tag is ${have:-missing}, not the image $(container_of "$stack") runs (${DEPLOY[$stack]}); $plan. Check: docker image inspect -f '{{.Id}}' $tag" high
    printf '%s\n' "$drift" >"$STATE_DIR/$stack.drift"
  fi
done
[[ "$MODE" != check ]] || exit 0
[[ ${#DOWN[@]} -gt 0 ]] || { log "no running stack; nothing to do"; exit 0; }

# --- preflight: nobody is disconnected unless the backup can run and verify ----
# PHASE drives the exit trap: what an interrupted run must put back.
PHASE=preflight
declare -A STARTED=()
declare -a HELPER_PIDS=()
restore_after_abort() {
  local rc=$? stack container priority=high left=""
  [[ "$PHASE" != finished ]] || return 0
  for pid in ${HELPER_PIDS[@]+"${HELPER_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if [[ "$PHASE" != preflight ]]; then
    if ! wait_backup; then
      notify "2004Scape recovery deferred" "$BACKUP_UNIT is still running. Leave games stopped until it finishes, then recover with --resume and start unchanged stacks." urgent
      return "$rc"
    fi
    for stack in "${DOWN[@]}"; do
      [[ -z "${STARTED[$stack]:-}" ]] || continue
      container="$(container_of "$stack")"
      if [[ "${CHANGED[$stack]:-false}" == true ]]; then
        priority=urgent
        left+=" $stack is DOWN mid-update; roll it back now with: bash linux-game-server/2004scape/maintenance.sh --resume."
      elif is_running "$container"; then
        # A countdown that reached the engine still fires; with the restart
        # policy back, the stack comes straight back on its current code.
        docker update --restart=unless-stopped "$container" >/dev/null 2>&1 || true
      else
        start_stack "$stack" >/dev/null 2>&1 || true
      fi
    done
  fi
  notify "2004Scape maintenance aborted" "Stopped during the $PHASE phase (exit $rc).$left Check: docker ps -a; journalctl -u 2004scape-maintenance.service" "$priority"
}
trap restore_after_abort EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP

now="$(date +%s)"
if [[ "$MODE" == scheduled ]]; then
  next="$(systemctl show "$BACKUP_TIMER" -p NextElapseUSecRealtime --value)"
  next_epoch="$(date -d "$next" +%s 2>/dev/null)" || die "cannot read when $BACKUP_TIMER runs next ('$next')"
  if [[ "$(LC_ALL=C date -d "@$next_epoch" +%a)" != "$MAINTENANCE_DAY" ]]; then
    log "the next backup is not on $MAINTENANCE_DAY; nothing to do"
    PHASE=finished
    exit 0
  fi
fi

[[ "$(unit_show "$BACKUP_UNIT" LoadState)" == loaded ]] || die "$BACKUP_UNIT is not installed"
[[ "$(unit_show "$VERIFY_UNIT" LoadState)" == loaded ]] \
  || die "$VERIFY_UNIT is not installed; rerun sudo bash linux-game-server/backup/setup.sh"
env_line=" $(unit_show "$BACKUP_UNIT" Environment) "
verify_command=" $(unit_show "$VERIFY_UNIT" ExecStart) "
for stack in "${DOWN[@]}"; do
  case "$stack" in
    lostcity)
      for state in server.json engine/data/players; do
        [[ "$verify_command" == *" --compare-live $LOSTCITY_RUNTIME_DIR/$state "* ]] \
          || die "$VERIFY_UNIT does not compare lostcity's $state; rerun sudo bash linux-game-server/backup/setup.sh"
      done
      [[ "$verify_command" == *" --compare-lostcity-config $LOSTCITY_RUNTIME_DIR "* ]] \
        || die "$VERIFY_UNIT does not compare lostcity's configuration; rerun sudo bash linux-game-server/backup/setup.sh"
      [[ -f "$LOSTCITY_RUNTIME_DIR/engine/.env" || -f "$LOSTCITY_RUNTIME_DIR/engine/data/config/world.json" ]] \
        || die "lostcity has neither .env nor world.json configuration"
      [[ "$verify_command" == *" --compare-sqlite $LOSTCITY_RUNTIME_DIR/engine/db.sqlite lostcity/db.sqlite.sqlitebak "* ]] ;;
    rs-sdk) [[ "$verify_command" == *" --compare-live $RS_SDK_DATA_DIR "* ]] ;;
  esac || die "$VERIFY_UNIT does not compare $stack's stopped data; rerun sudo bash linux-game-server/backup/setup.sh"
  case "$stack" in
    lostcity) [[ "$env_line" == *" BACKUP_LOSTCITY_RUNTIME_DIR=$LOSTCITY_RUNTIME_DIR "* ]] ;;
    rs-sdk) [[ "$env_line" == *" BACKUP_RS_SDK_DATA_DIR=$RS_SDK_DATA_DIR "* ]] ;;
  esac || die "$BACKUP_UNIT does not cover $stack; rerun sudo bash linux-game-server/backup/setup.sh"
done
# A backup still running is waited for, never interrupted.
wait_backup || die "$BACKUP_UNIT is still running; games left alone"
# A failure that would only repeat must not cost players a countdown every night.
[[ "$(unit_show "$BACKUP_UNIT" Result)" == success ]] \
  || die "the last $BACKUP_UNIT run failed; the games stay up until a backup succeeds again"
[[ "$(unit_show "$VERIFY_UNIT" Result)" == success ]] \
  || die "the last $VERIFY_UNIT run failed; once it is understood, clear it with: sudo systemctl reset-failed $VERIFY_UNIT"

countdown_seconds=$((COUNTDOWN_MINUTES * 60))
now="$(date +%s)"
if [[ "$MODE" == scheduled ]]; then
  deadline=$((next_epoch - DOWN_BEFORE_BACKUP_SECONDS))
  (( deadline - now <= 6 * 3600 )) \
    || die "the next backup ($next) is more than 6 h away; the maintenance timer must fire shortly before it"
  (( deadline - now >= countdown_seconds + 30 )) \
    || die "the next backup ($next) is too close for a $COUNTDOWN_MINUTES-minute countdown"
  log "games go down at $(date -d "@$deadline" '+%T %Z'), before the $BACKUP_TIMER run at $next"
  sleep $((deadline - countdown_seconds - now))
else
  deadline=$((now + countdown_seconds))
fi

# --- countdown and graceful shutdown ----------------------------------------------
wait_backup || die "$BACKUP_UNIT is still running; games left alone"
PHASE=countdown
started="$(date +%s)"
# Extra RS-SDK worlds (world.sh) use world 1's login server, so they log their
# players out a minute before it goes; each counts down on its own node only.
declare -a EXTRA_WORLDS=() EXTRA_PIDS=()
if [[ " ${DOWN[*]} " == *" rs-sdk "* ]]; then
  mapfile -t EXTRA_WORLDS < <(docker ps --filter label=computer-setup.rs-sdk.world --format '{{.Label "computer-setup.rs-sdk.world"}}')
fi
for world in ${EXTRA_WORLDS[@]+"${EXTRA_WORLDS[@]}"}; do
  lead=$(( deadline - 60 - $(date +%s) ))
  (( lead >= 15 )) || lead=15
  bash "$SCRIPT_DIR/world.sh" down "$world" --countdown "$lead" \
    >"$STATE_DIR/world-$world.down.log" 2>&1 </dev/null &
  EXTRA_PIDS+=("$!")
  HELPER_PIDS+=("$!")
done
helper="$(<"$SCRIPT_DIR/countdown.js")"
for stack in "${DOWN[@]}"; do
  container="$(container_of "$stack")"
  docker update --restart=no "$container" >/dev/null
  extra=()
  # Lost City's tick is a fixed 600 ms; RS-SDK reads NODE_TICKRATE from its env.
  [[ "$stack" == lostcity ]] && extra+=(-e COUNTDOWN_TICK_MS=600)
  [[ " ${UPDATE[*]} " == *" $stack "* ]] && extra+=(-e COUNTDOWN_WITH_UPDATE=1)
  docker exec -e COUNTDOWN_DEADLINE_MS="$((deadline * 1000))" "${extra[@]}" "$container" bun -e "$helper" \
    >"$STATE_DIR/$stack.countdown.log" 2>&1 </dev/null &
  HELPER_PIDS+=("$!")
done
for stack in "${DOWN[@]}"; do
  announced=false
  for _ in $(seq 1 30); do
    if grep -qx announced "$STATE_DIR/$stack.countdown.log"; then announced=true; break; fi
    sleep 1
  done
  [[ "$announced" == true ]] \
    || die "$stack: could not announce the countdown: $(tr '\n' ' ' <"$STATE_DIR/$stack.countdown.log")"
done
log "countdown announced for ${DOWN[*]}; going down at $(date -d "@$deadline" '+%T %Z')${UPDATE[*]:+, then updating ${UPDATE[*]}}"

now="$(date +%s)"
(( deadline > now )) && sleep "$((deadline - now))"
for stack in "${DOWN[@]}"; do
  container="$(container_of "$stack")"
  for _ in $(seq 1 "$STOP_GRACE_SECONDS"); do
    is_running "$container" || break
    sleep 1
  done
  # Not forced: that would take players down with no warning.
  ! is_running "$container" \
    || die "$stack: did not shut down on its countdown (the engine never got it); left running"
done
for pid in ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"}; do
  wait "$pid" 2>/dev/null || log "warning: an extra world did not go down cleanly; see $STATE_DIR/world-*.down.log"
done
PHASE=stopped
for pid in "${HELPER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
HELPER_PIDS=()
for stack in "${DOWN[@]}"; do
  container="$(container_of "$stack")"
  state="$(docker inspect -f '{{.State.Running}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$container")"
  logs="$(docker logs --since "$started" "$container" 2>&1)"
  [[ "$state" == "false 0 false" ]] && grep -q 'Server shutdown complete' <<<"$logs" \
    || die "$stack: did not shut down cleanly ($state); not backing up or updating"
done
stopped_at="$(date +%s)"

# --- backup and verification of the stopped data ----------------------------------
# Starts, or joins, a run of the unit that began after the games were down and
# waits for its result. A run in progress that began before (a late shutdown)
# does not count: it is waited out, then the unit runs again. A unit found idle
# is simply started: any run from then on began after the stop. Its start time
# is only trusted while systemd still reports it; the restore check is unloaded
# as soon as it finishes, and reading its empty timestamp as midnight once made
# a passed check run twice and then count as failed.
run_after_stop() {
  local unit="$1" began starts=0
  for _ in $(seq 1 720); do
    if unit_busy "$unit"; then
      began="$(unit_started_at "$unit")" || began=0
      if (( began < stopped_at )); then sleep 5; continue; fi
    fi
    (( starts++ < 2 )) || return 1
    systemctl --no-ask-password start --wait "$unit" || return 1
    began="$(unit_started_at "$unit")" || return 0
    (( began < stopped_at )) || return 0
  done
  return 1
}
if [[ "$MODE" == scheduled ]]; then
  now="$(date +%s)"
  (( next_epoch > now )) && sleep "$((next_epoch - now + 5))"
fi
log "backing up the stopped games"
began="$(unit_started_at "$BACKUP_UNIT" 2>/dev/null)" || began=0
if (( began < stopped_at )); then
  run_after_stop "$BACKUP_UNIT" || die "$BACKUP_UNIT failed; games restarted on their current code, not updated"
fi
wait_backup || die "$BACKUP_UNIT is still running; games remain stopped"
[[ "$(unit_show "$BACKUP_UNIT" Result)" == success ]] || die "$BACKUP_UNIT failed; not updating"
log "verifying the backup restores identical to the stopped data"
run_after_stop "$VERIFY_UNIT" || die "$VERIFY_UNIT failed; games restarted on their current code, not updated"

# --- everything back up, updates last ---------------------------------------------------
PHASE=updating
failures=0
for stack in "${DOWN[@]}"; do
  [[ " ${UPDATE[*]} " != *" $stack "* ]] || continue
  container="$(container_of "$stack")"
  if start_stack "$stack" && wait_healthy "$container"; then
    log "$stack: back up"
  else
    failures=$((failures + 1))
    notify "2004Scape did not come back" "$stack is not healthy after its restart. Check: docker ps -a; docker logs $container" high
  fi
  STARTED[$stack]=1
done
for stack in ${UPDATE[@]+"${UPDATE[@]}"}; do
  log "$stack: updating to ${TARGET[$stack]}"
  if "update_${stack//-/_}"; then
    deployed="$(deploy_image "$stack")"
    [[ -z "$deployed" ]] || save_image "$stack" "$deployed"
    rm -f "$STATE_DIR/$stack.inprogress" "$STATE_DIR/$stack.failed" "$STATE_DIR/$stack.notified"
    [[ "$stack" != rs-sdk || -z "$PROMOTE_IMAGE" ]] || rm -f "$STATE_DIR/rs-sdk.promote"
    log "$stack: updated and healthy"
    notify "2004Scape updated" "$stack is back up on ${TARGET[$stack]}." low
  else
    failures=$((failures + 1))
    printf '%s\n' "${TARGET[$stack]}" >"$STATE_DIR/$stack.failed"
    # A failed promotion is not retried every week; the owner promotes again.
    [[ "$stack" != rs-sdk || -z "$PROMOTE_IMAGE" ]] || rm -f "$STATE_DIR/rs-sdk.promote"
    log "$stack: update failed; putting it back"
    if recover "$stack"; then
      log "$stack: back up on its previous code"
      notify "2004Scape update FAILED" "$stack could not update to ${TARGET[$stack]} and is back up on its previous code. Not retried until upstream moves." high
    else
      log "$stack: could not be put back; the stack is down"
      notify "2004Scape update FAILED, server DOWN" "$stack failed to update to ${TARGET[$stack]} and the rollback failed; the next run retries it. Its pre-update copy is next to its data, and the backup verified just before has it too. Check: docker ps -a; journalctl -u 2004scape-maintenance.service" urgent
    fi
  fi
  STARTED[$stack]=1
done
# Live extra worlds come back on world 1's (possibly new) image; test worlds stay
# down until the owner needs them again.
for world in ${EXTRA_WORLDS[@]+"${EXTRA_WORLDS[@]}"}; do
  role="$(python3 "$GAME_DIR/rs-sdk/worlds/worlds.py" row "$world" | awk '{print $3}')" || role=""
  if [[ "$role" == live ]]; then
    bash "$SCRIPT_DIR/world.sh" up "$world" </dev/null >>"$STATE_DIR/world-$world.down.log" 2>&1 \
      || notify "2004Scape world $world did not come back" "Live world $world failed to start after maintenance. Check: world.sh status" high
  else
    log "test world $world stays down after maintenance (world.sh test up to bring it back)"
  fi
done
PHASE=finished
log "maintenance done: backup verified${UPDATE[*]:+; updates attempted for ${UPDATE[*]}}"
(( failures == 0 )) && notify "2004Scape maintenance done" "${DOWN[*]} restarted after a verified backup${UPDATE[*]:+; updated ${UPDATE[*]}}." low
exit $(( failures > 0 ))
