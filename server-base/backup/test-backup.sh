#!/usr/bin/env bash
set -euo pipefail

# Tests for the shared restic engine (server-base/backup/backup.sh), run against
# throwaway host directories that use the real hosts' sources.sh files and
# stubbed restic/sqlite3/mountpoint/docker on PATH.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# make_host <name> <real-host-dir>: a fake checkout with the engine symlinked in
# and the real host's sources.sh.
make_host() {
  local dir="$tmp/$1"
  mkdir -p "$dir/backup"
  ln -s "$SCRIPT_DIR/backup.sh" "$dir/backup/backup.sh"
  cp "$REPO/$2/backup/sources.sh" "$dir/backup/sources.sh"
  # Never read or write the real world marker from a test.
  sed -i.bak "s|^BACKUP_WORLD_MARKER=.*|BACKUP_WORLD_MARKER=$dir/world-seen|" "$dir/backup/sources.sh"
  printf '%s\n' "$dir"
}

# --- notify-failure (OnFailure owns alerts; status JSON bookkeeping) ---------
pi="$(make_host pi linux-pi)"
run_notifier() {
  STATUS_JSON="$tmp/status.json" NTFY_URL="${1:-}" NTFY_TOPIC=backup-test NTFY_TOKEN='' \
    KUMA_PUSH_URL="${2:-}" bash "$pi/backup/backup.sh" notify-failure
}

run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "missing status not recorded as failed"

jq -n '{status:"success", last_run:"previous"}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "success not overwritten"

jq -n '{status:"failed", last_run:"detailed", duration_seconds:42, notifier_pending:true}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.last_run' "$tmp/status.json")" == detailed ]] || fail "pending failure detail lost"
[[ "$(jq -r '.duration_seconds' "$tmp/status.json")" == 42 ]] || fail "pending failure duration lost"
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == false ]] || fail "pending flag not cleared"

jq -n '{status:"failed", last_run:"stale", duration_seconds:42, notifier_pending:false}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.last_run' "$tmp/status.json")" != stale ]] || fail "stale failure not refreshed"

jq -n '{status:"running", last_run:"interrupted", notifier_pending:false}' >"$tmp/status.json"
run_notifier
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "interrupted run not recorded as failed"

if STATUS_JSON="$tmp/status.json" NTFY_URL=not-a-url bash "$pi/backup/backup.sh" >/dev/null 2>&1; then
  fail "invalid early notification input unexpectedly succeeded"
fi
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "early failure not recorded"
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == true ]] || fail "early failure not left pending"
run_notifier
[[ "$(jq -r '.notifier_pending' "$tmp/status.json")" == false ]] || fail "pending not cleared after notifier"

rm -f "$tmp/status.json"
run_notifier not-a-url also-not-a-url
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "invalid notifier config blocked status"

# Without EnvironmentFile, the failure path reads the notifier keys from .env,
# tolerating `export`, inline comments and CRLF, and checks each channel alone.
printf 'export NTFY_URL=not-a-url\nKUMA_PUSH_URL=https://kuma.example/push # heartbeat\r\n' >"$pi/backup/.env"
err="$(STATUS_JSON="$tmp/status.json" bash "$pi/backup/backup.sh" notify-failure 2>&1)"
grep -q 'invalid ntfy configuration' <<<"$err" || fail "notify-failure ignored .env notifier keys"
if grep -q 'invalid KUMA_PUSH_URL' <<<"$err"; then fail "a bad ntfy URL suppressed the Kuma push"; fi
rm "$pi/backup/.env"

# With no alert channel at all, the failure path says so instead of staying silent.
err="$(STATUS_JSON="$tmp/status.json" bash "$pi/backup/backup.sh" notify-failure 2>&1)"
grep -q 'nobody alerted' <<<"$err" || fail "empty alert channels not reported"

# A broken host path must not stop the failure notifier (game: relative install dir).
game="$(make_host game linux-game-server)"
mkdir -p "$game/dragonwilds"
printf 'DRAGONWILDS_INSTALL_DIR=games/dragonwilds\n' >"$game/dragonwilds/.env"
rm -f "$tmp/status.json"
STATUS_JSON="$tmp/status.json" bash "$game/backup/backup.sh" notify-failure 2>/dev/null \
  || fail "notify-failure died on a bad DRAGONWILDS_INSTALL_DIR"
[[ "$(jq -r '.status' "$tmp/status.json")" == failed ]] || fail "game failure not recorded"

# --- full run with stubbed tools -------------------------------------------
stub="$tmp/stub"
mkdir -p "$stub"
cat >"$stub/restic" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RESTIC_LOG"
case "$*" in
  *"snapshots latest"*) printf '[{"short_id":"abc12345"}]\n' ;;
  *stats*) printf '{"total_size":2048}\n' ;;
