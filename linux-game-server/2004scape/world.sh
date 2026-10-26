#!/usr/bin/env bash
set -euo pipefail

# RS-SDK worlds: one set of accounts, several engines (see rs-sdk/README.md
# "Worlds"). World 1 is the main stack; extra worlds are listed in
# rs-sdk/worlds/worlds.conf and run as rs-sdk-world-<id> containers.
#
#   world.sh status [--json]               every world: role, state, image, players
#   world.sh up ID [IMAGE] [--allow-content-change]
#   world.sh down ID [--countdown SECONDS] logs everyone out (countdown on that world only)
#   world.sh test up [IMAGE] [...]         the test world (100) on IMAGE, default: latest candidate
#   world.sh test down
#   world.sh role ID live|test             switch a world's role (restarts it if it runs)
#   world.sh allow ID list|add|remove NAME the world's login allowlist (test role)
#   world.sh compat IMAGE                  would IMAGE share saves safely with world 1?
#   world.sh candidate build [--if-new] [--source-ref COMMIT]
#                                          build upstream (or COMMIT, e.g. world 1's own source,
#                                          without fetching) + this repo's patches, never deploy
#   world.sh candidate list
#   world.sh promote [IMAGE] --next-window|--now [--yes] [--fix-hiscores | --pre-start CMD]
#                                          put IMAGE (default: the test world's) on world 1;
#                                          --now runs the hook while the engine is stopped
#
# A live world runs exactly world 1's image and is open to everyone; a test world
# runs a candidate with its allowlist on and is never a hop target. Nothing here
# restarts world 1 except `promote --now` (2-minute in-game countdown).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
GAME_DIR="$(dirname -- "$SCRIPT_DIR")"
WORLDS_DIR="$GAME_DIR/rs-sdk/worlds"
readonly TEST_WORLD=100
readonly MAIN_CONTAINER=rs-sdk-server
readonly RS_SDK_IMAGE=computer-setup/rs-sdk:local
readonly RS_SDK_ROLLBACK_IMAGE=computer-setup/rs-sdk:rollback
readonly CANDIDATE_REPO=computer-setup/rs-sdk
: "${WORLD_COUNTDOWN_SECONDS:=120}"
: "${WORLD_HEALTH_TIMEOUT:=600}"
: "${HISCORE_FIX_IMAGE:=python:3.14-alpine}"

log() { printf '%s %s\n' "$(date '+%F %T %Z')" "$*"; }
die() { log "error: $*" >&2; exit 1; }

for env_file in "$SCRIPT_DIR/.env" "$GAME_DIR/rs-sdk/.env"; do
  [[ -f "$env_file" ]] || die "missing $env_file; run linux-game-server/2004scape/setup.sh first"
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
done
: "${RS_SDK_SOURCE_DIR:?}" "${RS_SDK_DATA_DIR:?}"
: "${NTFY_URL:=}" "${NTFY_TOPIC:=}" "${NTFY_TOKEN:=}"
export RS_SDK_DATA_DIR

STATE_DIR="${WORLDS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/computer-setup/rs-sdk-worlds}"
MAINT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/computer-setup/2004scape-maintenance"
export WORLDS_STATE_DIR="$STATE_DIR"
install -d -m 700 "$STATE_DIR"

notify() {
  local title="$1" body="$2" priority="${3:-default}"
  [[ -n "$NTFY_URL" && -n "$NTFY_TOPIC" ]] || return 0
  local -a auth=()
  [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 15 ${auth[@]+"${auth[@]}"} \
    -H "Title: $title" -H "Priority: $priority" -H "Tags: video_game" \
    -d "$body" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 \
    || log "warning: ntfy notification failed"
}

worlds() { python3 "$WORLDS_DIR/worlds.py" "$@"; }
git_() { git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c protocol.ext.allow=never "$@"; }
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]; }
container_of() { if [[ "$1" == 1 ]]; then printf '%s' "$MAIN_CONTAINER"; else printf 'rs-sdk-world-%s' "$1"; fi; }
listening() { ss -ltnH | awk '{print $4}' | grep -Eq "[:.]$1\$"; }

