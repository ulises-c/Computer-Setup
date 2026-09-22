#!/usr/bin/env bash
set -euo pipefail

# Record the latest public build of the dedicated server so the status card can
# flag an available update. Run on a timer rather than from the 1-minute status
# script: this one talks to Steam over the network.
#
# The result is written to a small file that dragonwilds-status.sh reads; it
# never touches the install itself. Updates are applied by the service's
# ExecStartPre on the next restart.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${DRAGONWILDS_INSTALL_DIR:=$HOME/games/dragonwilds}"
: "${STEAMCMD:=/usr/games/steamcmd}"
: "${LATEST_BUILD_FILE:=$SCRIPT_DIR/status/.latest-build}"

readonly APPID=4019830
lock="$DRAGONWILDS_INSTALL_DIR/.steamcmd.lock"

[[ -x "$STEAMCMD" ]] || { printf 'error: %s not found\n' "$STEAMCMD" >&2; exit 1; }

# The service runs steamcmd from its own ExecStartPre; two instances sharing
# ~/.steam can trip over each other, so both take this lock.
mkdir -p "$(dirname "$lock")"
exec 9>"$lock"
if ! flock -w 300 9; then
  printf 'error: timed out waiting for the steamcmd lock\n' >&2
  exit 1
fi

# Only "branches" carries a buildid; depot entries have manifest ids instead.
latest="$(timeout 240 "$STEAMCMD" +login anonymous +app_info_update 1 \
  +app_info_print "$APPID" +quit 2>/dev/null \
  | grep -A6 '"branches"' | grep -oE '"buildid"[[:space:]]+"[0-9]+"' \
  | grep -oE '[0-9]+' | head -1 || true)"

if [[ ! "$latest" =~ ^[0-9]+$ ]]; then
  printf 'error: could not read the public buildid from steamcmd\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$LATEST_BUILD_FILE")"
tmp="$(mktemp "$(dirname "$LATEST_BUILD_FILE")/.build.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s %s\n' "$latest" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$LATEST_BUILD_FILE"
trap - EXIT

printf 'latest public build: %s\n' "$latest"
