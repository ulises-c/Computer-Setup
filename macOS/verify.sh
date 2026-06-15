#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the check logic lives in the root
# verify.sh + lib/verify.sh, driven by the root packages.json. All flags are
# forwarded (see ../verify.sh); the trailing --platform pin wins over any
# forwarded platform flag, so this entrypoint always checks the macOS set.
# Note: work-tagged packages now require --work (or --all), matching setup.sh;
# the legacy script checked them unconditionally.
# Usage: bash macOS/verify.sh [--optional] [--work] [--personal] [--all]
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/verify.sh" "$@" --platform macos
