# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=game
BACKUP_LABEL="Game server"
BACKUP_UNIT=game-backup.service
BACKUP_SHARED_LOCK_PATH=/var/lib/dragonwilds/player-log/.backup.lock
# Written the first time a backup sees a world, and backed up with it so a full
# restore brings it back. From then on an empty SaveGames is a lost world, not a
# fresh install: the backup fails instead of succeeding (and pruning) without it,
# and the pre-update gate still runs. The main server's sources.sh keeps the same
# marker for the saves it holds.
BACKUP_WORLD_MARKER=/var/lib/dragonwilds/world-seen

# $1: the SaveGames dir this backup covers; $2: whether it holds a world.
check_world_marker() {
  local savegames="$1" present="$2" seen=""
  if [[ "$present" == true ]]; then
    if [[ -e "$BACKUP_WORLD_MARKER" ]]; then
      seen="$(head -n1 -- "$BACKUP_WORLD_MARKER")"
      [[ "$seen" == "$savegames" ]] \
        || log "warning: the world was first backed up from $seen, now from $savegames; check nothing was left behind"
    else
      install -d -m 755 "$(dirname -- "$BACKUP_WORLD_MARKER")"
      printf '%s\n' "$savegames" >"$BACKUP_WORLD_MARKER"
    fi
  elif [[ -e "$BACKUP_WORLD_MARKER" ]]; then
    die "no Dragonwilds world in $savegames, but one was backed up before; restore it, or delete $BACKUP_WORLD_MARKER if it was removed on purpose"
  fi
}

saved=""
install_dir=""
world_exists=false
resolve_sources() {
  world_exists=false
  install_dir="${BACKUP_DRAGONWILDS_INSTALL_DIR:-}"
  [[ -n "$install_dir" ]] || die "BACKUP_DRAGONWILDS_INSTALL_DIR is not rendered into game-backup.service"
  [[ "$install_dir" =~ ^/[[:alnum:]_./-]+$ && "$install_dir" != *//* && "$install_dir" != */./* && "$install_dir" != */. && "$install_dir" != */../* && "$install_dir" != */.. && "$install_dir" != */ ]] \
    || die "invalid fixed Dragonwilds install path"
  configured_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value)" \
    || die "cannot read dragonwilds.service's install path from systemd"
  [[ "$configured_install_dir" == "$install_dir" ]] \
    || die "game and backup Dragonwilds install paths differ; rerun both setup scripts"
  saved="$install_dir/RSDragonwilds/Saved"
  [[ -d "$saved" ]] || { log "warning: Dragonwilds saves not found at $saved — not backed up"; saved=""; }
  if [[ -n "$saved" ]] && compgen -G "$saved/SaveGames/*.sav" >/dev/null; then
    world_exists=true
  fi
  check_world_marker "${saved:-$install_dir/RSDragonwilds/Saved}/SaveGames" "$world_exists"

  # Worlds and server config only (OwnerId, identity, world password); the game
  # install comes back from steamcmd. The repository is encrypted.
  CANDIDATES+=("$HOST_DIR/homepage/config")
  CANDIDATES+=("/var/lib/dragonwilds/player-log" "$BACKUP_WORLD_MARKER")
  if [[ -n "$saved" ]]; then
    CANDIDATES+=("$saved/SaveGames" "$saved/Config")
  fi
  resolve_2004scape_sources
}

# 2004Scape state only: the engine/content/client checkouts come back from the
# bootstrap's revision clone. The engine scans the RS-SDK data dir for SQLite;
# Lost City's db.sqlite sits beside the checkout, so stage_extra snapshots it.
resolve_2004scape_sources() {
  local runtime="${BACKUP_LOSTCITY_RUNTIME_DIR:-}" rs_sdk="${BACKUP_RS_SDK_DATA_DIR:-}" path
  for path in "$runtime" "$rs_sdk"; do
    [[ -z "$path" ]] && continue
    [[ "$path" =~ ^/[[:alnum:]_./-]+$ && "$path" != *//* && "$path" != */./* && "$path" != */. && "$path" != */../* && "$path" != */.. && "$path" != */ ]] \
      || die "invalid fixed 2004Scape data path"
  done
  if [[ -n "$runtime" ]]; then
    if [[ -d "$runtime/engine" ]]; then
      CANDIDATES+=("$runtime/server.json" "$runtime/engine/.env"
        "$runtime/engine/data/players" "$runtime/engine/data/config")
    else
      log "warning: Lost City runtime not found at $runtime — not backed up"
    fi
  fi
  if [[ -n "$rs_sdk" ]]; then
    if [[ -d "$rs_sdk" ]]; then
      CANDIDATES+=("$rs_sdk")
    else
      log "warning: RS-SDK data not found at $rs_sdk — not backed up"
    fi
  fi
}

stage_lostcity_db() {
  local db="${BACKUP_LOSTCITY_RUNTIME_DIR:-}/engine/db.sqlite"
  [[ -n "${BACKUP_LOSTCITY_RUNTIME_DIR:-}" && -f "$db" ]] || return 0
  command -v sqlite3 >/dev/null || die "sqlite3 not installed (apt install sqlite3); needed for $db"
  install -d -m 700 "$STAGING_DIR/lostcity"
  sqlite3 "$db" ".backup '$STAGING_DIR/lostcity/db.sqlite.sqlitebak'" \
    || die "sqlite snapshot of $db failed"
  log "sqlite snapshot: Lost City db.sqlite"
}

# The game writes its world while running, so a raw file copy can be torn. Also
# stage a header-checked, hash-verified copy taken while the file was stable.
stage_extra() {
  stage_lostcity_db
  [[ "$world_exists" == true ]] || return 0
  [[ "${BACKUP_SAVE_SCRIPT:-}" == "$SCRIPT_DIR/backup-save.py" ]] \
    || die "Dragonwilds backup helper is not the installed root-owned bundle copy"
  [[ -n "${BACKUP_SAVE_SCRIPT:-}" ]] || die "root-owned Dragonwilds backup helper is not installed"
  [[ -x "$BACKUP_SAVE_SCRIPT" || -f "$BACKUP_SAVE_SCRIPT" ]] \
    || die "root-owned Dragonwilds backup helper is missing"
  [[ "${BACKUP_SAVE_SCRIPT_SHA256:-}" =~ ^[[:xdigit:]]{64}$ ]] \
    || die "Dragonwilds backup helper hash is not pinned in game-backup.service"
  local helper_hash
  if command -v sha256sum >/dev/null; then
    helper_hash="$(sha256sum "$BACKUP_SAVE_SCRIPT" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null; then
    helper_hash="$(shasum -a 256 "$BACKUP_SAVE_SCRIPT" | cut -d' ' -f1)"
  else
    die "sha256sum or shasum is required to verify the Dragonwilds backup helper"
  fi
  [[ "$helper_hash" == "$BACKUP_SAVE_SCRIPT_SHA256" ]] \
    || die "Dragonwilds backup helper hash does not match game-backup.service"
  install -d -m 700 "$STAGING_DIR/dragonwilds"
  python3 "$BACKUP_SAVE_SCRIPT" \
    --install-dir "$install_dir" --output-dir "$STAGING_DIR/dragonwilds" >/dev/null
  log "staged verified Dragonwilds world copy"
}
