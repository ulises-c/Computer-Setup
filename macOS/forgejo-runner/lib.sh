#!/usr/bin/env bash
# Shared constants + helpers for the Forgejo runner scripts (install/verify/run).
# Sourced, not executed. Paths mirror the live setup on the Mac mini.
# shellcheck disable=SC2034  # constants are consumed by the sourcing scripts
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Local, gitignored overrides (instance URL, etc.). Copy .env.example to .env
# and edit — keeps tailnet-specific values out of the committed repo.
[[ -f "$LIB_DIR/.env" ]] && source "$LIB_DIR/.env"

RUNNER_BIN="${RUNNER_BIN:-$HOME/.local/bin/forgejo-runner}"
CONFIG="${FORGEJO_RUNNER_CONFIG:-$HOME/forgejo-runner-config.yml}"
PLIST="$HOME/Library/LaunchAgents/net.forgejo.runner.plist"
LOG="$HOME/Library/Logs/forgejo-runner.log"
LABEL="net.forgejo.runner"

# Default Forgejo instance the runner talks to (Tailscale MagicDNS over HTTPS,
# terminated by the server's `tailscale serve` sidecar — no port).
# Set FORGEJO_INSTANCE_URL in .env (or the environment); the placeholder below
# is only a prompt hint. Discover your tailnet with:
#   tailscale status --json | jq -r '.MagicDNSSuffix'
DEFAULT_INSTANCE_URL="${FORGEJO_INSTANCE_URL:-https://forgejo.<tailnet>.ts.net}"

info()  { printf '  %s\n' "$*"; }
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
die()   { printf 'error: %s\n' "$*" >&2; exit 1; }

launchd_domain() { printf 'gui/%s' "$(id -u)"; }
