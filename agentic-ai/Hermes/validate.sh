#!/usr/bin/env bash
# Post-install health check for install.sh, plus the skill-sync checks from
# `hermes-config verify` once .env exists. Exit 0 = all checks passed.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
ERRORS=0

pass() { printf '  [ OK ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1" >&2; ERRORS=$(( ERRORS + 1 )); }
warn() { printf '  [WARN] %s\n' "$1"; }

check_link() {
  if [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; then pass "$1 → $2"; else fail "$1 is not a symlink to $2"; fi
}

printf '=== links ===\n'
check_link "$HOME/.local/bin/hermes-config" "$REPO_DIR/bin/hermes-config"
for widget in "$REPO_DIR"/tui-widgets/*.mjs; do
  check_link "$HERMES_HOME_DIR/tui-widgets/$(basename "$widget")" "$widget"
done

printf '\n=== tools ===\n'
for tool in hermes jq git; do
  if command -v "$tool" >/dev/null; then pass "$tool"; else fail "$tool not on PATH"; fi
done
if command -v codeburn >/dev/null; then pass "codeburn (widget data source)"; else warn "codeburn not on PATH; the codeburn widget will show an error"; fi

if [[ -f "$REPO_DIR/.env" ]]; then
  printf '\n=== skill sync ===\n'
  "$REPO_DIR/bin/hermes-config" verify || ERRORS=$(( ERRORS + 1 ))
  printf '\n=== nightly sync ===\n'
  cron_script="$HERMES_HOME_DIR/scripts/hermes-config-sync.sh"
  if grep -qF "$REPO_DIR/bin/hermes-config sync" "$cron_script" 2>/dev/null; then pass "cron script $cron_script"; else fail "cron script missing or stale; run: hermes-config install"; fi
  if hermes cron list 2>/dev/null | grep -q 'Script: *hermes-config-sync.sh'; then pass "cron job scheduled"; else warn "no cron job runs hermes-config-sync.sh (see README: Nightly commit + push)"; fi
else
  warn "no .env; skill sync not configured (see .env.example)"
fi

printf '\n'
if (( ERRORS )); then printf 'validate: %d failure(s)\n' "$ERRORS" >&2; exit 1; fi
printf 'validate: all checks passed\n'
