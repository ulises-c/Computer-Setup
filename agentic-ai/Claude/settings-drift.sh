#!/usr/bin/env bash
# Compares the repo settings.json template against the live ~/.claude copy.
# Volatile machine state is ignored: .model is set per machine and changes
# with every model release. Key order is normalized (jq -S) because Claude
# Code re-serializes the live file on plugin installs and /config changes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$REPO_DIR/settings.json"
LIVE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

if [[ ! -f "$LIVE" ]]; then
  printf 'error: no live settings at %s — run install.sh first\n' "$LIVE" >&2
  exit 1
fi

normalize() { jq -S 'del(.model)' "$1"; }

if drift=$(diff -u --label template --label live <(normalize "$TEMPLATE") <(normalize "$LIVE")); then
  printf 'settings in sync (ignored volatile keys: model)\n'
else
  printf 'settings drift — commit it to the template or re-run install.sh:\n%s\n' "$drift"
  exit 1
fi
