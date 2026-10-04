#!/usr/bin/env bash
set -euo pipefail

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
export HOME=/root
host="$(hostname)"

log "repository: $([[ "$second" == true ]] && printf second || printf primary)"
restic check >/dev/null || die "restic check failed"
log "restic check: no errors"

snapshot_json="$(restic snapshots latest --host "$host" --json)"
snapshot="$(jq -r '.[-1].short_id // empty' <<<"$snapshot_json")"
[[ -n "$snapshot" ]] || die "no snapshot for host $host"
log "snapshot $snapshot from $(jq -r '.[-1].time' <<<"$snapshot_json" | cut -c1-19)"

stats="$(restic stats "$snapshot" --mode restore-size --json)"
want_files="$(jq -r '.total_file_count' <<<"$stats")"
want_bytes="$(jq -r '.total_size' <<<"$stats")"

scratch_parent=/root
free_kb="$(df -Pk "$scratch_parent" | awk 'NR==2 {print $4}')"
(( free_kb * 1024 > want_bytes * 11 / 10 )) || die "not enough space under $scratch_parent for $want_bytes bytes"
scratch="$(mktemp -d "$scratch_parent/restore-check.XXXXXX")"
cleanup() { [[ "$keep" == true ]] || rm -rf "$scratch"; }
trap cleanup EXIT

restic restore "$snapshot" --target "$scratch" >/dev/null
got_files="$(find "$scratch" -type f | wc -l | tr -d ' ')"
(( got_files == want_files )) || die "restored $got_files files, snapshot has $want_files"
log "restored $got_files files ($want_bytes bytes)"

checked=0
while IFS= read -r -d '' db; do
  if ! command -v sqlite3 >/dev/null; then
    log "sqlite3 not installed; skipping $(basename "$db")"
    continue
  fi
  result="$(sqlite3 "file:$db?mode=ro" 'PRAGMA integrity_check;' 2>&1 | head -1)"
  [[ "$result" == ok ]] || die "integrity_check failed for ${db#"$scratch"}: $result"
  checked=$((checked + 1))
done < <(find "$scratch" -path '*-staging/sqlite/*' -type f -print0)
log "sqlite snapshots passing integrity_check: $checked"

sums=0
while IFS= read -r -d '' sidecar; do
  (cd "$(dirname "$sidecar")" && sha256sum --quiet -c "$(basename "$sidecar")") \
    || die "checksum mismatch: ${sidecar#"$scratch"}"
  sums=$((sums + 1))
done < <(find "$scratch" -name '*.sha256' -type f -print0)
log "checksummed staged copies verified: $sums"

log "PASSED: snapshot $snapshot restores completely"
[[ "$keep" == true ]] && log "restored tree kept at $scratch"
exit 0
