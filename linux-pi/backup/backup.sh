#!/usr/bin/env bash
set -euo pipefail

# Nightly Pi backup → restic over SSH. Pushes Pi service configs, AdGuard state,
# MotionEye/CUPS configs, and all .env files to the main server's DAS. Optionally
# copies the repo to a second drive for redundancy. Reports to ntfy + a homepage
# card.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PI_DIR="$(dirname -- "$SCRIPT_DIR")"
readonly STAGING_BASE="${HOME:-/root}"

if [[ "${1:-}" != "notify-failure" && -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${SECOND_RESTIC_REPOSITORY:=}"
readonly STAGING_DIR="$STAGING_BASE/pi-backup-staging"
: "${RETENTION_KEEP_DAILY:=7}"
: "${RETENTION_KEEP_WEEKLY:=4}"
: "${RETENTION_KEEP_MONTHLY:=6}"
: "${RUN_CHECK:=true}"
: "${NTFY_TOPIC:=pi-backup}"
: "${KUMA_PUSH_URL:=}"
: "${STATUS_JSON:=$SCRIPT_DIR/status/backup-status.json}"

HOSTTAG="$(hostname)"
SNAPSHOT_ID=""
SIZE_BYTES=0
DURATION=0
START=$SECONDS
STAGING_READY=false
SECOND_COPY_STATUS=""

log() { printf '[backup] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

notify() {
  local title="$1" priority="$2" tags="$3" msg="$4"
  [[ -n "${NTFY_URL:-}" ]] || return 0
  local args=(-fsS --connect-timeout 5 --max-time 10 -H "Title: $title" -H "Priority: $priority" -H "Tags: $tags" -d "$msg")
  [[ -n "${NTFY_TOKEN:-}" ]] && args+=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl "${args[@]}" -- "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

kuma_push() {
  local status="$1" msg="$2" ping="${3:-}"
  [[ -n "$KUMA_PUSH_URL" ]] || return 0
  curl -fsS --connect-timeout 5 --max-time 10 -G \
    --data-urlencode "status=$status" \
    --data-urlencode "msg=$msg" \
    --data-urlencode "ping=$ping" \
    -- "$KUMA_PUSH_URL" >/dev/null 2>&1 || true
}

validate_url() {
  local name="$1" value="$2"
  [[ -z "$value" || "$value" =~ ^https?://[^[:space:]]+$ ]] || die "$name must be an http(s) URL without whitespace"
}

validate_url NTFY_URL "${NTFY_URL:-}"
validate_url KUMA_PUSH_URL "$KUMA_PUSH_URL"
[[ "$NTFY_TOPIC" != *$'\n'* && "$NTFY_TOPIC" != *$'\r'* ]] || die "NTFY_TOPIC cannot contain a newline"
[[ "${NTFY_TOKEN:-}" != *$'\n'* && "${NTFY_TOKEN:-}" != *$'\r'* ]] || die "NTFY_TOKEN cannot contain a newline"

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

# systemd OnFailure owns alerts so a failed run produces exactly one notification.
if [[ "${1:-}" == "notify-failure" ]]; then
  notify "Pi backup FAILED" urgent rotating_light "systemd OnFailure — see: journalctl -u pi-backup.service"
  kuma_push down "systemd OnFailure — see journalctl -u pi-backup.service"
  exit 0
fi

STATUS=failed
finish() {
  if [[ "$STATUS" != success ]]; then
    DURATION=$((SECONDS - START))
    command -v jq >/dev/null && write_status failed || true
  fi
  [[ "$STAGING_READY" == true ]] && rm -rf "$STAGING_DIR"
}
trap finish EXIT

# --- guards -----------------------------------------------------------------
[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "set RESTIC_REPOSITORY in .env"
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "set RESTIC_PASSWORD in .env"
command -v restic >/dev/null || die "restic not installed (apt install restic)"
command -v jq >/dev/null || die "jq not installed (apt install jq)"
export RESTIC_REPOSITORY RESTIC_PASSWORD
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"

# --- resolve sources --------------------------------------------------------
CANDIDATES=(
  "$PI_DIR/adguard/conf"
  "$PI_DIR/homepage/config"
  /etc/motioneye
  /etc/cups
)
# shellcheck disable=SC2206
[[ -n "${BACKUP_EXTRA_PATHS:-}" ]] && CANDIDATES+=(${BACKUP_EXTRA_PATHS})

SOURCES=()
for s in "${CANDIDATES[@]}"; do
  [[ -e "$s" ]] && SOURCES+=("$s")
done
[[ ${#SOURCES[@]} -gt 0 ]] || log "no service data on disk yet — backing up staging + .env only"

# --- staging: collect .env files -------------------------------------------
umask 077
rm -rf "$STAGING_DIR"
install -d -m 700 "$STAGING_DIR/envs"
STAGING_READY=true

# Capture each service's .env (secrets needed to restore); the repo is encrypted.
while IFS= read -r -d '' envf; do
  svc="$(basename "$(dirname "$envf")")"
  install -m 600 "$envf" "$STAGING_DIR/envs/$svc.env"
done < <(find "$PI_DIR" -mindepth 2 -maxdepth 2 -name .env -print0)

# --- backup -----------------------------------------------------------------
if ! restic cat config >/dev/null 2>&1; then
  log "initializing restic repo at $RESTIC_REPOSITORY"
  restic init
fi

log "backing up ${#SOURCES[@]} source paths + staging"
restic backup "${SOURCES[@]}" "$STAGING_DIR" \
  --host "$HOSTTAG" \
  --tag pi-nightly \
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
  sync_second_repo() {
    restic -r "$SECOND_RESTIC_REPOSITORY" cat config >/dev/null 2>&1 || return 1
    log "copying snapshots → $SECOND_RESTIC_REPOSITORY"
    restic -r "$SECOND_RESTIC_REPOSITORY" copy --from-repo "$RESTIC_REPOSITORY" || return 1
    restic -r "$SECOND_RESTIC_REPOSITORY" forget --host "$HOSTTAG" \
      --keep-daily "$RETENTION_KEEP_DAILY" \
      --keep-weekly "$RETENTION_KEEP_WEEKLY" \
      --keep-monthly "$RETENTION_KEEP_MONTHLY" \
      --prune || return 1
  }

  if ! sync_second_repo; then
    SECOND_COPY_STATUS=" · second copy incomplete"
    log "second repo unavailable or an operation failed — primary backup remains successful"
  fi
fi

# --- done -------------------------------------------------------------------
DURATION=$((SECONDS - START))
write_status success
STATUS=success
human="$(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || printf '%s bytes' "$SIZE_BYTES")"
notify "Pi backup OK" default floppy_disk "snapshot $SNAPSHOT_ID · $human · ${DURATION}s${SECOND_COPY_STATUS}"
kuma_push up "snapshot $SNAPSHOT_ID · $human · ${DURATION}s${SECOND_COPY_STATUS}" "$((DURATION * 1000))"
log "done: snapshot $SNAPSHOT_ID, $human, ${DURATION}s${SECOND_COPY_STATUS}"
