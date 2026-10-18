#!/usr/bin/env bash
set -Eeuo pipefail

# Restore drill for the game server: proves the latest restic snapshot restores
# byte-identical saves and that the game loads them. It stops the empty server,
# takes a fresh snapshot of the stopped world, restores it to a scratch dir,
# compares it with the live files, swaps the restored SaveGames in and waits for
# the game to report a successful world load. The original SaveGames dir is kept
# in a new root-only dir beside it; on any failure it is put back and the game
# restarted.
#
# Usage: sudo bash linux-game-server/backup/restore-drill.sh [--allow-players]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_DIR="$(dirname -- "$SCRIPT_DIR")"
readonly GAME_UNIT=dragonwilds.service
readonly UPDATE_TIMER=dragonwilds-auto-update.timer
readonly UPDATE_SERVICE=dragonwilds-auto-update.service
readonly BACKUP_UNIT=game-backup.service
readonly LOAD_TIMEOUT_SECONDS=600
readonly LOCK_FILE=/run/lock/dragonwilds-restore-drill.lock
# Recovery ignores TERM/INT/HUP, so each systemctl call it makes is killed after
# this long (the game's stop timeout is 120s). The game's own start may take far
# longer (TimeoutStartSec=5h: pre-update backup gate plus a Steam update); waiting
# that long while ignoring signals is worse, so a start still running after 15
# minutes is handed to the operator and the update timer is left off.
readonly RECOVERY_CALL_SECONDS=180
readonly RECOVERY_START_SECONDS=900

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
trap 'printf "error: restore-drill stopped at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR
log() { printf '[drill] %s\n' "$*"; }
stop_unit() {
  local unit="$1" state
  systemctl stop "$unit" || return 1
  state="$(systemctl show "$unit" -p ActiveState --value)" || return 1
  [[ "$state" == inactive ]]
}
stop_game() { stop_unit "$GAME_UNIT"; }
# The journal is read whole and its status checked before matching: a failed
# read that printed an older line must not count as this load.
world_loaded_since() {
  local journal
  journal="$(journalctl -u "$GAME_UNIT" --since "$1" --no-pager -o cat)" || return 1
  [[ "$journal" == *'World load SUCCEEDED'* ]]
}

allow_players=false
for arg in "$@"; do
  case "$arg" in
    --allow-players) allow_players=true ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ "$EUID" -eq 0 ]] || die "run with sudo (restic reaches the repository with root's SSH key)"
for tool in restic jq systemctl journalctl diff flock timeout stat; do
  command -v "$tool" >/dev/null || die "$tool is required"
done
exec 9>"$LOCK_FILE"
flock -n 9 || die "another restore drill is running"

install_dir="$(systemctl show "$GAME_UNIT" -p WorkingDirectory --value)"
game_user="$(systemctl show "$GAME_UNIT" -p User --value)"
game_group="$(systemctl show "$GAME_UNIT" -p Group --value)"
[[ -n "$install_dir" && -n "$game_user" ]] || die "cannot read $GAME_UNIT"
saved="$install_dir/RSDragonwilds/Saved"
live="$saved/SaveGames"
[[ -d "$live" && -d "$saved/Config" ]] || die "no world at $saved"
compgen -G "$live/*.sav" >/dev/null || die "no save in $live; a drill needs a world to restore and load"

status_json="$HOST_DIR/dragonwilds/status/dragonwilds-status.json"
if [[ "$allow_players" == false ]]; then
  jq -e '(.updated | fromdateiso8601) as $updated |
    .players == 0 and .status == "running" and
    (now - $updated >= 0 and now - $updated <= 120)' "$status_json" >/dev/null 2>&1 \
    || die "fresh online zero-player status (at most 120s old) required; refresh status or pass --allow-players"
fi

