#!/usr/bin/env bash
set -euo pipefail

# Restore drill for the game server: proves the latest restic snapshot restores
# byte-identical saves and that the game loads them. It stops the empty server,
# takes a fresh snapshot of the stopped world, restores it to a scratch dir,
# compares it with the live files, swaps the restored SaveGames in and waits for
# the game to report a successful world load. The original SaveGames dir is kept
# beside the live one; on any failure it is put back and the game restarted.
#
# Usage: sudo bash linux-game-server/backup/restore-drill.sh [--allow-players]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(dirname -- "$SCRIPT_DIR")"
readonly GAME_UNIT=dragonwilds.service
readonly UPDATE_TIMER=dragonwilds-auto-update.timer
readonly BACKUP_UNIT=game-backup.service
readonly LOAD_TIMEOUT_SECONDS=600

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[drill] %s\n' "$*"; }

allow_players=false
for arg in "$@"; do
  case "$arg" in
    --allow-players) allow_players=true ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || die "run with sudo (restic reaches the repository with root's SSH key)"
for tool in restic jq systemctl journalctl diff; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

install_dir="$(systemctl show "$GAME_UNIT" -p WorkingDirectory --value)"
game_user="$(systemctl show "$GAME_UNIT" -p User --value)"
game_group="$(systemctl show "$GAME_UNIT" -p Group --value)"
[[ -n "$install_dir" && -n "$game_user" ]] || die "cannot read $GAME_UNIT"
saved="$install_dir/RSDragonwilds/Saved"
live="$saved/SaveGames"
[[ -d "$live" && -d "$saved/Config" ]] || die "no world at $saved"

status_json="$HOST_DIR/dragonwilds/status/dragonwilds-status.json"
if [[ "$allow_players" == false ]]; then
  players="$(jq -r '.players // empty' "$status_json" 2>/dev/null || true)"
  [[ "$players" == 0 ]] || die "players online (${players:-unknown}); retry when empty or pass --allow-players"
fi

[[ -f "$SCRIPT_DIR/.env" ]] || die "missing $SCRIPT_DIR/.env"
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a
[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set in backup/.env"
export HOME=/root

stamp="$(date +%Y%m%d-%H%M%S)"
scratch="$(mktemp -d /root/restore-drill.XXXXXX)"
aside="$saved/SaveGames.drill-$stamp"
swapped=false
finished=false

recover() {
  [[ "$finished" == true ]] && return
  printf '[drill] FAILED; restoring the original world and restarting the game\n' >&2
  if [[ "$swapped" == true ]]; then
    systemctl stop "$GAME_UNIT" || true
    rm -rf "$live"
    mv "$aside" "$live"
  fi
  systemctl start "$GAME_UNIT" || printf '[drill] could not start %s; check it by hand\n' "$GAME_UNIT" >&2
  systemctl start "$UPDATE_TIMER" || true
  rm -rf "$scratch"
}
trap recover EXIT

log "stopping $UPDATE_TIMER and $GAME_UNIT"
systemctl stop "$UPDATE_TIMER"
systemctl stop "$GAME_UNIT"

log "taking a fresh snapshot of the stopped world ($BACKUP_UNIT)"
systemctl restart --wait "$BACKUP_UNIT"
[[ "$(systemctl show "$BACKUP_UNIT" -p Result --value)" == success ]] || die "$BACKUP_UNIT failed"

snapshot="$(restic snapshots latest --host "$(hostname)" --json | jq -r '.[-1].short_id')"
[[ -n "$snapshot" && "$snapshot" != null ]] || die "no snapshot found for $(hostname)"
log "restoring snapshot $snapshot to $scratch"
restic restore "$snapshot" --target "$scratch" --include "$live" --include "$saved/Config" >/dev/null

log "comparing restored files with the stopped world"
diff -r "$scratch$live" "$live" >/dev/null || die "restored SaveGames differ from the live world"
diff -r "$scratch$saved/Config" "$saved/Config" >/dev/null || die "restored Config differs from the live world"
for sav in "$scratch$live"/*.sav; do
  [[ -f "$sav" ]] || continue
  log "verified $(basename "$sav") sha256 $(sha256sum "$sav" | cut -c1-16)"
done

log "swapping the restored SaveGames in (original kept at $aside)"
mv "$live" "$aside"
swapped=true
cp -a "$scratch$live" "$live"
chown -R "$game_user:${game_group:-$game_user}" "$live"

since="$(date '+%Y-%m-%d %H:%M:%S')"
log "starting $GAME_UNIT (its pre-update backup gate runs first)"
systemctl start "$GAME_UNIT"
deadline=$((SECONDS + LOAD_TIMEOUT_SECONDS))
until journalctl -u "$GAME_UNIT" --since "$since" --no-pager -o cat | grep -q 'World load SUCCEEDED'; do
  (( SECONDS < deadline )) || die "no 'World load SUCCEEDED' within ${LOAD_TIMEOUT_SECONDS}s"
  state="$(systemctl show "$GAME_UNIT" -p ActiveState --value)"
  [[ "$state" == active || "$state" == activating ]] || die "$GAME_UNIT is $state while loading"
  sleep 5
done
journalctl -u "$GAME_UNIT" --since "$since" --no-pager -o cat | grep 'World load SUCCEEDED' | tail -1

systemctl start "$UPDATE_TIMER"
rm -rf "$scratch"
finished=true
log "PASSED: snapshot $snapshot restored identically and the game loaded it"
log "the pre-drill SaveGames is at $aside; remove it once you are satisfied"
