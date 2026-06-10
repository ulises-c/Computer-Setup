#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the check logic lives in the root
# verify.sh + lib/verify.sh, driven by the root packages.json.
# Usage: bash macOS/verify.sh [--optional] [--work] [--personal] [--all]
# Note: work-tagged packages now require --work (or --all), matching setup.sh;
# the legacy script checked them unconditionally.
exec bash "$(cd "$(dirname "$0")/.." && pwd)/verify.sh" --platform macos "$@"
