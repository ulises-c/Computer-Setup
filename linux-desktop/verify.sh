#!/usr/bin/env bash
# Thin shim (UNIFICATION.md Phase 4): the check logic lives in the root
# verify.sh + lib/verify.sh, driven by the root packages.json. All flags are
# forwarded; the distro is auto-detected and --distro <ubuntu|arch> overrides.
# Usage: bash linux-desktop/verify.sh [--optional] [--work] [--personal]
#                                     [--all] [--distro <ubuntu|arch>]
if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'error: linux-desktop verify is Linux-only; use the root verify.sh\n' >&2
  exit 1
fi
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/verify.sh" "$@"
