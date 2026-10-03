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
chmod +x "$stub"/*

server="$(make_host server linux-server)"
drive="$tmp/drive"
mkdir -p "$drive" "$server/uptime-kuma/data" "$server/homepage/config" "$server/ntfy" "$server/forgejo" \
  "$tmp/forgejo-data"
touch "$drive/.backup-target-ok"
printf 'x' >"$server/uptime-kuma/data/kuma.db"
printf 'title: test\n' >"$server/homepage/config/settings.yaml"
printf 'FORGEJO_DATA_PATH="%s"\n' "$tmp/forgejo-data" >"$server/forgejo/.env"
printf 'NTFY_BASE_URL=x\n' >"$server/ntfy/.env"
cat >"$server/backup/.env" <<EOF
RESTIC_REPOSITORY=$drive/restic
RESTIC_PASSWORD=test
BACKUP_MOUNT=$drive
SECOND_RESTIC_REPOSITORY=$tmp/unmounted/restic-copy
SECOND_BACKUP_MOUNT=$tmp/unmounted
STAGING_DIR=$tmp/staging
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
    log() { :; }
    die() { exit 1; }
    env_value() { :; }
    # shellcheck source=/dev/null
    source "$REPO/$host/backup/sources.sh"
    [[ -n "$BACKUP_NAME" && -n "$BACKUP_LABEL" && "$BACKUP_UNIT" == *.service ]]
    resolve_sources
  ) || fail "$host/backup/sources.sh does not source cleanly"
done

# An unreachable SFTP primary fails the run instead of trying `restic init`.
cat >"$server/backup/.env" <<EOF2
RESTIC_REPOSITORY=sftp:target:/primary
RESTIC_PASSWORD=test
BACKUP_MOUNT=$drive
STAGING_DIR=$tmp/staging
EOF2
touch "$drive/.backup-target-ok"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$RESTIC_LOG"\nexit 1\n' >"$stub/restic"
: >"$tmp/restic.log"
if PATH="$stub:$PATH" RESTIC_LOG="$tmp/restic.log" bash "$server/backup/backup.sh" >/dev/null 2>&1; then
  fail "unreachable SFTP primary did not fail the run"
fi
if grep -q '^init' "$tmp/restic.log"; then fail "unreachable SFTP primary was initialized"; fi

printf 'backup engine tests: PASSED\n'
