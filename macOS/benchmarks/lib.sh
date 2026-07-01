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

ts_iso()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_file() { date +"%Y%m%d_%H%M%S"; }

# Stock macOS `openssl` is LibreSSL, which lacks `speed -seconds`; prefer the
# keg-only brew openssl@3 and accept a PATH openssl only if it is real OpenSSL.
resolve_openssl() {
  local cand
  for cand in "$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl" openssl; do
    command -v "$cand" >/dev/null 2>&1 || continue
    [[ "$("$cand" version 2>/dev/null)" == OpenSSL* ]] && { printf '%s' "$cand"; return 0; }
  done
  die "no OpenSSL with 'speed -seconds' support found (stock macOS ships LibreSSL) — brew install openssl@3"
}

ensure_results_dir() { mkdir -p "$RESULTS_DIR"; }