# Row fields: id node role web management game gateway gateway_public https_web https_gateway
read_row() {
  local row
  row="$(worlds row "$1")" || die "world $1 is not configured in $WORLDS_DIR/worlds.conf"
  read -r W_ID W_NODE W_ROLE W_WEB W_MGMT W_GAME W_GW W_GWPUB W_HTTPS_WEB W_HTTPS_GW <<<"$row"
  export W_ID W_NODE W_ROLE W_WEB W_MGMT W_GAME W_GW W_GWPUB W_HTTPS_WEB W_HTTPS_GW
}

world_compose() {
  local id="$1"
  shift
  docker compose -p "rs-sdk-world-$id" --project-directory "$WORLDS_DIR" -f "$WORLDS_DIR/world-compose.yml" "$@"
}

players_on() {
  curl -fsS -m 3 "http://127.0.0.1:$1/playercount" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count", 0))' 2>/dev/null || printf 'unknown'
}

wait_healthy() {
  local container="$1" status
  for _ in $(seq 1 $((WORLD_HEALTH_TIMEOUT / 5))); do
    status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null)" || status=""
    [[ "$status" == "running healthy" ]] && return 0
    [[ "$status" == running* ]] || return 1
    sleep 5
  done
  return 1
}

# world-compat.js fingerprint of an image, cached by image id.
fingerprint() {
  local id="$1" out="$STATE_DIR/compat/${1#sha256:}.json"
  install -d -m 700 "$STATE_DIR/compat"
  if [[ ! -s "$out" ]]; then
    docker run --rm --network none --entrypoint bun "$id" -e "$(<"$WORLDS_DIR/world-compat.js")" >"$out.tmp" </dev/null \
      || { rm -f "$out.tmp"; return 1; }
    mv "$out.tmp" "$out"
  fi
  printf '%s' "$out"
}

main_image() {
  docker inspect -f '{{.Image}}' "$MAIN_CONTAINER" 2>/dev/null \
    || { [[ -r "$MAINT_STATE_DIR/rs-sdk.image" ]] && cat "$MAINT_STATE_DIR/rs-sdk.image"; } \
    || return 1
}

# Refuses (non-zero) when IMAGE would level, save or migrate differently from world 1.
check_compat() {
  local image="$1" base cand
  shift
  base="$(main_image)" || { log "cannot tell which image world 1 runs"; return 1; }
  base="$(fingerprint "$base")" || { log "cannot fingerprint world 1's image"; return 1; }
  cand="$(fingerprint "$image")" || { log "cannot fingerprint $image"; return 1; }
  worlds compat "$base" "$cand" "$@"
}

latest_candidate() {
  [[ -r "$STATE_DIR/candidates.tsv" ]] || return 1
  awk -F'\t' '$6 == "ok" {line=$0} END {if (line) {split(line, f, "\t"); print f[1]} else exit 1}' "$STATE_DIR/candidates.tsv"
}

ensure_serve() {
  local https="$1" port="$2"
  if tailscale serve status --json 2>/dev/null | python3 -c '
import json, sys
port = sys.argv[1]
data = json.load(sys.stdin) or {}
sys.exit(0 if any(k.endswith(":" + port) for k in (data.get("Web") or {})) else 1)' "$https"; then
    return 0
  fi
  if tailscale serve --bg --https="$https" "http://127.0.0.1:$port" >/dev/null; then
    log "tailnet https :$https -> 127.0.0.1:$port"
  else
    log "warning: could not add tailscale serve :$https (add it with linux-game-server/serve.sh)"
  fi
}

