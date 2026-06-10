#!/usr/bin/env bash
# Unified setup entrypoint (UNIFICATION.md, issue #36).
# Usage: bash setup.sh [--optional] [--work] [--personal] [--dry-run]
#                      [--platform <macos|ubuntu|arch|server>] [--profile <desktop|server>]
#   --optional       also install low-priority optional packages
#   --work           also install work-only packages
#   --personal       also install personal-only packages
#   --dry-run        print all commands without executing anything
#   --platform <p>   force platform; default: auto-detect (uname / /etc/os-release).
#                    --distro <ubuntu|arch> is accepted as an alias.
#   --profile server headless server profile (apt only, no GUI packages);
#                    never auto-detected — Debian desktops and the Pi look alike.
#
# Package data lives in packages.json; the engine is lib/core.sh; per-platform
# quirks live in platforms/<platform>.sh.

set -euo pipefail

SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/core.sh
source "$SETUP_ROOT/lib/core.sh"

core_parse_args "$@"
core_detect_platform

# shellcheck source=/dev/null
source "$SETUP_ROOT/platforms/$PLATFORM.sh"

platform_main
