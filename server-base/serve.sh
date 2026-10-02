#!/usr/bin/env bash
set -euo pipefail

# Start a host's base containers and publish its web UIs under the host's own
# tailnet name, https://<host>.<tailnet>.ts.net/<service> (issue #86), with
# `tailscale serve` (tailnet only, never Funnel). Apps without base-path
# support get a dedicated HTTPS port on the same name instead.
#
#   bash server-base/serve.sh <host-dir>
#
# <host-dir>/serve.conf (bash) sets:
#   COMPOSE_DIRS  compose directories under <host-dir> to `up -d`
#   ROUTES        "<https-port> <mount-path> <target>" entries
#   RETIRED_PORTS HTTPS ports whose serve config is switched off
#   PRE_SERVE     optional command run from <host-dir> first (e.g. a scaffold)
#   WAIT_URL      optional loopback URL that must answer before serving

host_dir="$(cd -- "${1:?usage: bash serve.sh <host-dir>}" && pwd)"
COMPOSE_DIRS=()
ROUTES=()
RETIRED_PORTS=()
PRE_SERVE=()
WAIT_URL=""
# shellcheck source=/dev/null
source "$host_dir/serve.conf"

[[ "$(tailscale status --json | jq -r .BackendState)" == Running ]] || {
  printf 'error: authenticate this host with sudo tailscale up --operator="$USER" first\n' >&2
  exit 1
}
domain="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
[[ "$domain" =~ ^[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$ ]] || {
  printf 'error: unexpected tailnet name: %s\n' "$domain" >&2
  exit 1
}

if [[ -d "$host_dir/homepage" ]]; then
  bash "$(dirname -- "${BASH_SOURCE[0]}")/homepage/fetch-assets.sh" "$host_dir"
fi
if [[ ${#PRE_SERVE[@]} -gt 0 ]]; then
  (cd "$host_dir" && "${PRE_SERVE[@]}")
fi
for dir in "${COMPOSE_DIRS[@]}"; do
  sudo docker compose -f "$host_dir/$dir/docker-compose.yml" up -d
done

uses_cockpit=false
for route in "${ROUTES[@]}"; do
  [[ "$route" == *" /cockpit "* ]] && uses_cockpit=true
done
if [[ "$uses_cockpit" == true && -d /etc/cockpit ]]; then
  printf '[WebService]\nUrlRoot = /cockpit\nOrigins = https://%s wss://%s\nProtocolHeader = X-Forwarded-Proto\n' \
    "$domain" "$domain" | sudo tee /etc/cockpit/cockpit.conf >/dev/null
  sudo install -d -m 755 /etc/systemd/system/cockpit.socket.d
  printf '[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n' |
    sudo tee /etc/systemd/system/cockpit.socket.d/10-loopback.conf >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl stop cockpit.service 2>/dev/null || true
  sudo systemctl restart cockpit.socket
fi

if [[ -n "$WAIT_URL" ]]; then
  curl --fail --silent --show-error --retry 12 --retry-connrefused --retry-delay 2 "$WAIT_URL" >/dev/null
fi

# serve strips the mount path before proxying; a target that ends in a path
# re-adds it (Cockpit keeps its UrlRoot that way).
for route in "${ROUTES[@]}"; do
  read -r port path target <<< "$route"
  if [[ "$path" == /cockpit && ! -d /etc/cockpit ]]; then
    printf 'warning: Cockpit is not installed; skipping /cockpit\n' >&2
    continue
  fi
  if [[ "$path" == / ]]; then
    tailscale serve --bg --https="$port" "$target"
  else
    tailscale serve --bg --https="$port" --set-path "$path" "$target"
  fi
done
for port in "${RETIRED_PORTS[@]}"; do
  tailscale serve --https="$port" off >/dev/null 2>&1 || true
done
tailscale serve status
