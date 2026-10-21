#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" == 0 ]]; then
  printf 'Run this as the normal user, not with sudo; it invokes sudo only for the firewall/data-directory steps.\n' >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
game_dir="$repo_root/linux-game-server"
for env_file in "$game_dir/2004scape/.env" "$game_dir/lostcity/.env" "$game_dir/rs-sdk/.env"; do
  [[ -f "$env_file" ]] || { printf 'Missing %s; run setup.sh first.\n' "$env_file" >&2; exit 2; }
  # shellcheck disable=SC1090
  source "$env_file"
done
lan_iface="${LAN_IFACE:-}"
lan_cidr="${LAN_CIDR:-}"
[[ -n "$lan_iface" && -n "$lan_cidr" ]] || {
  printf 'Set LAN_IFACE and LAN_CIDR in linux-game-server/2004scape/.env first.\n' >&2
  exit 2
}
lostcity_runtime="$LOSTCITY_RUNTIME_DIR"
rs_sdk_source="$RS_SDK_SOURCE_DIR"
rs_sdk_data="$RS_SDK_DATA_DIR"

[[ -f "$lostcity_runtime/engine/data/config/world.json" || -f "$lostcity_runtime/engine/.env" ]] || {
  printf 'Lost City bootstrap is incomplete; run linux-game-server/2004scape/setup.sh first.\n' >&2
  exit 2
}
[[ -d "$rs_sdk_source/.git" ]] || { printf 'Missing RS-SDK checkout: %s\n' "$rs_sdk_source" >&2; exit 2; }

# Never start wildcard-bound host-network listeners unless UFW is already
# enforcing default-deny inbound and SSH is explicitly allowed. Do not enable
# UFW or change its default policy here.
ufw_status="$(sudo ufw status verbose)"
[[ "$ufw_status" == *'Status: active'* ]] || { printf 'UFW is not active; refusing to start the game services.\n' >&2; exit 2; }
[[ "$ufw_status" == *'deny (incoming)'* || "$ufw_status" == *'reject (incoming)'* ]] || {
  printf 'UFW default incoming policy is not deny/reject; refusing to start the game services.\n' >&2
  exit 2
}
ufw_rules="$(sudo ufw status numbered)"
[[ "$ufw_rules" == *'22/tcp'* || "$ufw_rules" == *'OpenSSH'* ]] || {
  printf 'No explicit SSH allow rule was found; refusing to touch firewall policy.\n' >&2
  exit 2
}
python3 - "$ufw_rules" <<'PY'
import sys

rules = sys.argv[1]
ports = ("8888", "8080", "43594", "43595", "7781", "9444", "9445", "9446")
for line in rules.splitlines():
    if "ALLOW" not in line:
        continue
    if "Anywhere" not in line or "on tailscale0" in line:
        continue
    if any(f"{port}/tcp" in line for port in ports):
        print("A target port already has an unrestricted UFW allow rule; remove/restrict it before activation.", file=sys.stderr)
        raise SystemExit(2)
PY

# Host-network services require no Docker NAT rules. LAN web ports are limited
# to the verified home subnet; Tailscale HTTPS listeners are limited to tailscale0.
sudo ufw allow in on "$lan_iface" from "$lan_cidr" to any port 8888 proto tcp comment 'Lost City web LAN'
sudo ufw allow in on "$lan_iface" from "$lan_cidr" to any port 8080 proto tcp comment 'RS-SDK web LAN'
for port in 9444 9445 9446; do
  sudo ufw allow in on tailscale0 to any port "$port" proto tcp comment '2004Scape tailnet Serve'
done

# The bind-mounted RS-SDK data volume must be writable by the root-owned
# upstream entrypoint, but readable by the host's docker-group backup job.
if [[ ! -e "$rs_sdk_data" ]]; then
  sudo install -d -m 2770 -o root -g docker "$rs_sdk_data"
else
  owner="$(stat -c '%u' "$rs_sdk_data")"
  [[ "$owner" == 0 ]] || {
    printf 'Existing RS-SDK data directory is not root-owned; preserving it and refusing to change ownership.\n' >&2
    exit 2
  }
fi

# All expected web and game ports must be free before Compose starts.
listeners="$(ss -H -ltn)"
python3 - "$listeners" <<'PY'
import sys

ports = {"8888", "8080", "43594", "43595", "7781"}
for line in sys.argv[1].splitlines():
    fields = line.split()
    if len(fields) < 4:
        continue
    port = fields[3].rsplit(":", 1)[-1]
    if port in ports:
        print(f"TCP port {port} is already in use; refusing to start.", file=sys.stderr)
        raise SystemExit(2)
PY

bash "$game_dir/serve.sh"

# Verify the web listeners before granting direct access to protocol ports.
curl --fail --silent --show-error --retry 60 --retry-connrefused --retry-delay 2 \
  http://127.0.0.1:8888/rs2.cgi >/dev/null
curl --fail --silent --show-error --retry 60 --retry-connrefused --retry-delay 2 \
  http://127.0.0.1:8080/engine-status >/dev/null
curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 2 \
  http://127.0.0.1:7781/status >/dev/null

# Open raw game/gateway ports only if the expected process actually listens.
listeners="$(ss -H -ltn)"
for port in 43594 43595 7781; do
  if python3 - "$listeners" "$port" <<'PY'
import sys
port = sys.argv[2]
for line in sys.argv[1].splitlines():
    fields = line.split()
    if len(fields) >= 4 and fields[3].rsplit(":", 1)[-1] == port:
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    sudo ufw allow in on "$lan_iface" from "$lan_cidr" to any port "$port" proto tcp comment '2004Scape game LAN'
    sudo ufw allow in on tailscale0 to any port "$port" proto tcp comment '2004Scape game tailnet'
  fi
done

serve_status="$(tailscale serve status)"
python3 - "$serve_status" <<'PY'
import sys
status = sys.argv[1]
for port in ("9444", "9445", "9446"):
    if f":{port} (tailnet only)" not in status:
        print(f"Tailscale Serve port {port} is missing or not tailnet-only.", file=sys.stderr)
        raise SystemExit(1)
PY

lan_ip="$(ip -4 -o addr show dev "$lan_iface" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
domain="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
printf '\nLAN: Lost City http://%s:8888/rs2.cgi\n' "$lan_ip"
printf 'LAN: RS-SDK http://%s:8080/\n' "$lan_ip"
printf 'Tailnet: Lost City https://%s:9444/rs2.cgi\n' "$domain"
printf 'Tailnet: RS-SDK https://%s:9445/\n' "$domain"
printf 'Tailnet: RS-SDK gateway wss://%s:9446\n' "$domain"
printf '\nVerify current UFW rules and Tailscale Serve status before sharing access. No Funnel or router port-forwarding was configured.\n'
