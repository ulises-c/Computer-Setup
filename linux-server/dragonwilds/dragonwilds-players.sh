#!/usr/bin/env bash
set -euo pipefail

# Print "<count>\t<names>" for the players connected right now.
#
# Shared by dragonwilds-status.sh (for the card) and dragonwilds-auto-update.sh
# (which must not restart the server while anyone is on). The auto-updater needs
# a live answer rather than whatever the status JSON last cached, so this stays a
# standalone read of the journal.
#
# The server publishes no query port and its EOS session attributes are written
# once at session creation, so the connection log is the only live source.
# Add/Remove pairs are authoritative: Remove fires on a timeout as well as a
# clean quit, so a crashed client leaves no phantom player behind.

UNIT="${1:-dragonwilds.service}"

started="$(systemctl show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null || true)"
state="$(systemctl show -p ActiveState --value "$UNIT" 2>/dev/null || true)"
if [[ "$state" != active || -z "$started" ]]; then
  printf '0\t\n'
  exit 0
fi

since="$(date -d "$started" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
if [[ -z "$since" ]]; then
  printf '0\t\n'
  exit 0
fi

# Exit non-zero rather than print 0 when the journal cannot be read: the
# auto-updater treats 0 as permission to restart. A running server logs heavily
# from its first second, so an empty read means no access (the user lacks the
# adm/systemd-journal group; journalctl may still exit 0), not an idle server.
if ! run_log="$(journalctl -u "$UNIT" --since "$since" --no-pager 2>/dev/null)" || [[ -z "$run_log" ]]; then
  printf 'error: cannot read the journal for %s\n' "$UNIT" >&2
  exit 1
fi

awk '
  /AddClientConnection: Added client connection/ {
    if (match($0, /RemoteAddr: [0-9.]+:[0-9]+/)) {
      a = substr($0, RSTART + 12, RLENGTH - 12); live[a] = 1; pending = a
    }
  }
  # "Join succeeded" carries no address, so the name is attributed to the
  # connection added immediately before it — best effort, unlike the count.
  /LogNet: Join succeeded: / {
    if (pending != "") { name[pending] = $NF; pending = "" }
  }
  /UNetDriver::RemoveClientConnection - Removed address/ {
    if (match($0, /address [0-9.]+:[0-9]+/)) {
      a = substr($0, RSTART + 8, RLENGTH - 8); delete live[a]; delete name[a]
    }
  }
  END {
    n = 0; list = ""
    for (a in live) { n++; list = list (list ? ", " : "") (name[a] ? name[a] : "?") }
    printf "%d\t%s\n", n, list
  }' <<< "$run_log"
