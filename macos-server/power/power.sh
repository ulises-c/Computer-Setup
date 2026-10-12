#!/usr/bin/env bash
set -euo pipefail

# Server power policy for the Mac mini, replacing Caffeine: never sleep, start
# again after a power cut or a freeze, wake on LAN. The display may still sleep.
#
#   bash macos-server/power/power.sh --check     # compare, no sudo; exit 1 on drift
#   bash macos-server/power/power.sh --dry-run   # print the commands
#   bash macos-server/power/power.sh             # apply (asks for sudo)

WANT=(sleep 0 disksleep 0 displaysleep 10 standby 0 autorestart 1 womp 1 tcpkeepalive 1)

mode="${1:-apply}"
case "$mode" in
  apply|--check|--dry-run) ;;
  *) printf 'usage: bash %s [--check|--dry-run]\n' "$0" >&2; exit 1 ;;
esac

current() {
  pmset -g custom | awk -v k="$1" '$1 == k { print $2; exit }'
}

drift=0
for ((i = 0; i < ${#WANT[@]}; i += 2)); do
  key="${WANT[i]}" want="${WANT[i + 1]}"
  have="$(current "$key")"
  if [[ "$have" == "$want" ]]; then
    printf '  ok     %-13s %s\n' "$key" "$have"
  else
    printf '  change %-13s %s -> %s\n' "$key" "${have:-unset}" "$want"
    drift=1
  fi
done
restart_freeze="$(systemsetup -getrestartfreeze 2>/dev/null || true)"
printf '  %s\n' "${restart_freeze:-restart after freeze: needs sudo to read}"

case "$mode" in
  --check) exit "$drift" ;;
  --dry-run)
    printf '[dry-run] sudo pmset -a %s\n' "${WANT[*]}"
    printf '[dry-run] sudo systemsetup -setrestartfreeze on\n'
    ;;
  apply)
    sudo pmset -a "${WANT[@]}"
    sudo systemsetup -setrestartfreeze on >/dev/null
    printf 'applied; Caffeine is no longer needed (quit it and remove it from Login Items)\n'
    ;;
esac
