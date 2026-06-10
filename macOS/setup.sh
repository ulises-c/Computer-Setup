#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the install logic lives in the root
# setup.sh + lib/core.sh + platforms/macos.sh, driven by the root packages.json.
# Usage: bash macOS/setup.sh [--optional] [--work] [--personal] [--dry-run]
exec bash "$(cd "$(dirname "$0")/.." && pwd)/setup.sh" --platform macos "$@"
