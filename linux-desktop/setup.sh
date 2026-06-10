#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the install logic lives in the root
# setup.sh + lib/core.sh + platforms/{ubuntu,arch}.sh, driven by the root
# packages.json. The distro is auto-detected; --distro <ubuntu|arch> overrides.
# Usage: bash linux-desktop/setup.sh [--optional] [--work] [--personal]
#                                    [--dry-run] [--distro <ubuntu|arch>]
exec bash "$(cd "$(dirname "$0")/.." && pwd)/setup.sh" "$@"
