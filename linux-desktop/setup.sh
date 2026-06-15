#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the install logic lives in the root
# setup.sh + lib/core.sh + platforms/{ubuntu,arch}.sh, driven by the root
# packages.json. All flags are forwarded; the distro is auto-detected and
# --distro <ubuntu|arch> overrides.
# Usage: bash linux-desktop/setup.sh [--optional] [--work] [--personal]
#                                    [--dry-run] [--distro <ubuntu|arch>]
if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'error: linux-desktop setup is Linux-only; use the root setup.sh\n' >&2
  exit 1
fi
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/setup.sh" "$@"
