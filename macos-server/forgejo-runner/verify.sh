#!/usr/bin/env bash
# Read-only health check for the Forgejo runner. Exits non-zero if any check
# fails. Mirrors the failure mode that took the runner down after a reboot:
# the configured instance URL no longer matched where Forgejo actually listens.
#
# Usage: bash verify.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=macOS/forgejo-runner/lib.sh
source "$HERE/lib.sh"

failures=0

printf 'Forgejo runner health check\n\n'

# 1. Binary
if [[ -x "$RUNNER_BIN" ]]; then
  ok "binary: $RUNNER_BIN ($("$RUNNER_BIN" --version 2>&1 | head -1))"
else
  fail "binary missing: $RUNNER_BIN"; failures=$((failures + 1))
fi

# 2. Config + endpoint
configured_url=""
if [[ -f "$CONFIG" ]]; then
  configured_url="$(grep -m1 -E '^[[:space:]]*url:' "$CONFIG" | sed -E 's/^[[:space:]]*url:[[:space:]]*//')"
  if [[ -n "$configured_url" ]]; then
    ok "config: $CONFIG (instance: $configured_url)"
  else
    fail "config has no server.connections url: $CONFIG"; failures=$((failures + 1))
  fi
else
  fail "config missing: $CONFIG"; failures=$((failures + 1))
fi

# 3. LaunchAgent installed
if [[ -f "$PLIST" ]]; then
  ok "LaunchAgent installed: $PLIST"
else
  fail "LaunchAgent missing: $PLIST"; failures=$((failures + 1))
fi

# 4. Daemon loaded + running
state="$(launchctl list "$LABEL" 2>/dev/null || true)"
if [[ -n "$state" ]]; then
  pid="$(printf '%s' "$state" | sed -nE 's/.*"PID" = ([0-9]+);.*/\1/p')"
  exit_status="$(printf '%s' "$state" | sed -nE 's/.*"LastExitStatus" = ([0-9]+);.*/\1/p')"
  if [[ -n "$pid" ]]; then
    ok "daemon running (PID $pid)"
  else
    fail "daemon loaded but not running (LastExitStatus=${exit_status:-?}) — see: $LOG"
    failures=$((failures + 1))
  fi
else
  fail "daemon not loaded — run: bash $HERE/run.sh start"; failures=$((failures + 1))
fi

# 5. Instance reachable (the exact thing that broke)
if [[ -n "$configured_url" ]]; then
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$configured_url/api/v1/version" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    ok "instance reachable: $configured_url (HTTP 200)"
  else
    fail "instance NOT reachable: $configured_url (HTTP $code)"
    info "  fix: make sure the url's host matches the server's ROOT_URL"
    info "  (served over HTTPS by the tailscale serve sidecar; see linux-server/forgejo/docker-compose.yml)"
    failures=$((failures + 1))
  fi
fi

# 6. Declared more recently than it last failed to connect. Compares log
#    positions so stale 'connection refused' spam from before a fix doesn't
#    register as a current failure.
if [[ -f "$LOG" ]]; then
  last_declared="$(grep -n 'declared successfully' "$LOG" | tail -1 | cut -d: -f1)"
  last_refused="$(grep -n 'connection refused' "$LOG" | tail -1 | cut -d: -f1)"
  if [[ -n "$last_declared" && ( -z "$last_refused" || "$last_declared" -gt "$last_refused" ) ]]; then
    ok "runner declared successfully after its last connection error"
  elif [[ -n "$last_refused" ]]; then
    fail "log's latest connection state is 'connection refused' — can't reach the instance"
    failures=$((failures + 1))
  else
    info "log present but no declare line yet: $LOG"
  fi
fi

printf '\n'
if [[ "$failures" -eq 0 ]]; then
  ok "all checks passed"
else
  fail "$failures check(s) failed"
fi
exit "$failures"
