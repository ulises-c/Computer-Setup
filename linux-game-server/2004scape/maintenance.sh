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
: "${MAINTENANCE_DAY:=Mon}"
: "${COUNTDOWN_MINUTES:=10}"
: "${NTFY_URL:=}"
: "${NTFY_TOPIC:=}"
: "${NTFY_TOKEN:=}"
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
backup_busy() { [[ "$(unit_show "$BACKUP_UNIT" ActiveState)" =~ ^(activating|active|deactivating|reloading)$ ]]; }
wait_backup() {
  for _ in $(seq 1 120); do
    backup_busy || return 0
    sleep 30
  done
  return 1
}
container_of() { case "$1" in lostcity) printf 'lostcity' ;; rs-sdk) printf 'rs-sdk-server' ;; esac; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }
start_stack() { compose "$1" up -d --no-build --force-recreate "$1" </dev/null; }

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
      target) TARGET[$stack]="$rest" ;;
      repo) read -r repo old new <<<"$rest"; OLD[$repo]="$old"; NEW[$repo]="$new" ;;
    esac
  done <"$STATE_DIR/$stack.inprogress"
}

lostcity_snapshot="$LOSTCITY_RUNTIME_DIR.pre-update"
lostcity_rebuild() {
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
  local running_image
  # The image the stack last ran, not whatever :local points at by now.
  running_image="$(docker inspect -f '{{.Image}}' rs-sdk-server)" || return 1
  docker tag "$running_image" "$RS_SDK_ROLLBACK_IMAGE" || return 1
  rs_sdk_data_op 'set -e; cd /parent; rm -rf "$NAME.pre-update" "$NAME.pre-update.complete"
    cp -a "$NAME" "$NAME.pre-update"; touch "$NAME.pre-update.complete"' || return 1
  begin_change rs-sdk || return 1
  git_ -C "$RS_SDK_SOURCE_DIR" merge --ff-only --quiet "${NEW[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
  compose rs-sdk build rs-sdk </dev/null || return 1
  start_stack rs-sdk || return 1
  wait_healthy rs-sdk-server
}
rollback_rs_sdk() {
  compose rs-sdk stop -t 120 rs-sdk </dev/null || true
  git_ -C "$RS_SDK_SOURCE_DIR" reset --hard --quiet "${OLD[$RS_SDK_SOURCE_DIR]}" </dev/null || return 1
  docker image inspect "$RS_SDK_ROLLBACK_IMAGE" >/dev/null || return 1
  docker tag "$RS_SDK_ROLLBACK_IMAGE" "$RS_SDK_IMAGE" || return 1
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
# Starts, or joins, a run of the unit and waits for its result; a run that began
# before the games were down (a late shutdown) does not count, so it runs again.
run_after_stop() {
  local unit="$1" began
  for _ in 1 2; do
    systemctl --no-ask-password start --wait "$unit" || return 1
    began="$(date -d "$(unit_show "$unit" ExecMainStartTimestamp)" +%s)" || return 1
    (( began >= stopped_at )) && return 0
  done
  return 1
}
if [[ "$MODE" == scheduled ]]; then
  now="$(date +%s)"
  (( next_epoch > now )) && sleep "$((next_epoch - now + 5))"
fi
log "backing up the stopped games"
began="$(date -d "$(unit_show "$BACKUP_UNIT" ExecMainStartTimestamp)" +%s 2>/dev/null)" || began=0
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
    rm -f "$STATE_DIR/$stack.inprogress" "$STATE_DIR/$stack.failed" "$STATE_DIR/$stack.notified"
    log "$stack: updated and healthy"
    notify "2004Scape updated" "$stack is back up on ${TARGET[$stack]}." low
  else
    failures=$((failures + 1))
    printf '%s\n' "${TARGET[$stack]}" >"$STATE_DIR/$stack.failed"
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
PHASE=finished
log "maintenance done: backup verified${UPDATE[*]:+; updates attempted for ${UPDATE[*]}}"
(( failures == 0 )) && notify "2004Scape maintenance done" "${DOWN[*]} restarted after a verified backup${UPDATE[*]:+; updated ${UPDATE[*]}}." low
exit $(( failures > 0 ))
