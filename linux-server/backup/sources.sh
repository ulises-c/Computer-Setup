# shellcheck shell=bash
# Sourced by server-base/backup/backup.sh (as root). Names this host's backup
# and lists its paths in resolve_sources (run after the engine's guards and
# EXIT trap); .env values override the mount defaults.
# shellcheck disable=SC2034
BACKUP_NAME=server
BACKUP_LABEL=Server
BACKUP_UNIT=backup.service
BACKUP_SHARED_LOCK_PATH=/var/lib/dragonwilds/player-log/.backup.lock
: "${BACKUP_MOUNT:=/mnt/wd1tb}"
: "${SECOND_BACKUP_MOUNT:=/mnt/wd14tb}"

# Same marker as linux-game-server/backup/sources.sh (the shared pre-update gate
# keys on it): written the first time a backup sees a world and backed up with it.
# From then on no world, or no configured install path, fails the backup instead
# of succeeding and pruning without the saves.
BACKUP_WORLD_MARKER=/var/lib/dragonwilds/world-seen
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
    die "no Dragonwilds world in ${savegames:-a configured install (BACKUP_DRAGONWILDS_INSTALL_DIR is empty)}, but one was backed up before; restore it, or delete $BACKUP_WORLD_MARKER if it was removed on purpose"
  fi
}

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
  [[ -z "$dwd" || ( "$dwd" =~ ^/[[:alnum:]_./-]+$ && "$dwd" != *//* && "$dwd" != */./* && "$dwd" != */. && "$dwd" != */../* && "$dwd" != */.. && "$dwd" != */ ) ]] \
    || die "invalid fixed Dragonwilds install path"
  command -v systemctl >/dev/null || die "systemctl is required to verify the Dragonwilds install path"
  # Once the game moved to its own host, only the saves left here are backed up;
  # the path cross-check applies only while this host still runs the game.
  game_load_state="$(systemctl show dragonwilds.service --property=LoadState --value 2>/dev/null)" \
    || die "could not read dragonwilds.service LoadState"
  if [[ -z "$dwd" && ( "$game_load_state" == loaded || -f "$HOST_DIR/dragonwilds/.env" || -d "$HOST_DIR/dragonwilds/games/dragonwilds/RSDragonwilds/Saved" ) ]]; then
    die "BACKUP_DRAGONWILDS_INSTALL_DIR is missing for configured/present Dragonwilds state; rerun backup setup"
  fi
  if [[ "$game_load_state" == loaded ]]; then
    configured_game_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value 2>/dev/null)" \
      || die "could not read dragonwilds.service WorkingDirectory"
    [[ -n "$configured_game_install_dir" && "$configured_game_install_dir" == "$dwd" ]] \
      || die "game and main-server backup Dragonwilds install paths differ; rerun both setup scripts"
  fi
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
  dragonwilds_world=false
  [[ -n "$dwd" ]] && compgen -G "$dwd/RSDragonwilds/Saved/SaveGames/*.sav" >/dev/null && dragonwilds_world=true
  check_world_marker "${dwd:+$dwd/RSDragonwilds/Saved/SaveGames}" "$dragonwilds_world"

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
    /var/lib/dragonwilds/player-log
    "$BACKUP_WORLD_MARKER"
    /etc/atvloadly
  )
  # Worlds and server config only — the ~5.5 GB game install comes back from steamcmd,
  # and Saved/ also holds logs and an EOS cache that are pure noise in a snapshot.
  if [[ -n "$dragonwilds_saved" ]]; then
    CANDIDATES+=("$dragonwilds_saved/SaveGames" "$dragonwilds_saved/Config")
  fi
}
