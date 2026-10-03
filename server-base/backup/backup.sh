#!/usr/bin/env bash
set -euo pipefail

# Nightly restic backup shared by every server (server-base/backup). Each host
# runs it through a symlink in <host>/backup/, next to that host's .env and
# sources.sh. sources.sh names the backup (BACKUP_NAME, BACKUP_LABEL,
# BACKUP_UNIT) and defines resolve_sources, which appends the host's paths to
# CANDIDATES, plus an optional stage_extra hook that writes into $STAGING_DIR.
# Only those simple assignments run at source time, so a broken host path can
# never stop the failure notifier. Snapshots those paths plus
# consistent SQLite copies, a Portainer volume copy and every service .env,
# prunes, optionally copies to a second repository, writes the status JSON
# for the Homepage card and reports to ntfy / Uptime Kuma.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
HOST_DIR="${BACKUP_HOST_DIR:-$(dirname -- "$SCRIPT_DIR")}"
readonly UNIT_SCRIPT_DIR="$SCRIPT_DIR"
readonly UNIT_HOST_DIR="$HOST_DIR"
readonly UNIT_BACKUP_HOST_DIR_SET="${BACKUP_HOST_DIR+x}"
readonly UNIT_BACKUP_HOST_DIR="${BACKUP_HOST_DIR-}"
readonly UNIT_BACKUP_SAVE_SCRIPT_SET="${BACKUP_SAVE_SCRIPT+x}"
readonly UNIT_BACKUP_SAVE_SCRIPT="${BACKUP_SAVE_SCRIPT-}"
readonly UNIT_BACKUP_SAVE_SCRIPT_SHA256_SET="${BACKUP_SAVE_SCRIPT_SHA256+x}"
readonly UNIT_BACKUP_SAVE_SCRIPT_SHA256="${BACKUP_SAVE_SCRIPT_SHA256-}"
readonly UNIT_BACKUP_DRAGONWILDS_INSTALL_DIR_SET="${BACKUP_DRAGONWILDS_INSTALL_DIR+x}"
readonly UNIT_BACKUP_DRAGONWILDS_INSTALL_DIR="${BACKUP_DRAGONWILDS_INSTALL_DIR-}"
readonly UNIT_BACKUP_FORGEJO_DATA_PATH_SET="${BACKUP_FORGEJO_DATA_PATH+x}"
readonly UNIT_BACKUP_FORGEJO_DATA_PATH="${BACKUP_FORGEJO_DATA_PATH-}"
readonly UNIT_STATUS_JSON_SET="${STATUS_JSON+x}"
readonly UNIT_STATUS_JSON="${STATUS_JSON-}"

