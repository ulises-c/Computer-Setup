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
dest="${2#.backup \'}"; cp "$1" "${dest%\'}"
EOF
cat >"$stub/mountpoint" <<'EOF'
#!/usr/bin/env bash
[[ "$2" != */unmounted ]]
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/docker"
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
printf 'x' >"$server/uptime-kuma/data/kuma.db"
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
grep -q 'second copy incomplete' <<<"$out" || fail "unmounted second drive not reported"
if grep -q '^init' "$tmp/restic.log"; then fail "second repo initialized on an unmounted drive"; fi
[[ "$(jq -r '.status' "$server/backup/status/backup-status.json")" == success ]] || fail "status not success"
[[ "$(jq -r '.snapshot' "$server/backup/status/backup-status.json")" == abc12345 ]] || fail "snapshot id not recorded"
[[ ! -e "$tmp/staging" ]] || fail "staging dir left behind"
grep -q 'skipping coordination' <<<"$out" || fail "absent player-log dir did not skip lock coordination"

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
for host in linux-server linux-pi linux-game-server; do
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
    [[ -n "$BACKUP_NAME" && -n "$BACKUP_LABEL" && "$BACKUP_UNIT" == *.service ]]
    resolve_sources
  ) || fail "$host/backup/sources.sh does not source cleanly"
done

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
  resolve_sources
' bash "$tmp/path-drift" "$REPO" >/dev/null 2>&1; then
  fail "game backup accepted a path drift from dragonwilds.service"
fi

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
if bash -c '
  set -euo pipefail
  HOST_DIR="$1"
  BACKUP_DRAGONWILDS_INSTALL_DIR="$1/dragonwilds/games/dragonwilds"
  CANDIDATES=()
  log() { :; }
  die() { printf "%s\\n" "$*" >&2; return 1; }
  env_value() { sed -n "s/^$2=//p" "$1" | tail -1; }
  source "$2/linux-server/backup/sources.sh"
  resolve_sources
' bash "$invalid_server" "$REPO" >/dev/null 2>&1; then
  fail "main Dragonwilds backup accepted a save without DedicatedServer.ini"
fi

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

printf 'backup engine tests: PASSED\n'