esac
EOF
cat >"$stub/sqlite3" <<'EOF'
#!/usr/bin/env bash
[[ "$(head -c 15 "$1")" == "SQLite format 3" ]] || exit 1
dest="${2#.backup \'}"; cp "$1" "${dest%\'}"
EOF
cat >"$stub/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$2" != */unmounted ]]
EOF
# Two running containers: Filebrowser, bind-mounting its database dir and the
# whole host filesystem, and AdGuard; stop/start calls are logged in order.
cat >"$stub/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info|volume) exit 0 ;;
  ps) [[ "${DOCKER_FAIL:-}" != ps ]] || { printf 'Cannot connect to the Docker daemon\n' >&2; exit 1; }
    [[ "${DOCKER_FAIL:-}" == partial-then-empty && -e "$DOCKER_LOG.inspected" ]] && exit 0
    printf 'fb0000000001\nag0000000001\n' ;;
  inspect)
    [[ "${*: -1}" != portainer ]] || exit 1
    if [[ "${DOCKER_FAIL:-}" == partial-then-empty ]]; then
      touch "$DOCKER_LOG.inspected"
      printf '/filebrowser\t%s\n/adguardhome\t%s\n' "$FB_DB_DIR" "$AG_WORK_DIR"
      printf 'Error: No such object: ag0000000002\n' >&2; exit 1
    fi
    if [[ "${DOCKER_FAIL:-}" == inspect ]] \
      || { [[ "${DOCKER_FAIL:-}" == inspect-once && ! -e "$DOCKER_LOG.inspected" ]] && touch "$DOCKER_LOG.inspected"; }; then
      printf 'Error: No such object\n' >&2; exit 1
    fi
    for id in "$@"; do
      case "$id" in
        fb0000000001) if [[ "${FB_FILE_MOUNT:-}" == 1 ]]; then printf '/filebrowser\t%s/filebrowser.db\n/filebrowser\t/\n' "$FB_DB_DIR"
          else printf '/filebrowser\t%s\n/filebrowser\t/\n' "$FB_DB_DIR"; fi ;;
        ag0000000001) printf '/adguardhome\t%s\n' "$AG_WORK_DIR" ;;
      esac
    done ;;
  stop|start) printf '%s %s\n' "$1" "$2" >>"$DOCKER_LOG" ;;
  *) exit 1 ;;
