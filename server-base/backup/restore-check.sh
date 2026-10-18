#!/usr/bin/env bash
set -Eeuo pipefail

# Restore check: restores a host's latest snapshot into a root-only scratch dir
# and verifies it without touching live data. Checks the repository structure,
# that every file in the snapshot came back, that staged SQLite snapshots pass
# integrity_check, and that staged files with a .sha256 sidecar match it.
#
# Usage: sudo bash server-base/backup/restore-check.sh <host-dir> [--second] [--keep]
#   <host-dir>  linux-server, linux-game-server or linux-pi (its backup/.env is used)
#   --second    check SECOND_RESTIC_REPOSITORY instead of the primary
#   --keep      leave the restored tree in place for inspection

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
trap 'printf "error: restore-check stopped at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR
log() { printf '[restore-check] %s\n' "$*"; }

host_dir="" second=false keep=false
for arg in "$@"; do
  case "$arg" in
    --second) second=true ;;
    --keep) keep=true ;;
    -*) die "unknown option: $arg" ;;
    *) host_dir="$arg" ;;
  esac
done
[[ -n "$host_dir" ]] || die "usage: $0 <host-dir> [--second] [--keep]"
[[ "$EUID" -eq 0 ]] || die "run with sudo (repositories are reached as root)"
env_file="$host_dir/backup/.env"
[[ -f "$env_file" ]] || die "missing $env_file"
for tool in restic jq; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
if [[ "$second" == true ]]; then
  [[ -n "${SECOND_RESTIC_REPOSITORY:-}" ]] || die "SECOND_RESTIC_REPOSITORY is not set"
  export RESTIC_REPOSITORY="$SECOND_RESTIC_REPOSITORY"
fi
[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set"
# The staging dir the engine uses, worked out the same way backup.sh does.
backup_name="$(sed -n 's/^BACKUP_NAME=//p' "$host_dir/backup/sources.sh")" \
  || die "cannot read BACKUP_NAME from $host_dir/backup/sources.sh"
backup_name="${backup_name##*$'\n'}"
[[ "$backup_name" =~ ^[a-z][a-z-]*$ ]] || die "bad BACKUP_NAME in $host_dir/backup/sources.sh"
staging_dir="${STAGING_DIR:-/var/tmp/$backup_name-backup-staging}"
export HOME=/root
host="$(hostname)"

log "repository: $([[ "$second" == true ]] && printf second || printf primary)"
restic check >/dev/null || die "restic check failed"
log "restic check: no errors"

snapshot_json="$(restic snapshots latest --host "$host" --json)"
snapshot="$(jq -r '.[-1].short_id // empty' <<<"$snapshot_json")"
[[ -n "$snapshot" ]] || die "no snapshot for host $host"
log "snapshot $snapshot from $(jq -r '.[-1].time' <<<"$snapshot_json" | cut -c1-19)"

want_bytes="$(restic stats "$snapshot" --mode restore-size --json | jq -r '.total_size')"
# restore-size's total_file_count also counts directories; compare regular files only.
want_files="$(restic ls "$snapshot" --json | jq -s '[.[] | select(.type == "file")] | length')"

scratch_parent=/root
free_kb="$(df -Pk "$scratch_parent" | awk 'NR==2 {print $4}')"
(( free_kb * 1024 > want_bytes * 11 / 10 )) || die "not enough space under $scratch_parent for $want_bytes bytes"
scratch="$(mktemp -d "$scratch_parent/restore-check.XXXXXX")"
scan_list=""
cleanup() { [[ -z "$scan_list" ]] || rm -f "$scan_list"; [[ "$keep" == true ]] || rm -rf "$scratch"; }
trap cleanup EXIT

restic restore "$snapshot" --target "$scratch" >/dev/null
got_files="$(find "$scratch" -type f | wc -l | tr -d ' ')"
(( got_files == want_files )) || die "restored $got_files files, snapshot has $want_files"
log "restored $got_files files ($want_bytes bytes)"

# Each scan goes to a checked list first: a failed find feeding the loop
# directly would leave the counts at zero and still print PASSED.
scan_list="$(mktemp "$scratch_parent/restore-check-scan.XXXXXX")"
scan_into_list() {
  find "$@" -print0 >"$scan_list" || die "cannot scan the restored tree; nothing was verified"
}

# Staged copies are verified only inside this host's staging dir, which must be
# one of the snapshot's own paths and carry the engine's marker. A backed-up
# service may hold its own *.sqlitebak, *.sha256 or .backup-staging; those are
# never judged and never stand in for the engine's.
in_snapshot="$(jq -r --arg p "$staging_dir" '.[-1].paths | index($p) != null' <<<"$snapshot_json")" \
  || die "cannot read the paths of snapshot $snapshot"
staging_root="$scratch$staging_dir"
[[ "$in_snapshot" == true && -f "$staging_root/.backup-staging" \
   && "$(<"$staging_root/.backup-staging")" == 'computer-setup backup staging' ]] \
  || die "snapshot $snapshot has no staging marker at $staging_dir (made by an older backup.sh, or STAGING_DIR changed since); run a backup, then check again"

checked=0 raw=0
scan_into_list "$staging_root" -name '*.sqlitebak' -type f
while IFS= read -r -d '' db; do
  # backup.sh falls back to a raw copy for non-SQLite *.db files (e.g. BoltDB),
  # still with the .sqlitebak suffix; only real SQLite files can be checked.
  # cmp exits 1 for a different header (or a file shorter than one) and 2 when
  # it cannot read; only the first means "not SQLite".
  rc=0
  cmp -s -n 16 "$db" <(printf 'SQLite format 3\0') || rc=$?
  case "$rc" in
    0) ;;
    1) log "raw copy, not SQLite (not checked): ${db#"$scratch"}"; raw=$((raw + 1)); continue ;;
    *) die "cannot read the header of ${db#"$scratch"}" ;;
  esac
  command -v sqlite3 >/dev/null || die "sqlite3 is required to verify ${db#"$scratch"} (apt install sqlite3)"
  if ! result="$(sqlite3 "file:$db?mode=ro" 'PRAGMA integrity_check;' 2>&1)" || [[ "$result" != ok ]]; then
    die "integrity_check failed for ${db#"$scratch"}: $(head -n1 <<<"$result")"
  fi
  checked=$((checked + 1))
done <"$scan_list"
log "sqlite snapshots passing integrity_check: $checked (raw non-SQLite copies: $raw)"

sums=0
scan_into_list "$staging_root" -name '*.sha256' -type f
while IFS= read -r -d '' sidecar; do
  (cd "$(dirname "$sidecar")" && sha256sum --quiet -c "$(basename "$sidecar")") \
    || die "checksum mismatch: ${sidecar#"$scratch"}"
  sums=$((sums + 1))
done <"$scan_list"
log "checksummed staged copies verified: $sums"

log "PASSED: snapshot $snapshot restores completely"
[[ "$keep" == true ]] && log "restored tree kept at $scratch"
exit 0