[[ -f "$SCRIPT_DIR/.env" ]] || die "missing $SCRIPT_DIR/.env"
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a
[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set in backup/.env"
export HOME=/root

# Device and inode alone are not enough: a freed inode is reused at once, so a
# dir made after the original was deleted can share it. Birth time tells them
# apart, so a filesystem that does not report it is refused before anything stops.
readonly IDENTITY_FORMAT='^[0-9]+:[0-9]+ [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)? [+-][0-9]{4}$'
dir_identity() {
  local id
  id="$(stat -c '%d:%i %w' -- "$1")" || return 1
  # GNU prints `-` for an unknown birth time; anything but a full timestamp
  # (empty, `-`, garbage) would leave only device:inode, so it is refused.
  [[ "$id" =~ $IDENTITY_FORMAT ]] || return 1
  printf '%s\n' "$id"
}
is_original() {
  local id
  [[ -d "$1" && ! -L "$1" ]] && id="$(dir_identity "$1" 2>/dev/null)" && [[ "$id" == "$original_id" ]]
}
original_id="$(dir_identity "$live")" \
  || die "cannot record the identity of $live; its filesystem must report birth time (stat %w)"

scratch="$(mktemp -d /root/restore-drill.XXXXXX)"
hold=""
aside=""
swapping=false
finished=false

# KILL, not TERM: recovery's children inherit its ignored TERM. Killing the
# client does not cancel a systemd job, so a timeout is reported, never trusted.
bounded() { local secs="$1"; shift; timeout -s KILL "$secs" "$@"; }
recovery_stop() {
  local unit="$1" state
  bounded "$RECOVERY_CALL_SECONDS" systemctl stop "$unit" || return 1
  state="$(bounded "$RECOVERY_CALL_SECONDS" systemctl show "$unit" -p ActiveState --value)" || return 1
  [[ "$state" == inactive ]]
}
# Says only what is known: a failed or timed-out systemctl may have left a unit
# running or a job queued.
manual() {
  printf '[drill] manual recovery required: %s. No further automatic recovery is attempted. Check %s, %s and %s and any pending systemd jobs before changing anything under %s. The snapshot restore, if any, is in %s%s\n' \
    "$1" "$GAME_UNIT" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$saved" "$scratch" "${hold:+; the aside dir of this drill is $hold}" >&2
}

recover() {
  [[ "$finished" == true ]] && return
  # A second signal must not cut a rollback short between deleting live and
  # moving the original back; every wait below is bounded instead.
  trap '' TERM INT HUP
  printf '[drill] FAILED; restoring the original world and restarting the game\n' >&2
  if ! bounded "$RECOVERY_CALL_SECONDS" systemctl stop "$UPDATE_TIMER" || ! recovery_stop "$UPDATE_SERVICE"; then
    manual "the updater could not be stopped"
    return 1
  fi
  # Decide from the directories, not the flags: the forward move may have failed
  # (live is still the original) or a signal may have landed right after it.
  # Only a dir with the original's identity is ever moved back over live.
  if [[ "$swapping" == true ]] && ! is_original "$live"; then
    recovery_stop "$GAME_UNIT" || { manual "$GAME_UNIT could not be verified stopped"; return 1; }
    # Checked after the stop, which can take minutes: the aside could change meanwhile.
    is_original "$aside" || { manual "the original world is not at $aside"; return 1; }
    rm -rf "$live" || { manual "could not remove the restored copy at $live"; return 1; }
    mv -T "$aside" "$live" || { manual "could not move $aside back to $live"; return 1; }
    # The aside path can still change between that check and the move.
    is_original "$live" || { manual "what was moved back to $live is not the original world, so the game was not started"; return 1; }
  fi
  if bounded "$RECOVERY_START_SECONDS" systemctl start "$GAME_UNIT"; then
    bounded "$RECOVERY_CALL_SECONDS" systemctl start "$UPDATE_TIMER" \
      || printf '[drill] could not start %s; start it by hand\n' "$UPDATE_TIMER" >&2
  else
    printf '[drill] %s did not start within %ss; its start job may still be running and succeed later. The original world is in place; %s was not restarted: once %s is up, start it by hand\n' \
      "$GAME_UNIT" "$RECOVERY_START_SECONDS" "$UPDATE_TIMER" "$GAME_UNIT" >&2
  fi
  [[ -z "$hold" ]] || rmdir -- "$hold" 2>/dev/null || true
  rm -rf "$scratch"
}
trap recover EXIT

log "stopping $UPDATE_TIMER and $GAME_UNIT"
systemctl stop "$UPDATE_TIMER"
stop_unit "$UPDATE_SERVICE" || die "could not verify $UPDATE_SERVICE stopped"
stop_game || die "could not verify $GAME_UNIT stopped"

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

is_original "$live" || die "$live changed during the drill"
swapping=true
# A fresh root-only dir: its name cannot collide and only root can write inside it.
hold="$(mktemp -d "$saved/.restore-drill.XXXXXX")"
aside="$hold/SaveGames"
log "swapping the restored SaveGames in (original kept at $aside)"
mv -T "$live" "$aside"
cp -a "$scratch$live" "$live"
chown -R "$game_user:${game_group:-$game_user}" "$live"

since="$(date '+%Y-%m-%d %H:%M:%S')"
log "starting $GAME_UNIT (its pre-update backup gate runs first)"
systemctl start "$GAME_UNIT"
deadline=$((SECONDS + LOAD_TIMEOUT_SECONDS))
until world_loaded_since "$since"; do
  (( SECONDS < deadline )) || die "no 'World load SUCCEEDED' within ${LOAD_TIMEOUT_SECONDS}s"
  state="$(systemctl show "$GAME_UNIT" -p ActiveState --value)"
  [[ "$state" == active || "$state" == activating ]] || die "$GAME_UNIT is $state while loading"
  sleep 5
done
log "game reported: World load SUCCEEDED"

systemctl start "$UPDATE_TIMER"
rm -rf "$scratch"
finished=true
log "PASSED: snapshot $snapshot restored identically and the game loaded it"
log "the pre-drill SaveGames is at $aside; remove $hold once you are satisfied"