esac
EOF
# A DNS peer answers only while DIG_ANSWER=1.
cat >"$stub/dig" <<'EOF'
#!/usr/bin/env bash
[[ "${DIG_ANSWER:-1}" == 1 ]] && printf '93.184.215.14\n'
exit 0
EOF
cat >"$stub/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == show ]] || exit 1
[[ "$*" == *LoadState* ]] && { printf 'loaded\n'; exit 0; }
printf '%s\n' "$BACKUP_DRAGONWILDS_INSTALL_DIR"
EOF
chmod +x "$stub"/*

server="$(make_host server linux-server)"
player_log="$tmp/player-log"
sed -i.bak "s|/var/lib/dragonwilds/player-log|$player_log|g" "$server/backup/sources.sh"
drive="$tmp/drive"
mkdir -p "$drive" "$server/uptime-kuma/data" "$server/homepage/config" "$server/ntfy" "$server/forgejo" \
  "$tmp/forgejo-data"
touch "$drive/.backup-target-ok"
printf 'SQLite format 3\0x' >"$server/uptime-kuma/data/kuma.db"
mkdir -p "$server/filebrowser/database"
printf '\0\0\0\0bolt' >"$server/filebrowser/database/filebrowser.db"
mkdir -p "$server/adguard/work/data"
printf '\0\0\0\0bolt' >"$server/adguard/work/data/stats.db"
export FB_DB_DIR="$server/filebrowser/database" AG_WORK_DIR="$server/adguard/work" DOCKER_LOG="$tmp/docker.log"
printf 'title: test\n' >"$server/homepage/config/settings.yaml"
printf 'FORGEJO_DATA_PATH="%s"\n' "$tmp/forgejo-data" >"$server/forgejo/.env"
printf 'NTFY_BASE_URL=x\n' >"$server/ntfy/.env"

# Quoted notifier values with inline comments must be parsed like shell .env values.
cat >"$tmp/quoted-notifier.env" <<'EOF'
NTFY_URL="https://ntfy.example" # comment
EOF
quoted_ntfy="$(bash -c 'eval "$(sed -n "/^env_value()/,/^CANDIDATES=()/p" "$1")"; env_value "$2" NTFY_URL' bash "$REPO/server-base/backup/backup.sh" "$tmp/quoted-notifier.env")"
[[ "$quoted_ntfy" == https://ntfy.example ]] || fail "quoted notifier value with inline comment was misparsed"

cat >"$server/backup/.env" <<EOF
RESTIC_REPOSITORY=$drive/restic
RESTIC_PASSWORD=test
BACKUP_MOUNT=$drive
SECOND_RESTIC_REPOSITORY=$tmp/unmounted/restic-copy
SECOND_BACKUP_MOUNT=$tmp/unmounted
STAGING_DIR=$tmp/staging
BACKUP_DRAGONWILDS_INSTALL_DIR=$server/dragonwilds/games/dragonwilds
BACKUP_FORGEJO_DATA_PATH=$tmp/forgejo-data
DNS_PEERS=192.0.2.53
DNS_PEER_WAIT_SECONDS=2
DNS_PEER_POLL_SECONDS=1
EOF

out="$(PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash ${TEST_TRACE:+-x} "$server/backup/backup.sh" 2>&1)" \
  || fail "server run failed: $out"
backup_line="$(grep '^backup ' "$tmp/restic.log")"
for want in "$tmp/forgejo-data" "$server/uptime-kuma/data" "$server/homepage/config" "$tmp/staging" \
            "--tag server-nightly"; do
  [[ "$backup_line" == *"$want"* ]] || fail "restic backup missing $want: $backup_line"
done
[[ "$backup_line" != *"$server/qbittorrent/config"* ]] || fail "absent path was backed up"
grep -q 'sqlite snapshot: uptime-kuma/data/kuma.db' <<<"$out" || fail "sqlite db not staged"
grep -q 'consistent copy: stopping filebrowser briefly' <<<"$out" || fail "BoltDB owner not stopped: $out"
grep -q 'raw copy with filebrowser stopped: filebrowser/database/filebrowser.db' <<<"$out" \
  || fail "BoltDB not copied while its owner was stopped: $out"
grep -q 'raw copy with adguardhome stopped: adguard/work/data/stats.db' <<<"$out" \
  || fail "AdGuard not stopped while a DNS peer answered: $out"
[[ "$(<"$DOCKER_LOG")" == $'stop adguardhome\nstart adguardhome\nstop filebrowser\nstart filebrowser' ]] \
  || fail "owners not stopped then restarted exactly once each: $(<"$DOCKER_LOG")"
grep -q 'second copy incomplete' <<<"$out" || fail "unmounted second drive not reported"
if grep -q '^init' "$tmp/restic.log"; then fail "second repo initialized on an unmounted drive"; fi
[[ "$(jq -r '.status' "$server/backup/status/backup-status.json")" == success ]] || fail "status not success"
[[ "$(jq -r '.snapshot' "$server/backup/status/backup-status.json")" == abc12345 ]] || fail "snapshot id not recorded"
[[ ! -e "$tmp/staging" ]] || fail "staging dir left behind"
grep -q 'skipping coordination' <<<"$out" || fail "absent player-log dir did not skip lock coordination"

# With no DNS peer answering, AdGuard is never stopped: wait, then copy live.
: >"$DOCKER_LOG"
out="$(DIG_ANSWER=0 PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "run without a DNS peer failed: $out"
grep -q 'waiting for a DNS peer before stopping adguardhome' <<<"$out" || fail "no DNS peer wait: $out"
grep -q 'no DNS peer answered within 2s; not stopping adguardhome' <<<"$out" || fail "DNS peer wait not bounded: $out"
grep -q 'raw copy with adguardhome running (may be inconsistent): adguard/work/data/stats.db' <<<"$out" \
  || fail "AdGuard files not copied live: $out"
[[ "$(<"$DOCKER_LOG")" == $'stop filebrowser\nstart filebrowser' ]] \
  || fail "AdGuard stopped without a DNS peer: $(<"$DOCKER_LOG")"

# A failed `docker ps` or `docker inspect` must fail the backup, never be read
# as "no running owner" and copy a live BoltDB file.
for failure in ps inspect; do
  : >"$DOCKER_LOG"
  : >"$tmp/restic.log"
  if out="$(DOCKER_FAIL=$failure PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
    fail "docker $failure failure did not fail the backup: $out"
  fi
  grep -q 'cannot tell which container owns' <<<"$out" || fail "docker $failure failure not reported: $out"
  if grep -q 'no running owner' <<<"$out"; then fail "docker $failure failure read as no owner: $out"; fi
  if grep -q '^backup ' "$tmp/restic.log"; then fail "snapshot taken after docker $failure failed"; fi
  [[ "$(jq -r '.status' "$server/backup/status/backup-status.json")" == failed ]] \
    || fail "docker $failure failure not recorded as failed"
done
# A container vanishing between ps and inspect is retried, not fatal.
: >"$DOCKER_LOG"
rm -f "$DOCKER_LOG.inspected"
out="$(DOCKER_FAIL=inspect-once PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "a single failed docker inspect was not retried: $out"
grep -q 'raw copy with filebrowser stopped' <<<"$out" || fail "owner not stopped after an inspect retry: $out"
# Mounts printed by a failed inspect must not outlive it: when the retry finds
# no running containers, nothing is stopped or started.
: >"$DOCKER_LOG"
rm -f "$DOCKER_LOG.inspected"
out="$(DOCKER_FAIL=partial-then-empty PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "an empty retry after a partial inspect failed the backup: $out"
[[ ! -s "$DOCKER_LOG" ]] || fail "stale inspect output stopped a container: $(<"$DOCKER_LOG")"
grep -q 'no running owner' <<<"$out" || fail "empty retry not reported as no owner: $out"
# A container that bind-mounts the database file itself owns it too.
: >"$DOCKER_LOG"
out="$(FB_FILE_MOUNT=1 PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "file-mounted BoltDB run failed: $out"
grep -q 'raw copy with filebrowser stopped: filebrowser/database/filebrowser.db' <<<"$out" \
  || fail "owner of a file-mounted BoltDB not stopped: $out"

# A failed database or .env scan must fail the run before any snapshot or
# prune, not back up (and prune) without the files it missed.
find_fail="$tmp/find-fail"
mkdir -p "$find_fail"
cat >"$find_fail/find" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  [[ "\$arg" == "\$FIND_FAIL_ON" ]] && { $(command -v find) "\$@"; exit 1; }
done
exec $(command -v find) "\$@"
EOF
chmod +x "$find_fail/find"
for scan in '*.sqlite3' .env; do
  : >"$DOCKER_LOG"
  : >"$tmp/restic.log"
  if out="$(FIND_FAIL_ON="$scan" PATH="$find_fail:$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
    fail "a failed $scan scan did not fail the backup: $out"
  fi
  grep -q "cannot list $([[ $scan == .env ]] && printf %s "$server" || printf %s "$tmp")" <<<"$out" \
    || fail "failed $scan scan not reported: $out"
  if grep -qE '^(backup|forget)' "$tmp/restic.log"; then fail "snapshot or prune after a failed $scan scan"; fi
  [[ "$(jq -r '.status' "$server/backup/status/backup-status.json")" == failed ]] \
    || fail "failed $scan scan not recorded as failed"
done
[[ ! -e "$tmp/staging" ]] || fail "staging dir left behind after a failed scan"

# The same for every other check whose failure used to be read as an answer:
# a docker CLI missing from PATH is not "no running owner", a failed owner
# listing is not "no owners", and a failed dig is not a DNS peer answering.
# Bash's PATH lookup cannot be made to skip a directory that also holds bash,
# so the engine's `command -v docker` is answered by a function exported in
# the environment instead.
nodocker_env=(env "BASH_FUNC_command%%=() { if [[ \$1 == -v && \$2 == docker ]]; then return 1; fi; builtin command \"\$@\"; }")
: >"$tmp/restic.log"
if out="$("${nodocker_env[@]}" PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
  fail "a missing docker CLI was read as no database owner: $out"
fi
grep -q 'docker missing' <<<"$out" || fail "missing docker not reported: $out"
if grep -qE '^(backup|forget)' "$tmp/restic.log"; then fail "snapshot or prune without a docker CLI"; fi

badsort="$tmp/badsort"
mkdir -p "$badsort"
printf '#!/usr/bin/env bash\nexit 1\n' >"$badsort/sort"
chmod +x "$badsort/sort"
: >"$DOCKER_LOG"
: >"$tmp/restic.log"
if out="$(PATH="$badsort:$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
  fail "a failed owner listing skipped the consistent copies: $out"
fi
grep -q 'cannot list the containers that own raw database copies' <<<"$out" || fail "failed owner listing not reported: $out"
[[ ! -s "$DOCKER_LOG" ]] || fail "containers stopped after a failed owner listing: $(<"$DOCKER_LOG")"
if grep -qE '^(backup|forget)' "$tmp/restic.log"; then fail "snapshot or prune after a failed owner listing"; fi

baddig="$tmp/baddig"
mkdir -p "$baddig"
printf '#!/usr/bin/env bash\nprintf "93.184.215.14\\n"\nexit 9\n' >"$baddig/dig"
chmod +x "$baddig/dig"
: >"$DOCKER_LOG"
out="$(PATH="$baddig:$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "run with a failing dig failed: $out"
grep -q 'not stopping adguardhome' <<<"$out" || fail "a failed dig counted as a DNS peer answering: $out"
[[ "$(<"$DOCKER_LOG")" == $'stop filebrowser\nstart filebrowser' ]] \
  || fail "AdGuard stopped on a failed dig: $(<"$DOCKER_LOG")"

# Once the player-log dir is backed up, its lock must exist and be root-owned 0600.
mkdir -p "$player_log"
if out="$(PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
  fail "missing shared lock did not stop the backup"
fi
grep -q 'shared backup lock is missing' <<<"$out" || fail "missing shared lock not reported: $out"
touch "$player_log/.backup.lock"
chmod 644 "$player_log/.backup.lock"
if [[ "$(id -u)" != 0 ]] \
  && out="$(PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)"; then
  fail "non-root shared lock did not stop the backup"
fi
rm -rf "$player_log"

# An SFTP second repo (no SECOND_BACKUP_MOUNT) that is unreachable is never initialized.
cat >"$stub/restic" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RESTIC_LOG"
case "$*" in
  *"-r sftp:"*"cat config"*) exit 1 ;;
  *"snapshots latest"*) printf '[{"short_id":"abc12345"}]\n' ;;
  *stats*) printf '{"total_size":2048}\n' ;;
esac
STUB
sed -i.bak -e 's|^SECOND_RESTIC_REPOSITORY=.*|SECOND_RESTIC_REPOSITORY=sftp:target:/copy|' \
  -e 's|^SECOND_BACKUP_MOUNT=.*|SECOND_BACKUP_MOUNT=|' "$server/backup/.env"
: >"$tmp/restic.log"
out="$(PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" 2>&1)" \
  || fail "sftp second-repo run failed: $out"
if grep -q 'sftp:target:/copy init' "$tmp/restic.log"; then fail "unreachable SFTP second repo was initialized"; fi
grep -q 'second copy incomplete' <<<"$out" || fail "unreachable SFTP second repo not reported"

# The local-drive guard refuses an unlabelled target.
rm "$drive/.backup-target-ok"
if PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" >/dev/null 2>&1; then
  fail "missing sentinel did not stop the backup"
fi

# Every host's sources.sh must source cleanly under errexit on a bare checkout.
for host in linux-server linux-pi linux-game-server macos-server; do
  (
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by the sourced sources.sh
    HOST_DIR="$tmp/bare-$host"
    # shellcheck disable=SC2034  # consumed by the sourced sources.sh
    CANDIDATES=()
    if [[ "$host" == linux-game-server || "$host" == linux-server ]]; then
      # shellcheck disable=SC2034  # consumed by the sourced backup sources.sh
      BACKUP_DRAGONWILDS_INSTALL_DIR="$HOST_DIR/no-game"
    fi
    if [[ "$host" == linux-server || "$host" == linux-game-server ]]; then
      # shellcheck disable=SC2329  # invoked indirectly by the sourced sources.sh
      systemctl() {
        if [[ "$*" == *LoadState* ]]; then printf 'loaded\n'; else printf '%s\n' "$BACKUP_DRAGONWILDS_INSTALL_DIR"; fi
      }
    fi
    if [[ "$host" == linux-server ]]; then
      # shellcheck disable=SC2034  # consumed by the sourced backup sources.sh
      BACKUP_FORGEJO_DATA_PATH="$HOST_DIR/forgejo/data"
    fi
    # shellcheck disable=SC2329  # invoked indirectly by the sourced sources.sh
    log() { :; }
    # shellcheck disable=SC2329  # invoked indirectly by the sourced sources.sh
    die() { exit 1; }
    # shellcheck disable=SC2329  # invoked indirectly by the sourced sources.sh
    env_value() { :; }
    # shellcheck source=/dev/null
    source "$REPO/$host/backup/sources.sh"
    # shellcheck disable=SC2034  # consumed by resolve_sources
    BACKUP_WORLD_MARKER="$HOST_DIR/world-seen"
    # The Mac's backup is a launchd agent, not a systemd service.
    [[ -n "$BACKUP_NAME" && -n "$BACKUP_LABEL" && ( "$BACKUP_UNIT" == *.service || "$host" == macos-server ) ]]
    resolve_sources
  ) || fail "$host/backup/sources.sh does not source cleanly"
done

# Mac mini (runs as the login user): Hermes databases are staged with SQLite's
# online backup, the install inventory is recorded, and a failure alert points
# at the launchd log instead of journalctl.
mac="$(make_host mac macos-server)"
mac_home="$tmp/mac-home"
mkdir -p "$mac_home/.hermes/skills" "$mac_home/Library/LaunchAgents" "$mac/homepage/config"
printf 'SQLite format 3\0x' >"$mac_home/.hermes/state.db"
printf 'model: x\n' >"$mac_home/.hermes/config.yaml"
mac_stub="$tmp/mac-stub"
mkdir -p "$mac_stub"
for tool in sw_vers pmset launchctl brew; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$MAC_TOOL_LOG"\n' >"$mac_stub/$tool"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$CURL_LOG"\n' >"$mac_stub/curl"
chmod +x "$mac_stub"/*
printf 'RESTIC_REPOSITORY=sftp:mac-backup-target:/primary\nRESTIC_PASSWORD=test\n' >"$mac/backup/.env"
rm -f "$tmp/restic.log"
out="$(HOME="$mac_home" PATH="$mac_stub:$stub:$PATH" RESTIC_LOG="$tmp/restic.log" MAC_TOOL_LOG="$tmp/mac-tools.log" \
  bash "$mac/backup/backup.sh" 2>&1)" || fail "mac run failed: $out"
backup_line="$(grep '^backup ' "$tmp/restic.log")"
for want in "$mac_home/.hermes/config.yaml" "$mac_home/.hermes/skills" "$mac_home/Library/LaunchAgents" \
            "$mac/homepage/config" "$mac_home/Library/Caches/computer-setup/mac-backup-staging" "--tag mac-nightly"; do
  [[ "$backup_line" == *"$want"* ]] || fail "mac restic backup missing $want: $backup_line"
done
[[ "$backup_line" != *"$mac_home/.hermes "* ]] || fail "mac backup took all of ~/.hermes: $backup_line"
[[ "$out" == *"sqlite snapshot: ~/.hermes/state.db"* ]] || fail "mac Hermes database not staged: $out"
grep -q '^bundle dump' "$tmp/mac-tools.log" || fail "mac Brewfile inventory not recorded"
[[ "$(jq -r .status "$mac/status/www/backup-status.json")" == success ]] || fail "mac status JSON not written"
HOME="$mac_home" PATH="$mac_stub:$stub:$PATH" CURL_LOG="$tmp/curl.log" NTFY_URL=https://ntfy.example \
  bash "$mac/backup/backup.sh" notify-failure 2>/dev/null || fail "mac notifier failed"
grep -q 'launchd run failed' "$tmp/curl.log" || fail "mac failure alert lacks the launchd log hint"

# A repointed game path must fail rather than backing up a different tree.
if bash -c '
  set -euo pipefail
  HOST_DIR="$1"
  BACKUP_DRAGONWILDS_INSTALL_DIR="$1/world-a"
  CANDIDATES=()
  log() { :; }
  die() { return 1; }
  systemctl() { printf "%s/world-b\\n" "$1"; }
  source "$2/linux-game-server/backup/sources.sh"
  BACKUP_WORLD_MARKER="$1/world-seen"
  resolve_sources
' bash "$tmp/path-drift" "$REPO" >/dev/null 2>&1; then
  fail "game backup accepted a path drift from dragonwilds.service"
fi

# Once a backup has seen a world, an empty SaveGames fails the backup instead of
# succeeding (and pruning) without it. A fresh install with no marker still passes.
game_world() {
  bash -c '
    set -euo pipefail
    HOST_DIR="$1"
    BACKUP_DRAGONWILDS_INSTALL_DIR="$1/game"
    CANDIDATES=()
    log() { :; }
    die() { printf "%s\n" "$*" >&2; exit 1; }
    systemctl() { printf "%s\n" "$BACKUP_DRAGONWILDS_INSTALL_DIR"; }
    source "$2/linux-game-server/backup/sources.sh"
    BACKUP_WORLD_MARKER="$1/world-seen"
    resolve_sources
    printf "world_exists=%s\n" "$world_exists"
    printf "candidates=%s\n" "${CANDIDATES[*]}"
  ' bash "$tmp/world-marker" "$REPO" 2>&1
}
wm="$tmp/world-marker"
mkdir -p "$wm/game/RSDragonwilds/Saved/SaveGames"
out="$(game_world)" || fail "fresh install without a world failed: $out"
[[ "$out" == *world_exists=false* && ! -e "$wm/world-seen" ]] || fail "fresh install wrote the world marker: $out"
touch "$wm/game/RSDragonwilds/Saved/SaveGames/Main.sav"
out="$(game_world)" || fail "first world backup failed: $out"
[[ "$out" == *world_exists=true* && -s "$wm/world-seen" ]] || fail "world marker not written: $out"
grep -q "candidates=.*$wm/world-seen" <<<"$out" || fail "game world marker not backed up: $out"
rm "$wm/game/RSDragonwilds/Saved/SaveGames/Main.sav"
if out="$(game_world)"; then fail "lost world backed up as a success: $out"; fi
grep -q 'one was backed up before' <<<"$out" || fail "lost world failed for the wrong reason: $out"
rm "$wm/world-seen"
out="$(game_world)" || fail "deleting the marker did not accept the empty world: $out"

# Main server: the path cross-check binds while it runs the game, and is skipped
# once dragonwilds.service is gone (old saves are still backed up).
main_server_resolve() {
  bash -c '
    set -euo pipefail
    HOST_DIR="$1"
    load_state="$3"
    BACKUP_DRAGONWILDS_INSTALL_DIR="$1/world-a"
    BACKUP_FORGEJO_DATA_PATH="$1/forgejo/data"
    CANDIDATES=()
    log() { :; }
    die() { exit 1; }
    systemctl() {
      if [[ "$*" == *LoadState* ]]; then printf "%s\n" "$load_state"; else printf "%s/world-b\n" "$HOST_DIR"; fi
    }
    source "$2/linux-server/backup/sources.sh"
    BACKUP_WORLD_MARKER="$1/world-seen"
    resolve_sources
    printf "%s\n" "${CANDIDATES[@]}"
  ' bash "$tmp/main-drift" "$REPO" "$1"
}
mkdir -p "$tmp/main-drift/world-a/RSDragonwilds/Saved/SaveGames"
if main_server_resolve loaded >/dev/null 2>&1; then
  fail "main-server backup accepted a path drift from a loaded dragonwilds.service"
fi
main_out="$(main_server_resolve not-found 2>&1)" || fail "main-server backup failed without dragonwilds.service: $main_out"
grep -q "world-a/RSDragonwilds/Saved/SaveGames" <<<"$main_out" \
  || fail "main-server backup dropped the old Dragonwilds saves: $main_out"

# The main server keeps the same world marker: once it has backed up a world,
# an empty SaveGames or an unconfigured install fails, whether or not it still
# runs the game. A server that never had a world is unaffected. The marker is
# backed up so a full restore carries it.
main_world() {
  bash -c '
    set -euo pipefail
    HOST_DIR="$1"
    load_state="$3"
    BACKUP_DRAGONWILDS_INSTALL_DIR="$4"
    BACKUP_FORGEJO_DATA_PATH="$1/forgejo/data"
    CANDIDATES=()
    log() { printf "%s\n" "$*" >&2; }
    die() { printf "%s\n" "$*" >&2; exit 1; }
    systemctl() {
      if [[ "$*" == *LoadState* ]]; then printf "%s\n" "$load_state"; else printf "%s\n" "$BACKUP_DRAGONWILDS_INSTALL_DIR"; fi
    }
    source "$2/linux-server/backup/sources.sh"
    BACKUP_WORLD_MARKER="$1/marker/world-seen"
    resolve_sources
    printf "%s\n" "${CANDIDATES[@]}"
  ' bash "$tmp/main-world" "$REPO" "$1" "${2-$tmp/main-world/game}" 2>&1
}
mw="$tmp/main-world"
mkdir -p "$mw/game/RSDragonwilds/Saved/SaveGames" "$mw/game/RSDragonwilds/Saved/Config/LinuxServer"
printf '[/Script/Dominion.DedicatedServerSettings]\nDefaultWorldName=Main\n' \
  >"$mw/game/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
out="$(main_world not-found '')" || fail "main server without Dragonwilds failed: $out"
out="$(main_world loaded)" || fail "main server with an empty fresh install failed: $out"
[[ ! -e "$mw/marker/world-seen" ]] || fail "main server wrote the world marker without a world"
touch "$mw/game/RSDragonwilds/Saved/SaveGames/Main.sav"
out="$(main_world loaded)" || fail "main server first world failed: $out"
[[ "$(<"$mw/marker/world-seen")" == "$mw/game/RSDragonwilds/Saved/SaveGames" ]] || fail "main world marker not written"
grep -qx "$mw/marker/world-seen" <<<"$out" || fail "main world marker not backed up: $out"
rm "$mw/game/RSDragonwilds/Saved/SaveGames/Main.sav"
for state in loaded not-found; do
  if out="$(main_world "$state")"; then fail "main server ($state) backed up a lost world: $out"; fi
  grep -q 'one was backed up before' <<<"$out" || fail "main lost world ($state) failed for the wrong reason: $out"
done
rm -r "$mw/game/RSDragonwilds/Saved/SaveGames"
if out="$(main_world not-found)"; then fail "main server backed up a missing SaveGames: $out"; fi
if out="$(main_world not-found '')"; then fail "main server ignored the marker with no install path: $out"; fi
grep -q 'BACKUP_DRAGONWILDS_INSTALL_DIR is empty' <<<"$out" || fail "unconfigured install failed for the wrong reason: $out"
# A world at another path is backed up, with a warning that the source moved.
mkdir -p "$mw/moved/RSDragonwilds/Saved/SaveGames" "$mw/moved/RSDragonwilds/Saved/Config/LinuxServer"
cp "$mw/game/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini" "$mw/moved/RSDragonwilds/Saved/Config/LinuxServer/"
touch "$mw/moved/RSDragonwilds/Saved/SaveGames/Main.sav"
out="$(main_world not-found "$mw/moved")" || fail "main world at a new path failed: $out"
grep -q 'first backed up from' <<<"$out" || fail "moved world source not warned about: $out"
rm "$mw/marker/world-seen"
out="$(main_world not-found '')" || fail "deleting the marker did not retire the main-server world: $out"

# A changed root-owned helper must fail its pinned-hash check before Python runs.
bundle="$tmp/root-bundle"
mkdir -p "$bundle"
printf '#!/usr/bin/env python3\\n' >"$bundle/backup-save.py"
if bash -c '
  set -euo pipefail
  SCRIPT_DIR="$1"
  HOST_DIR="$2"
  BACKUP_DRAGONWILDS_INSTALL_DIR="$2/world"
  BACKUP_SAVE_SCRIPT="$1/backup-save.py"
  BACKUP_SAVE_SCRIPT_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  STAGING_DIR="$2/staging"
  source "$3/linux-game-server/backup/sources.sh"
  log() { :; }
  die() { return 1; }
  world_exists=true
  saved="$2/world/RSDragonwilds/Saved"
  install_dir="$2/world"
  stage_extra
' bash "$bundle" "$tmp/hash-test" "$REPO" >/dev/null 2>&1; then
  fail "game backup accepted a changed helper hash"
fi

# A main-server Dragonwilds save without its config must fail the source
# resolver, rather than silently backing up only the .sav and reporting success.
invalid_server="$tmp/server-invalid"
mkdir -p "$invalid_server/dragonwilds/games/dragonwilds/RSDragonwilds/Saved/SaveGames"
printf 'DRAGONWILDS_INSTALL_DIR=%s\n' "$invalid_server/dragonwilds/games/dragonwilds" \
  >"$invalid_server/dragonwilds/.env"
touch "$invalid_server/dragonwilds/games/dragonwilds/RSDragonwilds/Saved/SaveGames/Main.sav"
main_world_resolve() {
  bash -c '
    set -euo pipefail
    HOST_DIR="$1"
    BACKUP_DRAGONWILDS_INSTALL_DIR="$1/dragonwilds/games/dragonwilds"
    BACKUP_FORGEJO_DATA_PATH="$1/forgejo/data"
    CANDIDATES=()
    log() { :; }
    die() { printf "%s\n" "$*" >&2; exit 1; }
    systemctl() { printf "not-found\n"; }
    env_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
    source "$2/linux-server/backup/sources.sh"
    BACKUP_WORLD_MARKER="$1/world-seen"
    resolve_sources
    printf "%s\n" "${CANDIDATES[@]}"
  ' bash "$invalid_server" "$REPO"
}
if main_out="$(main_world_resolve 2>&1)"; then
  fail "main Dragonwilds backup accepted a save without DedicatedServer.ini"
fi
grep -q 'Dragonwilds save exists but DedicatedServer.ini is missing' <<<"$main_out" \
  || fail "main-world guard failed for the wrong reason: $main_out"
mkdir -p "$invalid_server/dragonwilds/games/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer"
printf '[/Script/Dominion.DedicatedServerSettings]\nDefaultWorldName=Main\n' \
  >"$invalid_server/dragonwilds/games/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
main_out="$(main_world_resolve 2>&1)" || fail "valid main world rejected: $main_out"
grep -q '/Saved/SaveGames' <<<"$main_out" || fail "valid main world omitted from sources: $main_out"
printf '[/Script/Dominion.DedicatedServerSettings]\nDefaultWorldName=Missing\n' \
  >"$invalid_server/dragonwilds/games/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini"
if main_out="$(main_world_resolve 2>&1)"; then fail "main world accepted a missing configured save"; fi
grep -q 'invalid Dragonwilds config/world' <<<"$main_out" || fail "missing configured save failed for the wrong reason: $main_out"

# An unreachable SFTP primary fails the run instead of trying `restic init`.
cat >"$server/backup/.env" <<EOF2
RESTIC_REPOSITORY=sftp:target:/primary
RESTIC_PASSWORD=test
BACKUP_MOUNT=$drive
STAGING_DIR=$tmp/staging
BACKUP_DRAGONWILDS_INSTALL_DIR=$server/dragonwilds/games/dragonwilds
BACKUP_FORGEJO_DATA_PATH=$tmp/forgejo-data
EOF2
touch "$drive/.backup-target-ok"
# shellcheck disable=SC2016  # the generated stub expands RESTIC_LOG at runtime
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$RESTIC_LOG"\nexit 1\n' >"$stub/restic"
: >"$tmp/restic.log"
if PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" >/dev/null 2>&1; then
  fail "unreachable SFTP primary did not fail the run"
fi
if grep -q '^init' "$tmp/restic.log"; then fail "unreachable SFTP primary was initialized"; fi

# Every host's .env.example must survive `source` (sftp-client.sh sources a
# fresh copy before the user edits it): no bare < > placeholders.
for example in "$REPO"/linux-*/backup/.env.example; do
  # shellcheck source=/dev/null
  (cd "$tmp" && set -a && source "$example") 2>/dev/null || fail "$example is not safe to source"
