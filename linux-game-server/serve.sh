#!/usr/bin/env bash
set -euo pipefail

# Start this host's containers and publish every web UI on the host's own
# tailnet name with `tailscale serve` (tailnet only, never Funnel).

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_DIRS=(homepage glances portainer watchtower uptime-kuma)

[[ "$(tailscale status --json | jq -r .BackendState)" == Running ]] || {
  printf 'error: authenticate this host with sudo tailscale up first\n' >&2
  exit 1
}
domain="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
[[ "$domain" =~ ^[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$ ]] || {
  printf 'error: unexpected tailnet name: %s\n' "$domain" >&2
  exit 1
}

python3 "$SCRIPT_DIR/scaffold.py"
for dir in "${COMPOSE_DIRS[@]}"; do
  sudo docker compose -f "$SCRIPT_DIR/$dir/docker-compose.yml" up -d
done

if [[ -d /etc/cockpit ]]; then
  printf '[WebService]\nOrigins = https://%s:10000 wss://%s:10000\nProtocolHeader = X-Forwarded-Proto\n' \
    "$domain" "$domain" | sudo tee /etc/cockpit/cockpit.conf >/dev/null
  sudo install -d -m 755 /etc/systemd/system/cockpit.socket.d
  printf '[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n' |
    sudo tee /etc/systemd/system/cockpit.socket.d/10-loopback.conf >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl stop cockpit.service 2>/dev/null || true
  sudo systemctl restart cockpit.socket
fi

curl --fail --silent --show-error --retry 12 --retry-connrefused --retry-delay 2 \
  http://127.0.0.1:3000/ >/dev/null
tailscale serve --bg --https=443 http://127.0.0.1:3000
tailscale serve --bg --https=8443 http://127.0.0.1:61208
tailscale serve --bg --https=9443 http://127.0.0.1:9000
tailscale serve --bg --https=3443 http://127.0.0.1:3001
if [[ -d /etc/cockpit ]]; then
  tailscale serve --bg --https=10000 https+insecure://127.0.0.1:9090
fi
tailscale serve status