if [[ "${1:-}" != "notify-failure" && -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

# These values are rendered into the root-owned systemd unit and may not be
# overridden by the bundle's .env. In particular, never let a stale helper path
# or world path redirect a root backup into the writable checkout.
SCRIPT_DIR="$UNIT_SCRIPT_DIR"
HOST_DIR="$UNIT_HOST_DIR"
if [[ "$UNIT_BACKUP_HOST_DIR_SET" == x ]]; then BACKUP_HOST_DIR="$UNIT_BACKUP_HOST_DIR"; fi
if [[ "$UNIT_BACKUP_SAVE_SCRIPT_SET" == x ]]; then BACKUP_SAVE_SCRIPT="$UNIT_BACKUP_SAVE_SCRIPT"; fi
if [[ "$UNIT_BACKUP_SAVE_SCRIPT_SHA256_SET" == x ]]; then
  BACKUP_SAVE_SCRIPT_SHA256="$UNIT_BACKUP_SAVE_SCRIPT_SHA256"
fi
if [[ "$UNIT_BACKUP_DRAGONWILDS_INSTALL_DIR_SET" == x ]]; then
  BACKUP_DRAGONWILDS_INSTALL_DIR="$UNIT_BACKUP_DRAGONWILDS_INSTALL_DIR"
fi
if [[ "$UNIT_BACKUP_FORGEJO_DATA_PATH_SET" == x ]]; then
  BACKUP_FORGEJO_DATA_PATH="$UNIT_BACKUP_FORGEJO_DATA_PATH"
fi
if [[ "$UNIT_STATUS_JSON_SET" == x ]]; then STATUS_JSON="$UNIT_STATUS_JSON"; fi

HOSTTAG="$(hostname)"
SNAPSHOT_ID=""
SIZE_BYTES=0
DURATION=0
START=$SECONDS
STAGING_READY=false
SECOND_COPY_STATUS=""

log() { printf '[backup] %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Read one key from a service's .env without sourcing it (this runs as root, and
# those files are user-owned). Strips one layer of matching quotes, since the
# services themselves source the file and so accept KEY="value"; also tolerates
# an `export ` prefix, CRLF endings and a trailing ` # comment`.
env_value() {
  local v
  v="$(grep -E "^(export[[:space:]]+)?$2=" "$1" | tail -1 | cut -d= -f2- || true)"
  v="${v%$'\r'}"
  if [[ "$v" =~ ^\"([^\"]*)\"[[:space:]]*(#.*)?$ ]]; then
    v="${BASH_REMATCH[1]}"
  elif [[ "$v" =~ ^\'([^\']*)\'[[:space:]]*(#.*)?$ ]]; then
    v="${BASH_REMATCH[1]}"
  else
    v="${v%%[[:space:]]#*}"
  fi
  printf '%s' "$v"
}

CANDIDATES=()
# shellcheck source=/dev/null
source "$SCRIPT_DIR/sources.sh"
: "${BACKUP_NAME:?sources.sh must set BACKUP_NAME}"
: "${BACKUP_LABEL:?sources.sh must set BACKUP_LABEL}"
: "${BACKUP_UNIT:?sources.sh must set BACKUP_UNIT}"
# The failure path does not source .env (a broken file must not stop the alert),
# so read just the notifier keys without executing it when systemd's
# EnvironmentFile did not already provide them.
if [[ "${1:-}" == notify-failure && -f "$SCRIPT_DIR/.env" ]]; then
  for key in NTFY_URL NTFY_TOPIC NTFY_TOKEN KUMA_PUSH_URL; do
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$(env_value "$SCRIPT_DIR/.env" "$key")"
  done
fi
: "${BACKUP_MOUNT:=}"
: "${SECOND_BACKUP_MOUNT:=}"
: "${SECOND_RESTIC_REPOSITORY:=}"
: "${STAGING_DIR:=/var/tmp/$BACKUP_NAME-backup-staging}"
: "${RETENTION_KEEP_DAILY:=7}"
: "${RETENTION_KEEP_WEEKLY:=4}"
: "${RETENTION_KEEP_MONTHLY:=6}"
: "${RUN_CHECK:=true}"
: "${BACKUP_SHARED_LOCK_PATH:=}"
: "${NTFY_TOPIC:=$BACKUP_NAME-backup}"
: "${KUMA_PUSH_URL:=}"
: "${STATUS_JSON:=$SCRIPT_DIR/status/backup-status.json}"

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

# Checked per channel so one bad value cannot silence the other channel.
ntfy_config_valid() {
  [[ -z "${NTFY_URL:-}" || "${NTFY_URL:-}" =~ ^https?://[^[:space:]]+$ ]] \
    && [[ "$NTFY_TOPIC" != *$'\n'* && "$NTFY_TOPIC" != *$'\r'* ]] \
    && [[ "${NTFY_TOKEN:-}" != *$'\n'* && "${NTFY_TOKEN:-}" != *$'\r'* ]]
}

kuma_config_valid() {
  [[ -z "$KUMA_PUSH_URL" || "$KUMA_PUSH_URL" =~ ^https?://[^[:space:]]+$ ]]
}

write_status() {
  local st="$1"
  local notifier_pending="${2:-false}"
  mkdir -p "$(dirname "$STATUS_JSON")"
  jq -n \
    --arg status "$st" \
    --arg last_run "$(date -u +%FT%TZ)" \
    --arg snapshot "${SNAPSHOT_ID:-}" \
    --argjson size "${SIZE_BYTES:-0}" \
    --argjson dur "${DURATION:-0}" \
    --argjson notifier_pending "$notifier_pending" \
    '{status:$status, last_run:$last_run, snapshot:$snapshot, repo_size_bytes:$size, duration_seconds:$dur, notifier_pending:$notifier_pending}' \
    >"$STATUS_JSON"
}

# systemd OnFailure owns alerts so a failed run produces exactly one notification.
if [[ "${1:-}" == "notify-failure" ]]; then
  if command -v jq >/dev/null; then
    if jq -e '.status == "failed" and .notifier_pending == true' "$STATUS_JSON" >/dev/null 2>&1; then
      status_tmp="${STATUS_JSON}.tmp.$$"
      if jq '.notifier_pending = false' "$STATUS_JSON" >"$status_tmp" \
        && mv "$status_tmp" "$STATUS_JSON"; then
        :
      else
        rm -f "$status_tmp"
      fi
    else
      write_status failed || true
    fi
  fi
  [[ -n "${NTFY_URL:-}" || -n "$KUMA_PUSH_URL" ]] \
    || printf 'warning: NTFY_URL and KUMA_PUSH_URL are both empty; failure recorded but nobody alerted\n' >&2
  if ntfy_config_valid; then
    notify "$BACKUP_LABEL backup FAILED" urgent rotating_light "systemd OnFailure — see: journalctl -u $BACKUP_UNIT"
  else
    printf 'warning: invalid ntfy configuration; failure status recorded without an ntfy alert\n' >&2
  fi
  if kuma_config_valid; then
    kuma_push down "systemd OnFailure — see journalctl -u $BACKUP_UNIT"
  else
    printf 'warning: invalid KUMA_PUSH_URL; failure status recorded without a Kuma push\n' >&2
  fi
  exit 0
fi

STATUS=failed
finish() {
  if [[ "$STATUS" != success ]]; then
    DURATION=$((SECONDS - START))
    command -v jq >/dev/null && write_status failed true || true
  fi
  [[ "$STAGING_READY" == true ]] && rm -rf "$STAGING_DIR"
}
trap finish EXIT

# --- guards -----------------------------------------------------------------
command -v jq >/dev/null || die "jq not installed (apt install jq)"
write_status running
validate_url NTFY_URL "${NTFY_URL:-}"
validate_url KUMA_PUSH_URL "$KUMA_PUSH_URL"
[[ "$NTFY_TOPIC" != *$'\n'* && "$NTFY_TOPIC" != *$'\r'* ]] || die "NTFY_TOPIC cannot contain a newline"
[[ "${NTFY_TOKEN:-}" != *$'\n'* && "${NTFY_TOKEN:-}" != *$'\r'* ]] || die "NTFY_TOKEN cannot contain a newline"
[[ -n "${NTFY_URL:-}" || -n "$KUMA_PUSH_URL" ]] \
  || log "warning: NTFY_URL and KUMA_PUSH_URL are both empty in .env — a failed backup will alert nobody"
[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "set RESTIC_REPOSITORY in .env"
[[ -n "${RESTIC_PASSWORD:-}" ]] || die "set RESTIC_PASSWORD in .env"
command -v restic >/dev/null || die "restic not installed (apt install restic)"
export RESTIC_REPOSITORY RESTIC_PASSWORD
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
# A local-drive repository must be on its mounted, labelled drive, never the root FS.
if [[ -n "$BACKUP_MOUNT" ]]; then
  mountpoint -q "$BACKUP_MOUNT" || die "$BACKUP_MOUNT is not mounted — refusing to write to the root FS"
  [[ -f "$BACKUP_MOUNT/.backup-target-ok" ]] || die "sentinel $BACKUP_MOUNT/.backup-target-ok missing — wrong drive?"
  case "$HOST_DIR/" in
    "$BACKUP_MOUNT"/*) die "source $HOST_DIR is under the backup target $BACKUP_MOUNT (circular)" ;;
  esac
fi

# --- resolve sources --------------------------------------------------------
resolve_sources
# shellcheck disable=SC2206
[[ -n "${BACKUP_EXTRA_PATHS:-}" ]] && CANDIDATES+=(${BACKUP_EXTRA_PATHS})

SOURCES=()
for s in "${CANDIDATES[@]}"; do
  [[ -e "$s" ]] && SOURCES+=("$s")
done
[[ ${#SOURCES[@]} -gt 0 ]] || log "no service data on disk yet — backing up staging + .env only"

# --- staging: consistent DB + portainer snapshots, .env files -----------
umask 077
rm -rf "$STAGING_DIR"
install -d -m 700 "$STAGING_DIR/envs" "$STAGING_DIR/sqlite"
STAGING_READY=true

# Live SQLite files copied with the online .backup API (consistent, no downtime).
# Staged copies get a .sqlitebak suffix; restore by stripping it.
for root in "${SOURCES[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' db; do
    command -v sqlite3 >/dev/null || die "sqlite3 not installed (apt install sqlite3); needed for $db"
    rel="${db#"$HOST_DIR"/}"
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
if command -v docker >/dev/null && docker inspect -f '{{.State.Running}}' portainer >/dev/null 2>&1; then
  vol="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' portainer)"
  if [[ -n "$vol" && -d "$vol" ]]; then
    log "snapshotting portainer volume (brief stop)"
    docker stop portainer >/dev/null
    copied=true
    cp -a "$vol" "$STAGING_DIR/portainer" || copied=false
    docker start portainer >/dev/null
    [[ "$copied" == true ]] || die "copying the portainer volume failed (portainer restarted)"
  fi
fi

if declare -F stage_extra >/dev/null; then
  stage_extra
fi

# Capture each service's .env (secrets needed to restore); the repo is encrypted.
while IFS= read -r -d '' envf; do
  svc="$(basename "$(dirname "$envf")")"
  install -m 600 "$envf" "$STAGING_DIR/envs/$svc.env"
done < <(find "$HOST_DIR" -mindepth 2 -maxdepth 2 -name .env -print0)

# --- backup -----------------------------------------------------------------
if ! restic cat config >/dev/null 2>&1; then
  # A remote repository is never created here: an unreachable or misconfigured
  # SFTP target looks the same as a missing repository (sftp-client.sh inits it).
  [[ "$RESTIC_REPOSITORY" != sftp:* ]] || die "cannot open $RESTIC_REPOSITORY (not auto-initializing a remote repository; check SSH/SFTP access)"
  log "initializing restic repo at $RESTIC_REPOSITORY"
  restic init
fi

log "backing up ${#SOURCES[@]} source paths + staging"
BACKUP_SHARED_LOCK_FD=""
if [[ -n "$BACKUP_SHARED_LOCK_PATH" ]]; then
  command -v flock >/dev/null || die "flock is required for coordinated player-log backups"
  [[ -f "$BACKUP_SHARED_LOCK_PATH" && ! -L "$BACKUP_SHARED_LOCK_PATH" ]] \
    || die "shared backup lock is missing or not a regular file: $BACKUP_SHARED_LOCK_PATH"
  exec {BACKUP_SHARED_LOCK_FD}<>"$BACKUP_SHARED_LOCK_PATH"
  lock_fd_target="$(readlink -- "/proc/$$/fd/$BACKUP_SHARED_LOCK_FD")" || die "cannot inspect shared backup lock"
  [[ "$lock_fd_target" == "$BACKUP_SHARED_LOCK_PATH" ]] \
    || die "shared backup lock redirected to: $lock_fd_target"
  lock_fd_info="$(stat -Lc '%u:%a:%F' -- "/proc/$$/fd/$BACKUP_SHARED_LOCK_FD")" || die "cannot stat shared backup lock"
  [[ "$lock_fd_info" == '0:600:regular file' ]] \
    || die "shared backup lock ownership or mode is unsafe: $lock_fd_info"
  flock -s "$BACKUP_SHARED_LOCK_FD" || die "could not acquire shared backup lock"
fi
restic backup "${SOURCES[@]}" "$STAGING_DIR" \
  --host "$HOSTTAG" \
  --tag "$BACKUP_NAME-nightly" \
  --exclude ts-state \
  --exclude '*.sock' \
  --exclude lost+found
if [[ -n "$BACKUP_SHARED_LOCK_FD" ]]; then
  flock -u "$BACKUP_SHARED_LOCK_FD"
fi

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
    if [[ -n "$SECOND_BACKUP_MOUNT" ]]; then
      mountpoint -q "$SECOND_BACKUP_MOUNT" && [[ -f "$SECOND_BACKUP_MOUNT/.backup-target-ok" ]] || return 1
    fi
    if ! restic -r "$SECOND_RESTIC_REPOSITORY" cat config >/dev/null 2>&1; then
      # Only a verified local mount may be initialized: over SFTP an unreachable
      # target and an empty mountpoint look the same as a new repository.
      [[ -n "$SECOND_BACKUP_MOUNT" ]] || return 1
      log "initializing second repo at $SECOND_RESTIC_REPOSITORY"
      restic -r "$SECOND_RESTIC_REPOSITORY" init --copy-chunker-params --from-repo "$RESTIC_REPOSITORY" || return 1
    fi
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
notify "$BACKUP_LABEL backup OK" default floppy_disk "snapshot $SNAPSHOT_ID · $human · ${DURATION}s${SECOND_COPY_STATUS}"
kuma_push up "snapshot $SNAPSHOT_ID · $human · ${DURATION}s${SECOND_COPY_STATUS}" "$((DURATION * 1000))"
log "done: snapshot $SNAPSHOT_ID, $human, ${DURATION}s${SECOND_COPY_STATUS}"
