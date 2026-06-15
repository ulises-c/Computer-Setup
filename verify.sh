#!/usr/bin/env bash
# Unified read-only install verification (UNIFICATION.md Phase 3, issue #36).
# Usage: bash verify.sh [--optional] [--work] [--personal] [--all]
#                       [--platform <macos|ubuntu|arch>]
#   --optional      also check low-priority optional packages
#   --work          also check work-only packages
#   --personal      also check personal-only packages
#   --all           check everything (implies --optional --work --personal
#                   + priority "none")
#   --platform <p>  force platform; default: auto-detect (uname /
#                   /etc/os-release). --distro is accepted as an alias.
#
# Mirrors setup.sh's selection logic, so the packages checked here match what
# `setup.sh` with the same flags would install. Read-only — installs nothing.

set -uo pipefail

SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/core.sh
source "$SETUP_ROOT/lib/core.sh"
# shellcheck source=lib/verify.sh
source "$SETUP_ROOT/lib/verify.sh"

verify_parse_args "$@"
core_detect_platform

verify_main