done

# setup.sh --dry-run prints its plan and writes nothing, not even a scratch dir.
nowrite="$tmp/nowrite-bin"
mkdir -p "$nowrite"
for tool in mktemp install systemctl systemd-analyze; do
  printf '#!/usr/bin/env bash\nprintf "dry-run ran %s\\n" >&2\nexit 75\n' "$tool" >"$nowrite/$tool"
  chmod +x "$nowrite/$tool"
done
for host in linux-server linux-pi linux-game-server; do
  out="$(PATH="$nowrite:$PATH" bash "$REPO/$host/backup/setup.sh" --dry-run 2>&1)" \
    || fail "$host setup.sh --dry-run wrote or executed something: $out"
  [[ "$out" == *"[dry-run] systemctl enable --now"* ]] || fail "$host setup.sh --dry-run did not print its plan"
done

# setup.sh --verify renders and checks every host's units without installing,
# and rejects a broken template or sources.sh before anything is installed.
for host in linux-server linux-pi linux-game-server; do
  out="$(bash "$REPO/$host/backup/setup.sh" --verify 2>&1)" || fail "$host setup.sh --verify failed: $out"
done
bad="$tmp/badsetup"
mkdir -p "$bad/backup"
cp "$REPO/linux-pi/backup/"{sources.sh,pi-backup.timer,pi-backup-failure.service.template} "$bad/backup/"
cp "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/backup.sh" "$bad/backup/"
for typo in @BACKUP_SCRIPT_TYPO@ @BACKUP_SCRIPT2@ @Backup_script@; do
  sed "s/@BACKUP_SCRIPT@/$typo/" "$REPO/linux-pi/backup/pi-backup.service.template" \
    >"$bad/backup/pi-backup.service.template"
  if bash "$bad/backup/setup.sh" --verify >/dev/null 2>&1; then fail "--verify accepted unrendered $typo"; fi
