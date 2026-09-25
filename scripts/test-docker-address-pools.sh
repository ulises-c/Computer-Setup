#!/usr/bin/env bash
# Regression tests for the server Docker address-pool step (#75): the merge,
# the live-state "up to date" test, rollback on a failed restart, and the
# verify.sh checks. Docker, dockerd, systemctl and sudo are stubbed; a fake
# daemon's live pools are loaded from the daemon.json on each "restart".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

FAILS=0
fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }
ok() { printf 'ok   %s\n' "$1"; }

stub() {
  local name="$1"; shift
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

stub sudo 'exec "$@"'
stub dockerd \
  '[[ "$1" == --validate ]] || exit 2' \
  'jq -e "type == \"object\"" "$3" >/dev/null && echo "configuration OK"'
stub systemctl \
  'printf "%s\n" "$*" >> "$STATE/systemctl.log"' \
  'case "$1" in' \
  '  restart)' \
  '    [[ -f "$STATE/start_limited" ]] && { echo "Start request repeated too quickly" >&2; exit 1; }' \
  '    n="$(cat "$STATE/restart_fail")"' \
  '    if (( n > 0 )); then echo $((n - 1)) > "$STATE/restart_fail"; touch "$STATE/start_limited"; exit 1; fi' \
  '    if [[ -f "$DOCKER_DAEMON_JSON" ]]; then' \
  '      jq -c "if .\"default-address-pools\" then .\"default-address-pools\" | map({Base: .base, Size: .size}) else null end" "$DOCKER_DAEMON_JSON" > "$STATE/live"' \
  '    else echo null > "$STATE/live"; fi ;;' \
  '  reset-failed) rm -f "$STATE/start_limited" ;;' \
  '  *) exit 1 ;;' \
  'esac'
stub docker \
  '[[ -f "$STATE/down" ]] && { echo "cannot connect" >&2; exit 1; }' \
  'case "$1 ${2:-}" in' \
  '  "info ") ;;' \
  '  "info --format") cat "$STATE/live" ;;' \
  '  "network ls") [[ -f "$STATE/ls_fail" ]] && exit 1; cat "$STATE/net_ids" ;;' \
  '  "network inspect") [[ -f "$STATE/inspect_fail" ]] && exit 1; cat "$STATE/net_listing" ;;' \
  '  *) exit 1 ;;' \
  'esac'

NVIDIA='{"runtimes":{"nvidia":{"args":[],"path":"nvidia-container-runtime"}}}'
WANT='[{"base":"172.16.0.0/12","size":24}]'

# Fresh fake host: $1 = name, $2 = initial daemon.json content, or "none" for
# no file. A failed restart trips a start limit that only reset-failed clears,
# like docker.service's StartLimitBurst.
new_host() {
  export STATE="$WORK/$1" DOCKER_DAEMON_JSON="$WORK/$1/etc/docker/daemon.json"
  mkdir -p "$STATE/etc/docker"
  [[ "$2" == none ]] || printf '%s\n' "$2" > "$DOCKER_DAEMON_JSON"
  echo null > "$STATE/live"
  echo 0 > "$STATE/restart_fail"
  : > "$STATE/systemctl.log"
  printf 'n1\n' > "$STATE/net_ids"
  printf 'bridge 172.16.0.0/24\n' > "$STATE/net_listing"
}

restarts() { grep -c '^restart docker$' "$STATE/systemctl.log" || true; }
pools_in_file() { jq -cS '."default-address-pools" // []' "$DOCKER_DAEMON_JSON"; }

# Own bash process per run so `set -e` behaves as it does under setup.sh.
step() {
  local dry="${1:-false}"
  STEP_RC=0
  PATH="$STUBS:$PATH" bash -c '
    set -euo pipefail
    SETUP_ROOT="$1"; CONFIG_SRC_DIR="$1/linux-server"
    source "$1/lib/core.sh"; source "$1/platforms/server.sh"
    DRY_RUN="$2"
    server_docker_daemon_step' _ "$REPO_ROOT" "$dry" > "$STATE/out" 2>&1 || STEP_RC=$?
}

verify_out() {
  PATH="$STUBS:$PATH" bash -c '
    set -uo pipefail
    SETUP_ROOT="$1"; PLATFORM=server
    source "$1/lib/core.sh"; source "$1/lib/verify.sh"
    verify_extras_server' _ "$REPO_ROOT" 2>&1 | grep -i docker || true
}

# ── setup step ───────────────────────────────────────────────────────────────
new_host dry "$NVIDIA"
step true
[[ $STEP_RC == 0 && "$(restarts)" == 0 && "$(pools_in_file)" == '[]' ]] \
  && ok 'dry-run changes nothing' || fail 'dry-run changed state'

new_host merge "$NVIDIA"
chmod 600 "$DOCKER_DAEMON_JSON"
step
[[ $STEP_RC == 0 ]] || fail "merge rc=$STEP_RC: $(cat "$STATE/out")"
[[ "$(pools_in_file)" == "$WANT" ]] || fail 'merge did not add the pools'
jq -e '.runtimes.nvidia' "$DOCKER_DAEMON_JSON" >/dev/null || fail 'merge dropped the nvidia runtime'
[[ "$(stat -c %a "$DOCKER_DAEMON_JSON")" == 600 ]] || fail 'merge did not keep the file mode'
compgen -G "$DOCKER_DAEMON_JSON.bak.*" >/dev/null || fail 'merge wrote no backup'
[[ "$(restarts)" == 1 ]] || fail "merge restarted $(restarts) times"
ok 'merge keeps other keys and mode, backs up, restarts once'

step
[[ $STEP_RC == 0 && "$(restarts)" == 1 ]] && grep -q 'up to date and live' "$STATE/out" \
  && ok 'second run is a no-op' || fail 'second run was not a no-op'

echo null > "$STATE/live"
step
[[ $STEP_RC == 0 && "$(restarts)" == 2 && "$(jq -c . "$STATE/live")" != null ]] \
  && ok 'file pinned but daemon not restarted (interrupted run): next run restarts' \
  || fail 'interrupted run was not completed by the next run'

new_host rollback "$NVIDIA"
cp "$DOCKER_DAEMON_JSON" "$STATE/original"
echo 1 > "$STATE/restart_fail"
step
[[ $STEP_RC != 0 ]] || fail 'failed restart returned success'
cmp -s "$DOCKER_DAEMON_JSON" "$STATE/original" || fail 'failed restart did not restore the original file'
grep -q '^reset-failed docker$' "$STATE/systemctl.log" || fail 'rollback skipped reset-failed'
[[ "$(restarts)" == 2 ]] || fail "rollback restarted $(restarts) times, expected 2"
ok 'failed restart restores the original, reset-failed, restarts, exits non-zero'
step
[[ $STEP_RC == 0 && "$(pools_in_file)" == "$WANT" && "$(restarts)" == 3 ]] \
  && ok 'retry after rollback applies the pin' || fail 'retry after rollback did not apply the pin'

new_host nofile none
echo 1 > "$STATE/restart_fail"
step
[[ $STEP_RC != 0 && ! -e "$DOCKER_DAEMON_JSON" ]] \
  && ok 'failed restart with no prior file removes the new file' \
  || fail 'failed restart left a new daemon.json behind'

new_host empty ''
step
[[ $STEP_RC == 0 && "$(pools_in_file)" == "$WANT" ]] \
  && ok 'empty daemon.json is treated as {}' || fail "empty daemon.json: rc=$STEP_RC $(cat "$STATE/out")"

new_host invalid '{broken'
step
[[ $STEP_RC == 0 && "$(cat "$DOCKER_DAEMON_JSON")" == '{broken' && "$(restarts)" == 0 ]] \
  && ok 'invalid daemon.json is left alone' || fail 'invalid daemon.json was modified'

new_host down "$NVIDIA"
touch "$STATE/down"
step
[[ $STEP_RC == 0 && "$(pools_in_file)" == '[]' && "$(restarts)" == 0 ]] \
  && ok 'unreachable daemon: file untouched, no restart' || fail 'unreachable daemon was reconfigured'

# ── verify.sh ────────────────────────────────────────────────────────────────
new_host vok "$NVIDIA"
step
out="$(verify_out)"
[[ "$(grep -c '✅' <<< "$out")" == 3 && "$(grep -c '❌' <<< "$out")" == 0 ]] \
  && ok 'verify: pinned host passes all three docker checks' || fail "verify pinned host: $out"

echo null > "$STATE/live"
grep -q '❌.*running with the pinned' <<< "$(verify_out)" \
  && ok 'verify: file pinned but daemon not restarted fails' || fail 'verify missed an unapplied pin'

touch "$STATE/down"
out="$(verify_out)"
grep -q '❌.*daemon reachable' <<< "$out" && ! grep -q 'bridge' <<< "$out" \
  && ok 'verify: unreachable daemon is an explicit failure' || fail "verify unreachable daemon: $out"
rm "$STATE/down"

touch "$STATE/ls_fail"
grep -q '❌.*could not list' <<< "$(verify_out)" \
  && ok 'verify: network ls failure is reported' || fail 'verify hid a network ls failure'
rm "$STATE/ls_fail"

touch "$STATE/inspect_fail"
grep -q '❌.*could not list' <<< "$(verify_out)" \
  && ok 'verify: network inspect failure is reported' || fail 'verify passed on a network inspect failure'
rm "$STATE/inspect_fail"

printf 'bridge 172.16.0.0/24\nweb_default 192.168.16.0/20 fd00::/64\n' > "$STATE/net_listing"
out="$(verify_out)"
grep -q '❌.*web_default=192.168.16.0/20' <<< "$out" && ! grep -q 'fd00' <<< "$out" \
  && ok 'verify: stray IPv4 bridge is named, IPv6 ignored' || fail "verify stray bridge: $out"

if (( FAILS > 0 )); then
  printf 'docker address-pool tests: %d FAILED\n' "$FAILS" >&2
  exit 1
fi
printf 'docker address-pool tests passed.\n'
