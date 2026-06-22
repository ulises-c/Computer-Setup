#!/usr/bin/env bash
set -euo pipefail

# Nightly server backup → restic. Snapshots persistent service state (SQLite
# DBs, git repos, certs, configs) to an external drive, optionally copies the
# repo to a second drive, prunes old snapshots, writes a status JSON for the
# homepage card, and pings ntfy on success/failure.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SERVER_DIR="$(dirname -- "$SCRIPT_DIR")"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${BACKUP_MOUNT:=/mnt/wd1tb}"
: "${SECOND_RESTIC_REPOSITORY:=}"
: "${SECOND_BACKUP_MOUNT:=/mnt/wd14tb}"
: "${STAGING_DIR:=/var/tmp/server-backup-staging}"
: "${RETENTION_KEEP_DAILY:=7}"
: "${RETENTION_KEEP_WEEKLY:=4}"
: "${RETENTION_KEEP_MONTHLY:=6}"
: "${RUN_CHECK:=true}"
: "${NTFY_TOPIC:=server-backup}"
: "${STATUS_JSON:=$SCRIPT_DIR/status/backup-status.json}"
: "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY in .env}"
: "${RESTIC_PASSWORD:?set RESTIC_PASSWORD in .env}"
export RESTIC_REPOSITORY RESTIC_PASSWORD
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"

HOSTTAG="$(hostname)"
SNAPSHOT_ID=""
SIZE_BYTES=0
DURATION=0
START=$SECONDS