done
{
  cat "$REPO/linux-pi/backup/pi-backup.service.template"
  printf '# Wants=foo@.service; operator@example.test\n'
} >"$bad/backup/pi-backup.service.template"
bash "$bad/backup/setup.sh" --verify >/dev/null 2>&1 || fail "--verify rejected a lone @ that is not a placeholder"
cp "$REPO/linux-pi/backup/pi-backup.service.template" "$bad/backup/"
bash "$bad/backup/setup.sh" --verify >/dev/null 2>&1 || fail "--verify rejected the restored template"
printf 'if then\n' >>"$bad/backup/sources.sh"
if bash "$bad/backup/setup.sh" --verify >/dev/null 2>&1; then fail "--verify accepted a broken sources.sh"; fi

# A dropped substitution for a digit-bearing placeholder is caught too.
gbad="$tmp/badsetup-game"
mkdir -p "$gbad/backup" "$gbad/dragonwilds"
cp "$REPO/linux-game-server/backup/"{sources.sh,game-backup.timer,game-backup.service.template,game-backup-failure.service.template} "$gbad/backup/"
cp "$REPO/linux-game-server/dragonwilds/backup-save.py" "$gbad/dragonwilds/"
cp "$SCRIPT_DIR/backup.sh" "$gbad/backup/"
cp "$SCRIPT_DIR/setup.sh" "$gbad/backup/"
bash "$gbad/backup/setup.sh" --verify >/dev/null 2>&1 || fail "--verify rejected the game fixture"
sed -i.orig '/@BACKUP_SAVE_SCRIPT_SHA256@|/d' "$gbad/backup/setup.sh"
if bash "$gbad/backup/setup.sh" --verify >/dev/null 2>&1; then
  fail "--verify accepted an unrendered @BACKUP_SAVE_SCRIPT_SHA256@"
