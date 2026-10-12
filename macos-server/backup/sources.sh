# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh, run as the login user by the
# net.computer-setup.mac-backup LaunchAgent. Names this host's backup and lists
# its paths; the repository is the main server over SFTP (.env).
# shellcheck disable=SC2034
BACKUP_NAME=mac
BACKUP_LABEL="Mac mini server"
BACKUP_UNIT=net.computer-setup.mac-backup
BACKUP_FAILURE_HINT="launchd run failed — see ~/Library/Logs/computer-setup/mac-backup.log"
STATUS_JSON="$HOST_DIR/status/www/backup-status.json"
STAGING_DIR="$HOME/Library/Caches/computer-setup/mac-backup-staging"

HERMES_HOME="$HOME/.hermes"
resolve_sources() {
  # Small, hard-to-recreate state only: configuration, credentials (the
  # repository is encrypted) and the LaunchAgents. Apps, models and the Hermes
  # install come back from Homebrew, the model hub and the installers.
  CANDIDATES+=(
    "$HOST_DIR/homepage/config"
    "$HOME/forgejo-runner-config.yml"
    "$HOME/Library/LaunchAgents"
    "$HOME/.ssh/config"
    "$HERMES_HOME/config.yaml"
    "$HERMES_HOME/.env"
    "$HERMES_HOME/auth.json"
    "$HERMES_HOME/SOUL.md"
    "$HERMES_HOME/webui.env"
    "$HERMES_HOME/memories"
    "$HERMES_HOME/skills"
    "$HERMES_HOME/cron"
  )
}

# Hermes keeps its databases at the top of ~/.hermes, which is too large to
# back up whole, so they are snapshotted here with SQLite's online backup API.
# Also record what is installed, for rebuilding this Mac from a fresh install.
stage_extra() {
  local db inv="$STAGING_DIR/inventory"
  install -d -m 700 "$STAGING_DIR/hermes" "$inv"
  for db in "$HERMES_HOME"/*.db; do
    [[ -f "$db" ]] || continue
    sqlite3 "$db" ".backup '$STAGING_DIR/hermes/$(basename "$db").sqlitebak'" \
      || die "sqlite snapshot of $db failed"
    log "sqlite snapshot: ~/.hermes/$(basename "$db")"
  done
  sw_vers >"$inv/sw_vers.txt"
  pmset -g custom >"$inv/pmset.txt"
  launchctl list >"$inv/launchctl-list.txt"
  if command -v brew >/dev/null; then
    brew bundle dump --force --file="$inv/Brewfile" >/dev/null 2>&1 || log "warning: brew bundle dump failed"
  fi
  if [[ -d "$HOME/.models" ]]; then
    du -sh "$HOME/.models"/* >"$inv/models.txt" 2>/dev/null || true
  fi
  log "staged Hermes databases and the install inventory"
}
