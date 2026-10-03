# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=game
BACKUP_LABEL="Game server"
BACKUP_UNIT=game-backup.service

saved=""
install_dir=""
world_exists=false
resolve_sources() {
  world_exists=false
  install_dir="${BACKUP_DRAGONWILDS_INSTALL_DIR:-}"
  [[ -n "$install_dir" ]] || die "BACKUP_DRAGONWILDS_INSTALL_DIR is not rendered into game-backup.service"
  [[ "$install_dir" =~ ^/[[:alnum:]_./-]+$ && "$install_dir" != *//* && "$install_dir" != */./* && "$install_dir" != */. && "$install_dir" != */../* && "$install_dir" != */.. && "$install_dir" != */ ]] \
    || die "invalid fixed Dragonwilds install path"
  configured_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value 2>/dev/null || true)"
  [[ "$configured_install_dir" == "$install_dir" ]] \
    || die "game and backup Dragonwilds install paths differ; rerun both setup scripts"
  saved="$install_dir/RSDragonwilds/Saved"
  [[ -d "$saved" ]] || { log "warning: Dragonwilds saves not found at $saved — not backed up"; saved=""; }
  if [[ -n "$saved" ]] && compgen -G "$saved/SaveGames/*.sav" >/dev/null; then
    world_exists=true
  fi

  # Worlds and server config only (OwnerId, identity, world password); the game
  # install comes back from steamcmd. The repository is encrypted.
  CANDIDATES+=("$HOST_DIR/homepage/config")
  if [[ -n "$saved" ]]; then
    CANDIDATES+=("$saved/SaveGames" "$saved/Config")
  fi
}

# The game writes its world while running, so a raw file copy can be torn. Also
# stage a header-checked, hash-verified copy taken while the file was stable.
stage_extra() {
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