fi

# notify-failure never executes sources.sh: a broken or missing one still
# records the failure and alerts.
for state in broken missing; do
  nh="$tmp/notify-$state"
  mkdir -p "$nh/backup"
  ln -s "$SCRIPT_DIR/backup.sh" "$nh/backup/backup.sh"
  if [[ "$state" == broken ]]; then
    printf 'BACKUP_NAME=pi\nBACKUP_LABEL=Pi\nBACKUP_UNIT=pi-backup.service\nif then\n' >"$nh/backup/sources.sh"
  fi
  rm -f "$tmp/notify.status" "$tmp/notify.calls"
  # shellcheck disable=SC2016  # the stub expands its own arguments
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$tmp/notify.calls" >"$stub/curl"
  chmod +x "$stub/curl"
  PATH="$stub:$PATH" STATUS_JSON="$tmp/notify.status" NTFY_URL=https://ntfy.example NTFY_TOPIC=t KUMA_PUSH_URL='' \
    bash "$nh/backup/backup.sh" notify-failure >/dev/null 2>&1 || fail "notify-failure exited non-zero with a $state sources.sh"
  [[ "$(jq -r .status "$tmp/notify.status")" == failed ]] || fail "notify-failure did not record a $state-sources failure"
  grep -q 'backup FAILED' "$tmp/notify.calls" || fail "notify-failure did not alert with a $state sources.sh"
  [[ "$state" == missing ]] || grep -q 'Title: Pi backup FAILED' "$tmp/notify.calls" \
    || fail "notify-failure lost the label of a broken sources.sh"
