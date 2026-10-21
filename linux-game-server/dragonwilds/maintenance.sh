#!/usr/bin/env bash
set -euo pipefail

readonly MAINTENANCE_DIR=/var/lib/dragonwilds-maintenance
readonly MAINTENANCE_MARKER="$MAINTENANCE_DIR/blocked"
readonly MAINTENANCE_LOCK="$MAINTENANCE_DIR/operation.lock"
readonly MAINTENANCE_UNIT_DIR=/etc/systemd/system
readonly MAINTENANCE_TIMERS=(dragonwilds-auto-update.timer dragonwilds-update-check.timer dragonwilds-player-log.timer)
readonly MAINTENANCE_SERVICES=(dragonwilds-auto-update.service dragonwilds-update-check.service dragonwilds-player-log.service dragonwilds.service)

maintenance_error() { printf 'error: %s\n' "$*" >&2; return 1; }
maintenance_property() { systemctl show "$1" --property="$2" --value; }

maintenance_stopped() {
  local unit state
  for unit in "$@"; do
    state="$(maintenance_property "$unit" ActiveState)"
    case "$state" in
      inactive|failed) ;;
      *) maintenance_error "$unit is $state; enter maintenance explicitly first"; return 1 ;;
    esac
    if [[ "$unit" == *.service && "$(maintenance_property "$unit" LoadState)" != not-found ]]; then
      [[ "$(maintenance_property "$unit" MainPID)" == 0 && "$(maintenance_property "$unit" ControlPID)" == 0 ]] || {
        maintenance_error "$unit still has a process"; return 1;
      }
    fi
  done
}

maintenance_owned() {
  [[ ! -L "$1" && "$(stat -c '%u:%a' "$1")" == "0:$2" ]] || {
    maintenance_error "unconfirmed root-owned maintenance path: $1"; return 1;
  }
}

maintenance_hold() {
  local mode="$1"
  maintenance_owned "$MAINTENANCE_DIR" 755
  maintenance_owned "$MAINTENANCE_LOCK" 644
  exec 8<"$MAINTENANCE_LOCK"
  flock "$mode" 8
}

maintenance_check() {
  local unit dropin object conditions
  maintenance_owned "$MAINTENANCE_DIR" 755
  [[ -f "$MAINTENANCE_MARKER" ]] || { maintenance_error 'maintenance marker is missing'; return 1; }
  maintenance_owned "$MAINTENANCE_MARKER" 644
  for unit in "${MAINTENANCE_TIMERS[@]}" "${MAINTENANCE_SERVICES[@]}"; do
    dropin="$MAINTENANCE_UNIT_DIR/$unit.d/90-maintenance.conf"
    maintenance_owned "$MAINTENANCE_UNIT_DIR/$unit.d" 755
    maintenance_owned "$dropin" 644
    [[ "$(<"$dropin")" == $'[Unit]\nConditionPathExists=!'"$MAINTENANCE_MARKER" ]] || {
      maintenance_error "invalid maintenance drop-in for $unit"; return 1;
    }
    if [[ "$(maintenance_property "$unit" LoadState)" != not-found ]]; then
      [[ "$(maintenance_property "$unit" NeedDaemonReload)" == no ]] || {
        maintenance_error "$unit needs daemon-reload"; return 1;
      }
      object="${unit//-/_2d}"
      object="${object//./_2e}"
      conditions="$(busctl get-property org.freedesktop.systemd1 "/org/freedesktop/systemd1/unit/$object" \
        org.freedesktop.systemd1.Unit Conditions)"
      [[ "$conditions" == *'"ConditionPathExists" false true "'"$MAINTENANCE_MARKER"'" '* ]] || {
        maintenance_error "maintenance condition is not loaded for $unit"; return 1;
      }
    fi
  done
  maintenance_stopped "${MAINTENANCE_TIMERS[@]}" "${MAINTENANCE_SERVICES[@]}"
}

maintenance_block() {
  local unit dropin
  sudo touch "$MAINTENANCE_MARKER"
  sudo chown root:root "$MAINTENANCE_MARKER"
  sudo chmod 644 "$MAINTENANCE_MARKER"
  for unit in "${MAINTENANCE_TIMERS[@]}" "${MAINTENANCE_SERVICES[@]}"; do
    dropin="$MAINTENANCE_UNIT_DIR/$unit.d/90-maintenance.conf"
    sudo install -d -o root -g root -m 755 "$MAINTENANCE_UNIT_DIR/$unit.d"
    printf '[Unit]\nConditionPathExists=!%s\n' "$MAINTENANCE_MARKER" | sudo tee "$dropin" >/dev/null
    sudo chown root:root "$dropin"
    sudo chmod 644 "$dropin"
  done
  sudo systemctl daemon-reload
}

maintenance_stop() {
  local unit
  for unit in "${MAINTENANCE_TIMERS[@]}" "${MAINTENANCE_SERVICES[@]}"; do
    if [[ "$(maintenance_property "$unit" LoadState)" != not-found ]]; then
      sudo systemctl stop "$unit"
    fi
  done
  maintenance_check
}

maintenance_release() {
  maintenance_check
  sudo rm -- "$MAINTENANCE_MARKER"
  [[ ! -e "$MAINTENANCE_MARKER" ]] || { maintenance_error 'maintenance marker was not removed'; return 1; }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 1 ]] || { maintenance_error 'usage: maintenance.sh enter|prepare|check|leave'; exit 1; }
  case "$1" in
    enter|prepare)
      [[ "$1" != prepare ]] || maintenance_stopped dragonwilds.service
      sudo install -d -o root -g root -m 755 "$MAINTENANCE_DIR"
      sudo touch "$MAINTENANCE_LOCK"
      sudo chown root:root "$MAINTENANCE_LOCK"
      sudo chmod 644 "$MAINTENANCE_LOCK"
      maintenance_hold -x
      [[ "$1" != prepare ]] || maintenance_stopped dragonwilds.service
      maintenance_block
      # A concurrent start before daemon-reload must not turn a bootstrap rerun into a stop.
      [[ "$1" != prepare ]] || maintenance_stopped dragonwilds.service
      maintenance_stop
      printf 'Maintenance entered; game and update jobs are quiescent. Guard survives reboot.\n'
      ;;
    check|leave)
      maintenance_hold -x
      if [[ "$1" == check ]]; then
        maintenance_check
        printf 'Maintenance guard confirmed; game and update jobs are quiescent.\n'
      else
        maintenance_release
        printf 'Maintenance left. Nothing was started; start the chosen host explicitly.\n'
      fi
      ;;
    *) maintenance_error 'usage: maintenance.sh enter|prepare|check|leave'; exit 1 ;;
  esac
fi
