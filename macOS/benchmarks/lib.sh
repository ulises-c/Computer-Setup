#!/usr/bin/env bash
# Shared helpers for benchmark scripts. Sourced, not executed directly.
# shellcheck disable=SC2034  # constants consumed by sourcing scripts
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESULTS_DIR="$BENCH_DIR/results"

info()  { printf '  %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }
header() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

check_dep()          { command -v "$1" >/dev/null 2>&1; }
check_dep_required() { check_dep "$1" || die "required: $1 — install with: brew install $1"; }
check_dep_optional() {
  if ! check_dep "$1"; then
    warn "optional dep missing: $1 (brew install $1) — skipping that section"
    return 1
  fi
}

ts_iso()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_file() { date +"%Y%m%d_%H%M%S"; }

ensure_results_dir() { mkdir -p "$RESULTS_DIR"; }
