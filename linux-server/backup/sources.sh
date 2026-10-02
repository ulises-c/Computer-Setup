# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths; .env values override the mount defaults.
# shellcheck disable=SC2034
BACKUP_NAME=server
BACKUP_LABEL=Server
BACKUP_UNIT=backup.service
: "${BACKUP_MOUNT:=/mnt/wd1tb}"
: "${SECOND_BACKUP_MOUNT:=/mnt/wd14tb}"

# Forgejo's data dir may be relocated to an external drive via its own .env.
forgejo_data="$HOST_DIR/forgejo/data"
if [[ -f "$HOST_DIR/forgejo/.env" ]]; then
  fdp="$(env_value "$HOST_DIR/forgejo/.env" FORGEJO_DATA_PATH)"
  if [[ -n "${fdp:-}" ]]; then
    [[ "$fdp" = /* ]] && forgejo_data="$fdp" || forgejo_data="$HOST_DIR/forgejo/$fdp"
  fi
fi

# Dragonwilds worlds live outside the repo; its .env says where the install is.
dragonwilds_saved=""
if [[ -f "$HOST_DIR/dragonwilds/.env" ]]; then
  dwd="$(env_value "$HOST_DIR/dragonwilds/.env" DRAGONWILDS_INSTALL_DIR)"
  if [[ -n "${dwd:-}" ]]; then
    # A relative value would otherwise resolve against systemd's CWD and be
    # silently skipped by the -e filter — a backup script must not lose a path quietly.
    [[ "$dwd" = /* ]] || dwd="$HOST_DIR/dragonwilds/$dwd"
    dragonwilds_saved="$dwd/RSDragonwilds/Saved"
    [[ -d "$dragonwilds_saved" ]] || log "warning: Dragonwilds saves not found at $dragonwilds_saved — not backed up"
  fi
fi

CANDIDATES+=(
  "$forgejo_data"
  "$HOST_DIR/uptime-kuma/data"
  "$HOST_DIR/speedtest-tracker/data"
  "$HOST_DIR/nginx-proxy-manager/data"
  "$HOST_DIR/nginx-proxy-manager/letsencrypt"
  "$HOST_DIR/ntfy/data"
  "$HOST_DIR/adguard/conf"
  "$HOST_DIR/adguard/work"
  "$HOST_DIR/syncthing/config"
  "$HOST_DIR/filebrowser/database"
  "$HOST_DIR/filebrowser/filebrowser.db"
  "$HOST_DIR/qbittorrent/config"
  "$HOST_DIR/homepage/config"
  /etc/atvloadly
)
# Worlds and server config only — the ~5.5 GB game install comes back from steamcmd,
# and Saved/ also holds logs and an EOS cache that are pure noise in a snapshot.
if [[ -n "$dragonwilds_saved" ]]; then
  CANDIDATES+=("$dragonwilds_saved/SaveGames" "$dragonwilds_saved/Config")
fi