# --- up / down --------------------------------------------------------------------
cmd_up() {
  local id="$1" image="" allow=() id_img
  shift
  while (($#)); do
    case "$1" in
      --allow-content-change) allow+=(--allow-content-change) ;;
      -*) die "unknown option $1" ;;
      *) image="$1" ;;
    esac
    shift
  done
  read_row "$id"
  [[ "$id" != 1 ]] || die "world 1 is the main stack: it is started by maintenance.sh / compose, and changed only by promote"
  local container
  container="$(container_of "$id")"
  ! is_running "$container" || die "world $id is already running ($container); world.sh down $id first"
  if [[ "$W_ROLE" == live ]]; then
    local main
    main="$(main_image)" || die "cannot tell which image world 1 runs"
    [[ -z "$image" || "$(image_id "$image")" == "$main" ]] \
      || die "world $id is live: it runs world 1's image ($main), not $image (use role test for a candidate)"
    image="$main"
  elif [[ -z "$image" ]]; then
    image="$(latest_candidate)" || die "no candidate built yet: world.sh candidate build, or name an image"
  fi
  id_img="$(image_id "$image")" || die "no such image: $image"
  log "world $id ($W_ROLE): checking $image against world 1"
  check_compat "$id_img" ${allow[@]+"${allow[@]}"} || die "world $id not started: $image does not share saves safely with world 1"
  listening 43510 || die "world 1's login server (43510) is not listening; world $id needs it"
  local port
  for port in "$W_WEB" "$W_MGMT" "$W_GAME" "$W_GW" "$W_GWPUB"; do
    ! listening "$port" || die "port $port is taken; world $id cannot start"
  done
  if [[ "$W_ROLE" == test ]] && [[ "$(worlds allow "$id" list)" == "(empty"* ]]; then
    log "warning: world $id's allowlist is empty: nobody can log in (world.sh allow $id add NAME)"
  fi
  # The engine runs as root without CAP_DAC_OVERRIDE, so its state dir must be
  # writable for others; the state dir above it is 700, so no other user reaches it.
  install -d -m 700 "$STATE_DIR"
  install -d "$STATE_DIR/$id" "$STATE_DIR/$id/save-backups"
  chmod 777 "$STATE_DIR/$id" "$STATE_DIR/$id/save-backups"
  printf '%s\n' "$id_img" >"$STATE_DIR/$id.image"
  local line
  while IFS= read -r line; do export "${line?}"; done < <(worlds env "$id")
  export WORLD_IMAGE="$id_img"
  log "world $id: starting $container on $image"
  world_compose "$id" up -d --no-build --force-recreate </dev/null
  wait_healthy "$container" || die "world $id did not become healthy; see: docker logs $container"
  ensure_serve "$W_HTTPS_WEB" "$W_WEB"
  ensure_serve "$W_HTTPS_GW" "$W_GWPUB"
  log "world $id is up ($W_ROLE): web 127.0.0.1:$W_WEB (tailnet :$W_HTTPS_WEB), gateway :$W_GWPUB (tailnet :$W_HTTPS_GW), node $W_NODE"
}