done

# restore-check never reports PASSED when a verification step could not run:
# a failed scan of the restored tree, or sqlite3 printing "ok" then failing.
rc="$tmp/restore-check"
mkdir -p "$rc/bin" "$rc/root" "$rc/host/backup"
printf 'RESTIC_REPOSITORY=/nonexistent\n' >"$rc/host/backup/.env"
sed -e 's|\[\[ "\$EUID" -eq 0 \]\]|true|' -e "s|^scratch_parent=/root|scratch_parent=$rc/root|" \
  "$SCRIPT_DIR/restore-check.sh" >"$rc/restore-check.sh"
grep -q "scratch_parent=$rc/root" "$rc/restore-check.sh" || fail "restore-check fixture did not redirect scratch"
cat >"$rc/bin/restic" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  snapshots) printf '[{"short_id":"abcdef","time":"2026-10-18T00:00:00"}]' ;;
  stats) printf '{"total_size":10}' ;;
  ls) printf '{"type":"file"}\n{"type":"file"}\n' ;;
  restore)
    t="$4"; mkdir -p "$t/x-staging/sqlite"
    printf 'SQLite format 3\0' >"$t/x-staging/sqlite/db.sqlitebak"
    (cd "$t/x-staging/sqlite" && sha256sum db.sqlitebak >db.sqlitebak.sha256) ;;
