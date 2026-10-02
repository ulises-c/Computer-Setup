# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=game
BACKUP_LABEL="Game server"
BACKUP_UNIT=game-backup.service

saved=""
if [[ -f "$HOST_DIR/dragonwilds/.env" ]]; then
  install_dir="$(env_value "$HOST_DIR/dragonwilds/.env" DRAGONWILDS_INSTALL_DIR)"
  [[ "$install_dir" = /* ]] || die "DRAGONWILDS_INSTALL_DIR must be absolute in dragonwilds/.env"
  saved="$install_dir/RSDragonwilds/Saved"
  [[ -d "$saved" ]] || log "warning: Dragonwilds saves not found at $saved — not backed up"
fi

# Worlds and server config only (OwnerId, identity, world password); the game
# install comes back from steamcmd. The repository is encrypted.
CANDIDATES+=("$HOST_DIR/homepage/config")
if [[ -n "$saved" ]]; then
  CANDIDATES+=("$saved/SaveGames" "$saved/Config")
fi

# The game writes its world while running, so a raw file copy can be torn. Also
# stage a header-checked, hash-verified copy taken while the file was stable.
stage_extra() {
  [[ -n "$saved" ]] || return 0
  install -d -m 700 "$STAGING_DIR/dragonwilds"
  python3 "$HOST_DIR/dragonwilds/backup-save.py" \
    --install-dir "$install_dir" --output-dir "$STAGING_DIR/dragonwilds" >/dev/null
  log "staged verified Dragonwilds world copy"
}
