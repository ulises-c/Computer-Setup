# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths in resolve_sources (run after the engine's guards and
# EXIT trap); .env values override the mount defaults.
# shellcheck disable=SC2034
BACKUP_NAME=server
BACKUP_LABEL=Server
BACKUP_UNIT=backup.service
: "${BACKUP_MOUNT:=/mnt/wd1tb}"
: "${SECOND_BACKUP_MOUNT:=/mnt/wd14tb}"

resolve_sources() {
  # Forgejo's data dir is captured into the root-owned unit during setup;
  # never reread the checkout-owned Forgejo .env as root at backup time.
  forgejo_data="${BACKUP_FORGEJO_DATA_PATH:-}"
  [[ -n "$forgejo_data" ]] || die "BACKUP_FORGEJO_DATA_PATH is not rendered into backup.service"
  [[ "$forgejo_data" =~ ^/[[:alnum:]_./-]+$ && "$forgejo_data" != *//* && "$forgejo_data" != */./* && "$forgejo_data" != */. && "$forgejo_data" != */../* && "$forgejo_data" != */.. && "$forgejo_data" != */ ]] \
    || die "invalid fixed Forgejo data path"

  # Dragonwilds worlds live outside the repo; setup renders the fixed install
  # path into the root-owned systemd unit rather than rereading a user-owned .env.
  dragonwilds_saved=""
  dwd="${BACKUP_DRAGONWILDS_INSTALL_DIR:-}"
  [[ -n "$dwd" ]] || die "BACKUP_DRAGONWILDS_INSTALL_DIR is not rendered into backup.service"
  [[ "$dwd" =~ ^/[[:alnum:]_./-]+$ && "$dwd" != *//* && "$dwd" != */./* && "$dwd" != */. && "$dwd" != */../* && "$dwd" != */.. && "$dwd" != */ ]] \
    || die "invalid fixed Dragonwilds install path"
  command -v systemctl >/dev/null || die "systemctl is required to verify the Dragonwilds install path"
  configured_game_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value 2>/dev/null)" \
    || die "could not read dragonwilds.service WorkingDirectory"
  [[ -n "$configured_game_install_dir" && "$configured_game_install_dir" == "$dwd" ]] \
    || die "game and main-server backup Dragonwilds install paths differ; rerun both setup scripts"
  if [[ -n "$dwd" ]]; then
    dragonwilds_saved="$dwd/RSDragonwilds/Saved"
    [[ -d "$dragonwilds_saved" ]] || log "warning: Dragonwilds saves not found at $dragonwilds_saved — not backed up"
    if compgen -G "$dragonwilds_saved/SaveGames/*.sav" >/dev/null; then
      config="$dragonwilds_saved/Config/LinuxServer/DedicatedServer.ini"
      [[ -r "$config" ]] || die "Dragonwilds save exists but DedicatedServer.ini is missing"
      python3 - "$config" "$dragonwilds_saved/SaveGames" <<'PY'
import configparser
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
save_dir = Path(sys.argv[2])
try:
    config = configparser.ConfigParser(interpolation=None)
    config.read(config_path)
    world = config['/Script/Dominion.DedicatedServerSettings']['DefaultWorldName'].strip()
    if not world or world in ('.', '..') or '/' in world or '\\' in world or '\n' in world:
        raise ValueError()
    if not (save_dir / f'{world}.sav').is_file():
        raise ValueError()
except (OSError, KeyError, ValueError, configparser.Error):
    raise SystemExit('invalid Dragonwilds config/world; refusing an unverified backup')
PY
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
}
