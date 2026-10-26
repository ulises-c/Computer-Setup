#!/bin/bash
# Entrypoint of an extra RS-SDK world (world-compose.yml), in place of the
# image's /opt/server/entrypoint.sh. It mirrors that script (gateway supervisor,
# then the engine) minus what belongs to world 1 alone:
#   - no database migration: the SQLite database is world 1's, mounted read-write
#     only so this node can read hiscores and the login table (the login, friend
#     and logger servers that write it run inside world 1's container);
#   - no player-save symlink: with LOGIN_SERVER=true saves go through world 1's
#     login server, never this container's disk.
# An ISOLATED test world (isolated-compose.yml, WORLD_ISOLATED=true) is the
# opposite: its own servers and its own copy of world 1's data, so after
# world-node.js it runs the image's own entrypoint unchanged (backup, migrations,
# saves, gateway, engine) on that copy. It refuses a data dir without
# isolated-copy.sh's marker, so it never starts on world 1's own data.
# world-node.js patches the engine first; a patch that no longer matches upstream
# stops the start (set -e), so the world never runs unguarded.
set -euo pipefail

: "${WORLD_ID:?}" "${NODE_ID:?}"
[[ "$NODE_ID" =~ ^[0-9]+$ && "$NODE_ID" != 10 ]] \
  || { echo "[world] refusing: world $WORLD_ID's NODE_ID ($NODE_ID) must be a number other than world 1's node 10" >&2; exit 1; }

if [[ "${WORLD_ISOLATED:-}" == true ]]; then
  [[ -f /opt/server/data/ISOLATED-COPY ]] \
    || { echo "[world] refusing: isolated world $WORLD_ID needs its own data copy (no ISOLATED-COPY marker)" >&2; exit 1; }
  [[ "${EASY_STARTUP:-}" == true && "${LOGIN_PORT:-43510}" != 43510 ]] \
    || { echo "[world] refusing: an isolated world runs its own login server, never world 1's (43510)" >&2; exit 1; }
  [[ "${WORLD_ALLOWLIST_ENABLED:-}" == true ]] \
    || { echo "[world] refusing: an isolated world always has its allowlist on" >&2; exit 1; }
  bun /opt/world/world-node.js /opt
  mkdir -p "${WORLD_SAVE_BACKUP_DIR:-/opt/world-state/save-backups}"
  echo "[world] world $WORLD_ID ISOLATED: own login server :${LOGIN_PORT}, own data copy ($(grep '^copied_at=' /opt/server/data/ISOLATED-COPY)); gateway ${AGENT_PORT:?}/${GATEWAY_PUBLIC_PORT:?}, web ${WEB_PORT:?}, game ${NODE_PORT:?}"
  exec /opt/server/entrypoint.sh
fi

[[ "${EASY_STARTUP:-}" == false && "${LOGIN_SERVER:-}" == true ]] \
  || { echo "[world] refusing: an extra world needs EASY_STARTUP=false and LOGIN_SERVER=true (shared login server)" >&2; exit 1; }
[[ -f /opt/server/data/db.sqlite ]] || { echo "[world] refusing: world 1's database is not mounted" >&2; exit 1; }

bun /opt/world/world-node.js /opt

ln -sfn /opt/server/data/db.sqlite /opt/server/engine/db.sqlite
mkdir -p "${WORLD_SAVE_BACKUP_DIR:-/opt/world-state/save-backups}"

echo "[world] world $WORLD_ID: gateway on ${AGENT_PORT:?}/${GATEWAY_PUBLIC_PORT:?}, web ${WEB_PORT:?}, game ${NODE_PORT:?}, login server ${LOGIN_HOST:?}:${LOGIN_PORT:?}"
(
    cd /opt/server/gateway
    while true; do
        bun run gateway.ts || true
        echo "[world] gateway exited, restarting in 2s..." >&2
        sleep 2
    done
) &

cd /opt/server/engine
exec bun run src/app.ts