log() { printf '[backup] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

notify() {
  local title="$1" priority="$2" tags="$3" msg="$4"
  [[ -n "${NTFY_URL:-}" ]] || return 0
  local args=(-fsS -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$msg")
  [[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl "${args[@]}" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

write_status() {
  local st="$1"
  mkdir -p "$(dirname "$STATUS_JSON")"
  jq -n \
    --arg status "$st" \
    --arg last_run "$(date -u +%FT%TZ)" \
    --arg snapshot "${SNAPSHOT_ID:-}" \
    --argjson size "${SIZE_BYTES:-0}" \
    --argjson dur "${DURATION:-0}" \
    '{status:$status, last_run:$last_run, snapshot:$snapshot, repo_size_bytes:$size, duration_seconds:$dur}' \
    >"$STATUS_JSON"
}

# systemd OnFailure backstop: record + alert even if the main run died early.
if [[ "${1:-}" == "notify-failure" ]]; then
  write_status failed
  notify "Server backup FAILED" urgent rotating_light "systemd OnFailure — see: journalctl -u backup.service"
  exit 0
fi

STATUS=failed
finish() {
  local rc=$?
  if [[ "$STATUS" != success ]]; then
    DURATION=$((SECONDS - START))
    write_status failed
    notify "Server backup FAILED" urgent rotating_light "exit $rc — see: journalctl -u backup.service"
  fi
  rm -rf "$STAGING_DIR"
}
trap finish EXIT

# --- guards -----------------------------------------------------------------
command -v restic >/dev/null || die "restic not installed (apt install restic)"
command -v sqlite3 >/dev/null || die "sqlite3 not installed (apt install sqlite3)"
command -v jq >/dev/null || die "jq not installed (apt install jq)"
mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT is not mounted — refusing to write to the root FS"
[[ -f "$BACKUP_MOUNT/.backup-target-ok" ]] || die "sentinel $BACKUP_MOUNT/.backup-target-ok missing — wrong drive?"
case "$SERVER_DIR/" in
  "$BACKUP_MOUNT"/*) die "source $SERVER_DIR is under the backup target $BACKUP_MOUNT (circular)" ;;
esac

# --- resolve sources --------------------------------------------------------
# Forgejo's data dir may be relocated to an external drive via its own .env.
forgejo_data="$SERVER_DIR/forgejo/data"
if [[ -f "$SERVER_DIR/forgejo/.env" ]]; then
  fdp="$(grep -E '^FORGEJO_DATA_PATH=' "$SERVER_DIR/forgejo/.env" | tail -1 | cut -d= -f2- || true)"
  [[ -n "${fdp:-}" ]] && forgejo_data="$fdp"
fi

CANDIDATES=(
  "$forgejo_data"
  "$SERVER_DIR/uptime-kuma/data"
  "$SERVER_DIR/speedtest-tracker/data"
  "$SERVER_DIR/nginx-proxy-manager/data"
  "$SERVER_DIR/nginx-proxy-manager/letsencrypt"
  "$SERVER_DIR/ntfy/data"
  "$SERVER_DIR/adguard/conf"
  "$SERVER_DIR/adguard/work"
  "$SERVER_DIR/syncthing/config"
  "$SERVER_DIR/filebrowser/database"
  "$SERVER_DIR/filebrowser/filebrowser.db"
  "$SERVER_DIR/qbittorrent/config"
  "$SERVER_DIR/homepage/config"
  /etc/atvloadly
)
# shellcheck disable=SC2206
[[ -n "${BACKUP_EXTRA_PATHS:-}" ]] && CANDIDATES+=(${BACKUP_EXTRA_PATHS})

SOURCES=()
for s in "${CANDIDATES[@]}"; do
  [[ -e "$s" ]] && SOURCES+=("$s")
done
[[ ${#SOURCES[@]} -gt 0 ]] || log "no service data on disk yet — backing up staging + .env only"

# --- staging: consistent DB + portainer snapshots --------------------------
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/sqlite" "$STAGING_DIR/envs"

# Live SQLite files copied with the online .backup API (consistent, no downtime).
# Staged copies get a .sqlitebak suffix; restore by stripping it.
for root in "${SOURCES[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' db; do
    rel="${db#"$SERVER_DIR"/}"
    rel="${rel#/}"
    dest="$STAGING_DIR/sqlite/$rel.sqlitebak"
    mkdir -p "$(dirname "$dest")"
    if sqlite3 "$db" ".backup '$dest'" 2>/dev/null; then
      log "sqlite snapshot: $rel"
    else
      cp -a "$db" "$dest"
      log "raw copy (not sqlite/locked): $rel"
    fi
  done < <(find "$root" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print0)
done

# Portainer stores BoltDB in a named volume; a brief stop guarantees a clean copy.
if docker inspect -f '{{.State.Running}}' portainer >/dev/null 2>&1; then
  vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' portainer)"
  if [[ -n "$vol" && -d "$vol" ]]; then
    log "snapshotting portainer volume (brief stop)"
    docker stop portainer >/dev/null
    cp -a "$vol" "$STAGING_DIR/portainer"
    docker start portainer >/dev/null
  fi
fi

# Capture each service's .env (secrets needed to restore); the repo is encrypted.
while IFS= read -r -d '' envf; do
  svc="$(basename "$(dirname "$envf")")"
  cp -a "$envf" "$STAGING_DIR/envs/$svc.env"
done < <(find "$SERVER_DIR" -mindepth 2 -maxdepth 2 -name .env -print0)

# --- backup -----------------------------------------------------------------
if ! restic cat config >/dev/null 2>&1; then
  log "initializing restic repo at $RESTIC_REPOSITORY"
  restic init
fi

log "backing up ${#SOURCES[@]} source paths + staging"
restic backup "${SOURCES[@]}" "$STAGING_DIR" \
  --host "$HOSTTAG" \
  --tag server-nightly \
  --exclude ts-state \
  --exclude '*.sock' \
  --exclude lost+found

SNAPSHOT_ID="$(restic snapshots latest --host "$HOSTTAG" --json | jq -r '.[-1].short_id')"

log "pruning (keep ${RETENTION_KEEP_DAILY}d/${RETENTION_KEEP_WEEKLY}w/${RETENTION_KEEP_MONTHLY}m)"
restic forget --host "$HOSTTAG" \
  --keep-daily "$RETENTION_KEEP_DAILY" \
  --keep-weekly "$RETENTION_KEEP_WEEKLY" \
  --keep-monthly "$RETENTION_KEEP_MONTHLY" \
  --prune

[[ "$RUN_CHECK" == true ]] && { log "verifying repo"; restic check; }

SIZE_BYTES="$(restic stats --mode raw-data --json | jq -r '.total_size // 0')"

# --- second copy (3-2-1-ish) -----------------------------------------------
if [[ -n "$SECOND_RESTIC_REPOSITORY" ]]; then
  if mountpoint -q "$SECOND_BACKUP_MOUNT" && [[ -f "$SECOND_BACKUP_MOUNT/.backup-target-ok" ]]; then
    if ! restic -r "$SECOND_RESTIC_REPOSITORY" cat config >/dev/null 2>&1; then
      log "initializing second repo at $SECOND_RESTIC_REPOSITORY"
      restic -r "$SECOND_RESTIC_REPOSITORY" init --copy-chunker-params --from-repo "$RESTIC_REPOSITORY"
    fi
    log "copying snapshots → $SECOND_RESTIC_REPOSITORY"
    restic -r "$SECOND_RESTIC_REPOSITORY" copy --from-repo "$RESTIC_REPOSITORY"
    restic -r "$SECOND_RESTIC_REPOSITORY" forget --host "$HOSTTAG" \
      --keep-daily "$RETENTION_KEEP_DAILY" \
      --keep-weekly "$RETENTION_KEEP_WEEKLY" \
      --keep-monthly "$RETENTION_KEEP_MONTHLY" \
      --prune
  else
    log "second target $SECOND_BACKUP_MOUNT not ready — skipping copy"
  fi
fi

# --- done -------------------------------------------------------------------
DURATION=$((SECONDS - START))
STATUS=success
write_status success
human="$(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || printf '%s bytes' "$SIZE_BYTES")"
notify "Server backup OK" default floppy_disk "snapshot $SNAPSHOT_ID · $human · ${DURATION}s"
log "done: snapshot $SNAPSHOT_ID, $human, ${DURATION}s"