cmd_down() {
  local id="$1" countdown=""
  shift
  while (($#)); do
    case "$1" in
      --countdown) countdown="${2:?}"; shift ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done
  read_row "$id"
  [[ "$id" != 1 ]] || die "world 1 goes down only through maintenance.sh or promote"
  local container players
  container="$(container_of "$id")"
  if is_running "$container"; then
    players="$(players_on "$W_WEB")"
    docker update --restart=no "$container" >/dev/null
    if [[ -n "$countdown" || "$players" != 0 ]]; then
      countdown="${countdown:-$WORLD_COUNTDOWN_SECONDS}"
      local deadline=$(( $(date +%s) + countdown ))
      printf '%s\n' "$deadline" >"$STATE_DIR/$id.countdown"
      log "world $id: $players player(s) on it; ${countdown}s in-game countdown on world $id only"
      # The friend server relays the countdown to this node id alone.
      docker exec -e COUNTDOWN_DEADLINE_MS="$((deadline * 1000))" -e COUNTDOWN_TICK_MS=600 \
        -e COUNTDOWN_REASON="a world $id shutdown" "$container" bun -e "$(<"$SCRIPT_DIR/countdown.js")" \
        >"$STATE_DIR/$id.countdown.log" 2>&1 </dev/null &
      local helper=$!
      for _ in $(seq 1 30); do grep -qx announced "$STATE_DIR/$id.countdown.log" && break; sleep 1; done
      grep -qx announced "$STATE_DIR/$id.countdown.log" \
        || { kill "$helper" 2>/dev/null || true; rm -f "$STATE_DIR/$id.countdown"
             die "world $id: countdown not announced: $(tr '\n' ' ' <"$STATE_DIR/$id.countdown.log")"; }
      for _ in $(seq 1 $((countdown + 180))); do is_running "$container" || break; sleep 1; done
      kill "$helper" 2>/dev/null || true
      wait "$helper" 2>/dev/null || true
      is_running "$container" && log "warning: world $id still up after its countdown; stopping it (the engine saves on SIGTERM)"
    else
      log "world $id: nobody on it; stopping (the engine logs out and saves on SIGTERM)"
    fi
    is_running "$container" && docker stop -t 120 "$container" >/dev/null
    log "world $id: engine stopped: $(docker logs --tail 200 "$container" 2>&1 | grep -c 'Server shutdown complete' || true) clean-shutdown line(s)"
  else
    log "world $id is not running"
  fi
  rm -f "$STATE_DIR/$id.countdown"
  if docker inspect "$container" >/dev/null 2>&1; then
    local line
    while IFS= read -r line; do export "${line?}"; done < <(worlds env "$id")
    WORLD_IMAGE="$(docker inspect -f '{{.Image}}' "$container")"
    export WORLD_IMAGE
    world_compose "$id" down </dev/null
  fi
  local left
  left="$(worlds logged-in "$W_NODE")" || die "cannot read the login table"
  if [[ "$left" != 0 ]]; then
    log "world $id: the login server still shows $left account(s) on node $W_NODE; releasing them"
    docker run --rm --network host -e RELEASE_NODE_ID="$W_NODE" -e LOGIN_PORT=43510 --entrypoint bun \
      "$(main_image)" -e "$(<"$WORLDS_DIR/login-release.js")" </dev/null
    sleep 1
    left="$(worlds logged-in "$W_NODE")"
    [[ "$left" == 0 ]] || die "world $id: $left account(s) still recorded on node $W_NODE"
  fi
  log "world $id is down; no account is recorded on node $W_NODE"
}

cmd_role() {
  local id="$1" role="$2" container
  [[ "$role" == live || "$role" == test ]] || die "role must be live or test"
  [[ "$id" != 1 ]] || die "world 1 is always live"
  read_row "$id"
  container="$(container_of "$id")"
  if is_running "$container"; then
    log "world $id runs as $W_ROLE; switching to $role restarts it"
    cmd_down "$id"
    printf '%s\n' "$role" >"$STATE_DIR/$id.role"
    cmd_up "$id"
  else
    printf '%s\n' "$role" >"$STATE_DIR/$id.role"
    log "world $id is $role from its next start"
  fi
}

# --- candidates ---------------------------------------------------------------------
patch_set() {
  (cd "$GAME_DIR/rs-sdk" && sha256sum Dockerfile ./*.js) | sha256sum | cut -c1-12
}

cmd_candidate_build() {
  local if_new=false source_ref=""
  while (($#)); do
    case "$1" in
      --if-new) if_new=true ;;
      --source-ref) source_ref="${2:?--source-ref needs a commit}"; shift ;;
      *) die "unknown option $1 (usage: candidate build [--if-new] [--source-ref COMMIT])" ;;
    esac
    shift
  done
  local branch upstream patches tag log_file work
  if [[ -n "$source_ref" ]]; then
    # A pinned commit (e.g. world 1's own source for a fixes-only build): resolved in
    # the checkout without fetching; the checkout itself never moves (worktree below).
    [[ "$source_ref" != -* ]] || die "--source-ref: not a commit: $source_ref"
    upstream="$(git_ -C "$RS_SDK_SOURCE_DIR" rev-parse --verify --quiet "$source_ref^{commit}")" \
      || die "--source-ref: $source_ref is not a commit in $RS_SDK_SOURCE_DIR"
  else
    branch="$(git_ -C "$RS_SDK_SOURCE_DIR" symbolic-ref --short -q HEAD)" || die "cannot read the branch of $RS_SDK_SOURCE_DIR"
    git_ -C "$RS_SDK_SOURCE_DIR" fetch --quiet origin "$branch" </dev/null || die "cannot fetch $RS_SDK_SOURCE_DIR"
    upstream="$(git_ -C "$RS_SDK_SOURCE_DIR" rev-parse FETCH_HEAD)"
  fi
  patches="$(patch_set)"
  tag="$CANDIDATE_REPO:candidate-${upstream:0:12}-$patches"
  if image_id "$tag" >/dev/null; then
    log "candidate $tag already built"
    $if_new && return 0
  fi
  if $if_new && [[ -r "$STATE_DIR/candidate.failed" && "$(cat "$STATE_DIR/candidate.failed")" == "$upstream $patches" ]]; then
    log "candidate for upstream ${upstream:0:12} with patch set $patches failed before; not retried"
    return 1
  fi
  log_file="$STATE_DIR/candidate-${upstream:0:12}-$patches.log"
  work="$STATE_DIR/build-src"
  git_ -C "$RS_SDK_SOURCE_DIR" worktree remove --force "$work" >/dev/null 2>&1 || rm -rf "$work"
  git_ -C "$RS_SDK_SOURCE_DIR" worktree prune
  log "building candidate from upstream ${upstream:0:12} + patch set $patches (log: $log_file)"
  local ok=true
  {
    git_ -C "$RS_SDK_SOURCE_DIR" worktree add --detach --quiet "$work" "$upstream" \
      && CANDIDATE_SOURCE="$work" CANDIDATE_UPSTREAM="$upstream" CANDIDATE_PATCHES="$patches" \
         CANDIDATE_UPSTREAM_TAG="$CANDIDATE_REPO:upstream-${upstream:0:12}" CANDIDATE_TAG="$tag" \
         docker compose -f "$WORLDS_DIR/candidate-compose.yml" build candidate
  } >"$log_file" 2>&1 </dev/null || ok=false
  git_ -C "$RS_SDK_SOURCE_DIR" worktree remove --force "$work" >/dev/null 2>&1 || true
  if ! $ok; then
    printf '%s %s\n' "$upstream" "$patches" >"$STATE_DIR/candidate.failed"
    printf '%s\t%s\t%s\t%s\t%s\tfailed\n' "-" "$tag" "$upstream" "$patches" "$(date +%s)" >>"$STATE_DIR/candidates.tsv"
    log "candidate build FAILED; neither world was touched. Last lines:"
    tail -n 15 "$log_file" >&2
    notify "RS-SDK candidate build FAILED" "Upstream ${upstream:0:12} with patch set $patches did not build (a patch script may no longer match upstream). Neither world was touched. Log: $log_file" high
    return 1
  fi
  rm -f "$STATE_DIR/candidate.failed"
  local id compat_result
  id="$(image_id "$tag")"
  if check_compat "$id" >"$log_file.compat" 2>&1; then compat_result="same XP curve and save format as world 1"
  else compat_result="NOT save-compatible with world 1: $(grep -h refused "$log_file.compat" | tr '\n' ' ')"; fi
  printf '%s\t%s\t%s\t%s\t%s\tok\n' "$id" "$tag" "$upstream" "$patches" "$(date +%s)" >>"$STATE_DIR/candidates.tsv"
  log "candidate ready: $tag ($compat_result)"
  notify "RS-SDK candidate ready" "$tag: upstream ${upstream:0:12}, patch set $patches; $compat_result. Test it: world.sh test up, then world.sh promote --next-window." default
}

cmd_candidate_list() {
  [[ -r "$STATE_DIR/candidates.tsv" ]] || { log "no candidates built yet"; return 0; }
  python3 - "$STATE_DIR/candidates.tsv" <<'PY'
import sys, time
for line in open(sys.argv[1]):
    image, tag, upstream, patches, built, status = line.rstrip('\n').split('\t')
    print(f"{time.strftime('%F %T', time.localtime(int(built)))}  {status:<6}  upstream {upstream[:12]}  patches {patches}  {tag}")
PY
}

# --- promote --------------------------------------------------------------------------
cmd_promote() {
  local image="" mode="" yes=false
  PRE_START=""
  while (($#)); do
    case "$1" in
      --now) mode=now ;;
      --next-window) mode=window ;;
      --yes) yes=true ;;
      --pre-start) [[ -z "$PRE_START" ]] || die "one --pre-start/--fix-hiscores only"; PRE_START="${2:?--pre-start needs a command}"; shift ;;
      --fix-hiscores) [[ -z "$PRE_START" ]] || die "one --pre-start/--fix-hiscores only"; PRE_START=fix-hiscores ;;
      -*) die "unknown option $1" ;;
      *) image="$1" ;;
    esac
    shift
  done
  [[ -n "$mode" ]] || die "say when: --next-window (the weekly maintenance restart, with backup and rollback) or --now (2-minute countdown)"
  [[ -z "$PRE_START" || "$mode" == now ]] || die "--pre-start/--fix-hiscores run only with --now (the engine-stopped step of this promotion)"
  if [[ "$PRE_START" == fix-hiscores ]]; then
    image_id "$HISCORE_FIX_IMAGE" >/dev/null || die "--fix-hiscores runs in $HISCORE_FIX_IMAGE, which is not on this host (docker pull it first)"
    log "hiscore fix, dry run against the live database (applied while the engine is stopped):"
    python3 "$GAME_DIR/rs-sdk/fix-hiscore-levels.py" --db "$RS_SDK_DATA_DIR/db.sqlite" --examples 0 \
      || die "the hiscore fix's dry run failed; nothing changed"
  fi
  if [[ -z "$image" ]]; then
    [[ -r "$STATE_DIR/$TEST_WORLD.image" ]] || die "no image named and the test world has never run one"
    image="$(cat "$STATE_DIR/$TEST_WORLD.image")"
  fi
  local id main base cand
  id="$(image_id "$image")" || die "no such image: $image"
  main="$(main_image)" || die "cannot tell which image world 1 runs"
  [[ "$id" != "$main" ]] || die "world 1 already runs $image"
  # A promotion may bring new content, migrations or a newer save version (world 1
  # migrates at start and reads older saves); the XP curve must never change.
  base="$(fingerprint "$main")" || die "cannot fingerprint world 1's image"
  cand="$(fingerprint "$id")" || die "cannot fingerprint $image"
  python3 -c 'import json,sys; a,b=(json.load(open(p)) for p in sys.argv[1:3]); sys.exit(0 if a.get("xp")==b.get("xp") and not str(a.get("xp")).startswith("error") else 1)' "$base" "$cand" \
    || die "$image levels differently from world 1 (XP curve); refusing to promote"
  if ! $yes; then
    [[ -t 0 ]] || die "promote asks for confirmation; rerun with --yes"
    read -r -p "Put $image ($id) on world 1 ($mode)? [y/N] " answer
    [[ "$answer" == [yY]* ]] || die "not promoted"
  fi
  install -d -m 700 "$MAINT_STATE_DIR"
  if [[ "$mode" == window ]]; then
    printf '%s\n' "$id" >"$MAINT_STATE_DIR/rs-sdk.promote"
    log "world 1 switches to $image at the next weekly maintenance (backup, verify, then start; rollback on failure)"
    notify "RS-SDK promotion scheduled" "World 1 switches to $image at the next weekly maintenance." low
    offer_test_down
    return 0
  fi
  promote_now "$id" "$main"
  offer_test_down
}

offer_test_down() {
  is_running "$(container_of "$TEST_WORLD")" || return 0
  log "the test world is still up; take it down with: world.sh test down"
}

promote_now() {
  local id="$1" previous="$2" deadline parent name
  exec {LOCK_FD}>"$MAINT_STATE_DIR/lock"
  flock -n "$LOCK_FD" || die "maintenance is running; promote --next-window instead, or wait"
  is_running "$MAIN_CONTAINER" || die "world 1 is not running"
  parent="$(dirname -- "$RS_SDK_DATA_DIR")"
  name="$(basename -- "$RS_SDK_DATA_DIR")"
  docker tag "$previous" "$RS_SDK_ROLLBACK_IMAGE"
  docker update --restart=no "$MAIN_CONTAINER" >/dev/null
  deadline=$(( $(date +%s) + WORLD_COUNTDOWN_SECONDS ))
  docker exec -e COUNTDOWN_DEADLINE_MS="$((deadline * 1000))" -e COUNTDOWN_WITH_UPDATE=1 "$MAIN_CONTAINER" \
    bun -e "$(<"$SCRIPT_DIR/countdown.js")" >"$STATE_DIR/1.countdown.log" 2>&1 </dev/null &
  local helper=$!
  printf '%s\n' "$deadline" >"$STATE_DIR/1.countdown"
  for _ in $(seq 1 30); do grep -qx announced "$STATE_DIR/1.countdown.log" && break; sleep 1; done
  if ! grep -qx announced "$STATE_DIR/1.countdown.log"; then
    kill "$helper" 2>/dev/null || true
    docker update --restart=unless-stopped "$MAIN_CONTAINER" >/dev/null
    rm -f "$STATE_DIR/1.countdown"
    die "world 1's countdown was not announced; nothing changed"
  fi
  log "world 1: countdown announced; down at $(date -d "@$deadline" '+%T')"
  for _ in $(seq 1 $((WORLD_COUNTDOWN_SECONDS + 180))); do is_running "$MAIN_CONTAINER" || break; sleep 1; done
  kill "$helper" 2>/dev/null || true
  rm -f "$STATE_DIR/1.countdown"
  if is_running "$MAIN_CONTAINER"; then
    docker update --restart=unless-stopped "$MAIN_CONTAINER" >/dev/null
    die "world 1 did not shut down on its countdown; left running on its current image"
  fi
  log "world 1 stopped; copying its data dir before the switch"
  docker run --rm --network none --entrypoint sh -e NAME="$name" -v "$parent":/parent "$RS_SDK_ROLLBACK_IMAGE" -c \
    'set -e; cd /parent; rm -rf "$NAME.pre-promote"; cp -a "$NAME" "$NAME.pre-promote"' </dev/null \
    || { start_main "$previous"; die "could not copy the data dir; world 1 restarted on its previous image"; }
  local why="world 1 is not healthy on $id"
  if [[ -n "$PRE_START" ]] && ! run_pre_start; then
    why="the pre-start step failed"
  elif start_main "$id"; then
    log "world 1 runs $id"
    notify "RS-SDK world 1 promoted" "World 1 now runs $id (previous: $previous, tagged rollback)." default
    return 0
  fi
  log "$why; rolling back data and image"
  docker stop -t 120 "$MAIN_CONTAINER" >/dev/null 2>&1 || true
  docker run --rm --network none --entrypoint sh -e NAME="$name" -v "$parent":/parent "$RS_SDK_ROLLBACK_IMAGE" -c \
    'set -e; cd /parent; find "$NAME" -mindepth 1 -maxdepth 1 -exec rm -rf {} +; cp -a "$NAME.pre-promote/." "$NAME/"' </dev/null \
    || die "rollback of the data dir FAILED; world 1 is down. Its copy: $RS_SDK_DATA_DIR.pre-promote"
  start_main "$previous" || die "world 1 did not come back on its previous image; check docker logs $MAIN_CONTAINER"
  notify "RS-SDK promotion FAILED" "World 1 was not healthy on $id and is back on $previous with its data restored." high
  die "promotion failed; world 1 is back on its previous image"
}

# The promote hook: runs once, after the data copy and before world 1 starts on the new
# image, with the engine stopped. A failure restores the data copy and the old image.
run_pre_start() {
  is_running "$MAIN_CONTAINER" && { log "pre-start: $MAIN_CONTAINER is running; refusing"; return 1; }
  if [[ "$PRE_START" == fix-hiscores ]]; then
    # The data dir is root's (the engine's), so the repair runs as root in a container,
    # without network; its backups land in the operator's state dir.
    local backups="$MAINT_STATE_DIR/../hiscore-fix"
    install -d -m 700 "$backups"
    log "pre-start: fix-hiscore-levels.py --apply (engine stopped; backup in $(cd "$backups" && pwd))"
    docker run --rm --network none --entrypoint sh -e OWNER="$(id -u):$(id -g)" \
      -v "$RS_SDK_DATA_DIR":/data -v "$backups":/backup \
      -v "$GAME_DIR/rs-sdk/fix-hiscore-levels.py":/fix-hiscore-levels.py:ro "$HISCORE_FIX_IMAGE" -c \
      'rc=0; python3 /fix-hiscore-levels.py --db /data/db.sqlite --apply --backup-dir /backup || rc=$?; chown -R "$OWNER" /backup; exit "$rc"' </dev/null
  else
    log "pre-start: $PRE_START (engine stopped)"
    RS_SDK_DATA_DIR="$RS_SDK_DATA_DIR" bash -c "$PRE_START" </dev/null
  fi
}

start_main() {
  docker tag "$1" "$RS_SDK_IMAGE"
  # maintenance.sh restarts what this file names, so the switch survives the next window.
  printf '%s\n' "$1" >"$MAINT_STATE_DIR/rs-sdk.image.tmp" && mv "$MAINT_STATE_DIR/rs-sdk.image.tmp" "$MAINT_STATE_DIR/rs-sdk.image"
  docker compose --project-directory "$GAME_DIR/rs-sdk" -f "$GAME_DIR/rs-sdk/docker-compose.yml" \
    up -d --no-build --force-recreate rs-sdk </dev/null || return 1
  local status
  for _ in $(seq 1 180); do
    status="$(docker inspect -f '{{.State.Status}} {{.State.Health.Status}}' "$MAIN_CONTAINER" 2>/dev/null)" || status=""
    [[ "$status" == "running healthy" ]] && return 0
    sleep 5
  done
  return 1
}

# --- dispatch -----------------------------------------------------------------------------
command="${1:-status}"
shift || true
exec {WORLDS_LOCK}>"$STATE_DIR/lock"
case "$command" in
  status|list) worlds list "$@"
    [[ " $* " == *" --json "* ]] && exit 0
    printf 'world 1 pin (maintenance): %s\n' "$(cat "$MAINT_STATE_DIR/rs-sdk.image" 2>/dev/null || echo none)"
    [[ -r "$MAINT_STATE_DIR/rs-sdk.promote" ]] && printf 'promotion scheduled for the next window: %s\n' "$(cat "$MAINT_STATE_DIR/rs-sdk.promote")"
    printf 'upstream checkout: %s\n' "$(git_ -C "$RS_SDK_SOURCE_DIR" log -1 --format='%h %cs %s' 2>/dev/null || echo unknown)"
    printf 'patch set: %s (%s)\n' "$(patch_set)" "$(cd "$GAME_DIR/rs-sdk" && printf '%s ' ./*.js)"
    printf 'updates: RS_SDK_UPDATES=%s (AUTO_UPDATE=%s applies to Lost City)\n' "${RS_SDK_UPDATES:-candidate}" "${AUTO_UPDATE:-true}"
    printf 'latest candidate: %s\n' "$(latest_candidate 2>/dev/null || echo none)"
    printf 'test world %s allowlist: %s\n' "$TEST_WORLD" "$(worlds allow "$TEST_WORLD" list | tr '\n' ' ')" ;;
  up) flock -n "$WORLDS_LOCK" || die "another world.sh is running"; cmd_up "$@" ;;
  down) flock -n "$WORLDS_LOCK" || die "another world.sh is running"; cmd_down "$@" ;;
  test)
    flock -n "$WORLDS_LOCK" || die "another world.sh is running"
    sub="${1:-}"; shift || true
    case "$sub" in
      up) cmd_up "$TEST_WORLD" "$@" ;;
      down) cmd_down "$TEST_WORLD" "$@" ;;
      *) die "usage: world.sh test up [IMAGE] | test down" ;;
    esac ;;
  role) flock -n "$WORLDS_LOCK" || die "another world.sh is running"; cmd_role "${1:?id}" "${2:?live|test}" ;;
  allow) worlds allow "$@" ;;
  compat) check_compat "$(image_id "${1:?image}")" "${@:2}" ;;
  candidate)
    sub="${1:-}"; shift || true
    case "$sub" in
      build) flock -n "$WORLDS_LOCK" || die "another world.sh is running"; cmd_candidate_build "$@" ;;
      list) cmd_candidate_list ;;
      *) die "usage: world.sh candidate build [--if-new] [--source-ref COMMIT] | candidate list" ;;
    esac ;;
  promote) cmd_promote "$@" ;;
  *) die "unknown command: $command (see the header of $0)" ;;
esac
