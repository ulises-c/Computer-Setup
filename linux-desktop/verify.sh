#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the check logic lives in the root
# verify.sh + lib/verify.sh, driven by the root packages.json. The distro is
# auto-detected; --distro <ubuntu|arch> overrides.
# Usage: bash linux-desktop/verify.sh [--optional] [--work] [--personal]
#                                     [--all] [--distro <ubuntu|arch>]
exec bash "$(cd "$(dirname "$0")/.." && pwd)/verify.sh" "$@"
