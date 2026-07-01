#!/usr/bin/env bash
# Shared helpers for benchmark scripts. Sourced, not executed directly.
# shellcheck disable=SC2034  # constants consumed by sourcing scripts
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RESULTS_DIR="$BENCH_DIR/results"
SUITE_VERSION="1.0.0"

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

ensure_results_dir() {
  mkdir -p "$RESULTS_DIR"
  # A sudo run (stress-test.sh, for powermetrics) must not leave results/
  # root-owned — later non-sudo suites would finish their whole run and then
  # die writing the result file
  [[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$RESULTS_DIR"
  return 0
}

# bench_init <suite> — shared suite prologue: creates results/, captures
# SYSINFO, sets HOSTNAME_SHORT / STAMP / OUTFILE, prints the system banner.
bench_init() {
  local suite="$1"
  ensure_results_dir
  SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
  HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
  STAMP=$(ts_file)
  OUTFILE="$RESULTS_DIR/${suite}_${HOSTNAME_SHORT}_${STAMP}.json"
  printf '\n'
  ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB | macOS $(printf '%s' "$SYSINFO" | jq -r '.macos_version')"
  info "Results will be written to: $OUTFILE"
}

# openssl_sha256_kbs <seconds> [ncpu] — sha256 16k-block throughput in KB/s
# via `openssl speed`; prints nothing if the output is unparseable. Requires
# OPENSSL_BIN (resolve_openssl). No-arrays branch: bash 3.2 + set -u errors
# on expanding an empty array.
openssl_sha256_kbs() {
  local secs="$1" ncpu="${2:-}" raw
  if [[ -n "$ncpu" ]]; then
    raw=$("$OPENSSL_BIN" speed -elapsed -seconds "$secs" -multi "$ncpu" sha256 2>&1 || true)
  else
    raw=$("$OPENSSL_BIN" speed -elapsed -seconds "$secs" sha256 2>&1 || true)
  fi
  printf '%s\n' "$raw" | awk '/^sha256/{gsub(/k$/,"",$7); printf "%.0f", $7+0}'
}