esac
EOF
cat >"$rc/bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
printf 'ok\n'
exit "${SQLITE_EXIT:-0}"
EOF
real_find="$(command -v find)"
cat >"$rc/bin/find" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" != "\${RC_FIND_FAIL:-none}" ]] || { "$real_find" "\$@"; exit 1; }; done
exec "$real_find" "\$@"
EOF
chmod +x "$rc/bin/"*
out="$(PATH="$rc/bin:$PATH" bash "$rc/restore-check.sh" "$rc/host" 2>&1)" || fail "restore-check control failed: $out"
grep -q 'integrity_check: 1' <<<"$out" && grep -q 'verified: 1' <<<"$out" && grep -q PASSED <<<"$out" \
  || fail "restore-check control did not verify both checks: $out"
for scan in '*-staging/sqlite/*' '*.sha256'; do
  if out="$(RC_FIND_FAIL="$scan" PATH="$rc/bin:$PATH" bash "$rc/restore-check.sh" "$rc/host" 2>&1)"; then
    fail "restore-check passed after its $scan scan failed: $out"
  fi
  if grep -q PASSED <<<"$out"; then fail "restore-check printed PASSED after its $scan scan failed"; fi
  grep -q 'cannot scan the restored tree' <<<"$out" || fail "failed $scan scan not reported: $out"
done
if out="$(SQLITE_EXIT=1 PATH="$rc/bin:$PATH" bash "$rc/restore-check.sh" "$rc/host" 2>&1)"; then
  fail "restore-check accepted ok from a failing sqlite3: $out"
fi
grep -q 'integrity_check failed' <<<"$out" || fail "failing sqlite3 not reported: $out"
[[ -z "$(ls -A "$rc/root")" ]] || fail "restore-check left scratch behind: $(ls -A "$rc/root")"

printf 'backup engine tests: PASSED\n'
