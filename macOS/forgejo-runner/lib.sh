#!/usr/bin/env bash
# Shared constants + helpers for the Forgejo runner scripts (install/verify/run).
# Sourced, not executed. Paths mirror the live setup on the Mac mini.
# shellcheck disable=SC2034  # constants are consumed by the sourcing scripts
set -euo pipefail

RUNNER_BIN="${RUNNER_BIN:-$HOME/.local/bin/forgejo-runner}"
CONFIG="${FORGEJO_RUNNER_CONFIG:-$HOME/forgejo-runner-config.yml}"
PLIST="$HOME/Library/LaunchAgents/net.forgejo.runner.plist"
LOG="$HOME/Library/Logs/forgejo-runner.log"
LABEL="net.forgejo.runner"

# Default Forgejo instance the runner talks to (Tailscale MagicDNS, port 3000).
# Override with FORGEJO_INSTANCE_URL. Discover the tailnet with:
#   tailscale status --json | jq -r '.MagicDNSSuffix'
DEFAULT_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-http://forgejo.tail01d63b.ts.net:3000}"

info()  { printf '  %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

launchd_domain() { printf 'gui/%s' "$(id -u)"; }
