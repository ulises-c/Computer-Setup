#!/usr/bin/env bash
# Stop and remove the fleet service container and its tailnet port. Keeps the data
# (~/.local/share/rs-fleet-service) and tokens (~/.config/rs-fleet-service); delete those by hand.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tailscale serve --https=9447 --yes off >/dev/null 2>&1 || true
docker compose --project-name rs-fleet-service --project-directory "$SCRIPT_DIR" -f "$SCRIPT_DIR/docker-compose.yml" down
