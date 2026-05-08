#!/usr/bin/env bash
# Tailscale setup script for Ubuntu Server
# Usage: bash linux-server/setup_tailscale.sh [--ssh] [--advertise-exit-node]
#   --ssh                  enable Tailscale SSH (replaces standard SSH for Tailscale peers)
#   --advertise-exit-node  advertise this server as an exit node
#   --dry-run              print commands without executing

set -euo pipefail

USE_SSH=false
EXIT_NODE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --ssh)                  USE_SSH=true ;;
    --advertise-exit-node)  EXIT_NODE=true ;;
    --dry-run)              DRY_RUN=true ;;
  esac
done

run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

# ── Install ───────────────────────────────────────────────────────────────────
if ! command -v tailscale &>/dev/null; then
  echo "==> Installing Tailscale..."
  run curl -fsSL https://tailscale.com/install.sh | sudo sh
else
  echo "==> Tailscale already installed ($(tailscale version | head -1))"
fi

# ── Build tailscale up args ───────────────────────────────────────────────────
UP_ARGS=()
[[ "$USE_SSH" == true ]] && UP_ARGS+=("--ssh")
[[ "$EXIT_NODE" == true ]] && UP_ARGS+=("--advertise-exit-node")

# ── Authenticate ──────────────────────────────────────────────────────────────
STATUS="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo 'unknown')"

if [[ "$STATUS" == "Running" ]]; then
  echo "==> Tailscale is already authenticated and running."
  if [[ ${#UP_ARGS[@]} -gt 0 ]]; then
    echo "==> Applying additional flags: ${UP_ARGS[*]}"
    run sudo tailscale up "${UP_ARGS[@]}"
  fi
else
  echo "==> Starting Tailscale — a login URL will appear below."
  echo "    Open it in a browser to authenticate this device."
  echo ""
  run sudo tailscale up "${UP_ARGS[@]}"
fi

# ── Status ────────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == false ]]; then
  echo ""
  echo "==> Tailscale status:"
  tailscale status
fi

echo ""
echo "Done. This server is now accessible on your Tailnet."
[[ "$USE_SSH" == true ]] && echo "Tailscale SSH is enabled — you can SSH via Tailscale IP or MagicDNS hostname."
