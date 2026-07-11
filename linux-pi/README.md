# linux-pi — Raspberry Pi (`ollie-pi4`) node

Service stacks for the Raspberry Pi, deployed from this repo (clone + `docker
compose up -d`). Mirrors the `linux-server/<service>/` layout: each folder is a
Docker Compose stack with a committed `docker-compose.yml` / `.env.example` and
gitignored runtime dirs (`conf/ work/ ts-state/`) + `.env`.

## Why this node exists

The home network had a **single point of DNS failure**: the Ubuntu server ran the
only AdGuard Home. A network outage took it down and it couldn't self-heal (see
`linux-server/adguard` — the primary's Tailscale sidecar/netns coupling caused a
bootstrap deadlock, now fixed). This node adds a **secondary AdGuard Home** as a
backup resolver so DNS survives the server going down.

## `adguard/` — secondary AdGuard Home

- **Host-networked** (`network_mode: host`): owns `:53` (tcp+udp) and the `:80`
  admin UI directly on the Pi. **Independent of Tailscale** — DNS keeps serving
  LAN clients even if the tailnet/internet is down. This is the whole point; do
  not move AdGuard into the sidecar's netns the way the primary does.
- **`adguard-pi-ts`** — a *decoupled* Tailscale sidecar (its own netns) that
  serves only the HTTPS admin UI at `https://adguard-pi.<tailnet>.ts.net`,
  proxying `:443 -> host.docker.internal:80`. Carries the `dns: [9.9.9.10,
  1.1.1.1]` bootstrap guard. If this container is down, DNS is unaffected.

## `adguardhome-sync/` — config replication

[`bakito/adguardhome-sync`](https://github.com/bakito/adguardhome-sync) runs on
the Pi and pulls the primary's config (filters, rewrites, upstreams, rules,
services) into this replica on a cron, so the two stay in lockstep. DHCP sync is
disabled. Because the syncer runs here, the Pi re-pulls the latest config on
start; if the primary is down, the replica simply keeps its last-good config.

## `homepage/`, `motioneye/`, `cups/` — Pi dashboard + service front doors

The Pi is a *secondary server* (security cameras via MotionEye, printing via CUPS,
plus the backup AdGuard). These stacks surface it:

- `homepage/` — a homepage dashboard for the Pi (host-networked on `:3000`) with a
  decoupled `homepage-pi-ts` sidecar → `https://homepage-pi.<tailnet>.ts.net`. Its
  cards link to the Pi services, and it shows the Pi's own CPU/mem/disk/temp (the
  `resources` widget works because homepage runs on the Pi host).
- `motioneye/`, `cups/` — decoupled sidecars **only** (the services themselves
  already run on the Pi host, on `:8765` and `:631`). They add HTTPS front doors at
  `https://motioneye-pi.<tailnet>.ts.net` and `https://cups-pi.<tailnet>.ts.net`.

The **main server's** homepage links to the Pi dashboard and pings it (a
`siteMonitor` "Secondary Server (Pi)" card), driven by
`HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` in `linux-server/homepage/.env`.

### Sidecar → host hop (required for every Pi HTTPS front door)

Each sidecar proxies `:443 → host.docker.internal:<port>` from its own netns to the
host-networked service. This pattern works on the main server. If a Pi sidecar's
HTTPS URL times out **while the service answers on its host port**, that hop is the
culprit — usually an old Docker without `host-gateway` support, or `ufw` dropping
the docker-bridge→host path. Diagnose on the Pi:

```bash
docker exec <svc>-ts tailscale serve status
docker exec <svc>-ts sh -c 'getent hosts host.docker.internal; \
  wget -qO- -T5 http://host.docker.internal:<port>/ >/dev/null && echo OK || echo UNREACHABLE'
docker version --format '{{.Server.Version}}'
sudo ufw status
```

Fix it once (allow bridge→host / enable `host-gateway`) and every sidecar works.
CUPS additionally validates the `Host` header — if its admin pages 400 through the
proxy, add `ServerAlias *` to `cupsd.conf` and restart cups.

## Deploy runbook (on the Pi)

Prerequisites: Docker + compose plugin (`setup.sh --profile server` covers the
base, or install manually).

1. **Free port 53.** Debian's `systemd-resolved` stub may hold `:53`. Set
   `DNSStubListener=no` in resolved's config and restart it (or bind AdGuard to
   the Pi's LAN IP). Standard Pi-hole/AdGuard prerequisite.
2. **Bring up AdGuard:**
   ```bash
   cd linux-pi/adguard
   cp .env.example .env      # set TS_AUTHKEY
   docker compose up -d
   ```
   Complete the first-run wizard at `http://<pi-lan-ip>:3000` (set the admin
   user/password; configure the UI on `:80`). The UI then lives behind the
   sidecar at `https://adguard-pi.<tailnet>.ts.net`.
3. **Bring up sync:**
   ```bash
   cd ../adguardhome-sync
   cp .env.example .env      # set origin/replica URLs + creds
   docker compose up -d
   ```
   The Pi's filters/rewrites/upstreams should now match the primary.
4. **Wire failover on the router (`192.168.1.1`):** in its DHCP settings, set the
   DNS servers to `[<server-ip>, <pi-ip>]` (primary = server, secondary = Pi).
   Renew a client lease to pick it up.
5. **Bring up the Pi dashboard + service front doors:** for each of `homepage`,
   `motioneye`, `cups`: `cp .env.example .env`, set `TS_AUTHKEY` (and, for
   `homepage`, the `HOMEPAGE_VAR_*` domains + AdGuard creds), then
   `docker compose up -d`. The Pi dashboard is then at
   `https://homepage-pi.<tailnet>.ts.net`, and the main server's homepage shows a
   "Secondary Server (Pi)" card linking to it. (All Pi HTTPS front doors depend on
   the sidecar→host hop above.)

## Verification

```bash
dig @<pi-lan-ip> example.com +short          # resolves
dig @<pi-lan-ip> <a-blocked-domain> +short   # returns 0.0.0.0 (filtering works)
docker exec adguard-pi-ts tailscale status    # sidecar online
```
Resilience proof: stop `adguard-pi-ts` (or `tailscaled`) → `dig @<pi-lan-ip>`
still resolves, proving DNS is independent of Tailscale. Failover test: stop the
primary AdGuard and confirm a client still resolves via the Pi.

## Caveat: secondary DNS is not clean failover

OS resolvers treat multiple DHCP-provided nameservers inconsistently — some race
both, some only fall back after a timeout. A secondary buys **resilience, not
seamless behavior**. Running the *same* software (AdGuard) on both keeps ad-
filtering and split-DNS working whichever one answers.

## Privacy

Repo is public. Tracked files use placeholders (`<tailnet>`, `<pi-lan-ip>`,
`<server-ip>`); real IPs, hostnames, the tailnet suffix, auth keys, and AdGuard
credentials live only in gitignored `.env` files.
