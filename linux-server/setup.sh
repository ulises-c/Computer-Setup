#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the install logic lives in the root
# setup.sh + lib/core.sh + platforms/server.sh, driven by the root
# packages.json. All flags are forwarded (see ../setup.sh); the trailing
# --platform pin wins over any forwarded platform flag, so this entrypoint
# always runs the server flow.
# Usage: bash linux-server/setup.sh [--optional] [--dry-run]
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/setup.sh" "$@" --platform server
