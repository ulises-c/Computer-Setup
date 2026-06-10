#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the install logic lives in the root
# setup.sh + lib/core.sh + platforms/macos.sh, driven by the root packages.json.
# All flags are forwarded (see ../setup.sh for the full list); the trailing
# --platform pin wins over any forwarded platform flag, so this entrypoint
# always runs the macOS flow.
# Usage: bash macOS/setup.sh [--optional] [--work] [--personal] [--dry-run]
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/setup.sh" "$@" --platform macos
