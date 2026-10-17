#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  *) printf 'usage: bash %s [--dry-run]\n' "$0" >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { printf 'error: too many arguments\n' >&2; exit 1; }
[[ $EUID -ne 0 ]] || { printf 'error: SteamCMD must run as the game user, not root\n' >&2; exit 1; }
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
fi
: "${STEAMCMD:=$HOME/.local/share/steamcmd/steamcmd.sh}"
: "${DRAGONWILDS_INSTALL_DIR:=$HOME/games/dragonwilds}"
if [[ "$DRY_RUN" == true ]]; then
  printf '[dry-run] download Valve SteamCMD to %s; install/validate Steam app 4019830 in %s (never starts the server)\n' \
    "$STEAMCMD" "$DRAGONWILDS_INSTALL_DIR"
  exit 0
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/maintenance.sh"
maintenance_hold -s
maintenance_check
configured_install_dir="$(systemctl show dragonwilds.service --property=WorkingDirectory --value 2>/dev/null || true)"
if [[ -n "$configured_install_dir" ]]; then
  DRAGONWILDS_INSTALL_DIR="$configured_install_dir"
fi
if ! [[ "$DRAGONWILDS_INSTALL_DIR" =~ ^/[[:alnum:]_./-]+$ && "$DRAGONWILDS_INSTALL_DIR" != *//* && "$DRAGONWILDS_INSTALL_DIR" != */./* && "$DRAGONWILDS_INSTALL_DIR" != */. && "$DRAGONWILDS_INSTALL_DIR" != */../* && "$DRAGONWILDS_INSTALL_DIR" != */.. && "$DRAGONWILDS_INSTALL_DIR" != */ ]]; then
  printf 'error: invalid Dragonwilds install path: %s\n' "$DRAGONWILDS_INSTALL_DIR" >&2
  exit 1
fi
if compgen -G "$DRAGONWILDS_INSTALL_DIR/RSDragonwilds/Saved/SaveGames/*.sav" >/dev/null; then
  [[ -n "$configured_install_dir" ]] || {
    printf 'error: an existing world requires the installed dragonwilds.service backup gate\n' >&2
    exit 1
  }
  systemctl start --wait dragonwilds-pre-update-backup.service
fi
if [[ ! -x "$STEAMCMD" ]]; then
  cache="$HOME/.cache/computer-setup"
  mkdir -p "$cache" "$(dirname "$STEAMCMD")"
  archive="$(mktemp "$cache/steamcmd.XXXXXX.tar.gz")"
  trap 'rm -f "$archive"' EXIT
  curl -fSL --retry 3 --connect-timeout 20 \
    https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o "$archive"
  tar -xzf "$archive" -C "$(dirname "$STEAMCMD")"
fi
mkdir -p "$DRAGONWILDS_INSTALL_DIR"
exec 9>"$DRAGONWILDS_INSTALL_DIR/.steamcmd.lock"
flock 9
maintenance_check
"$STEAMCMD" \
  +force_install_dir "$DRAGONWILDS_INSTALL_DIR" +login anonymous +app_update 4019830 validate +quit
test -x "$DRAGONWILDS_INSTALL_DIR/RSDragonwildsServer.sh"
maintenance_check
printf 'Dragonwilds downloaded. No world was created and no game process was started.\n'
