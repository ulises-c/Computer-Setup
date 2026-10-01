# linux-pi — Raspberry Pi (`<pi-hostname>`) node

Service stacks for the Raspberry Pi, deployed from this repo (clone + `docker
compose up -d`). Mirrors the `linux-server/<service>/` layout: each folder is a
Docker Compose stack with a committed `docker-compose.yml` / `.env.example` and
gitignored runtime dirs (`conf/ work/`) + `.env`.

## Why this node exists

The home network had a **single point of DNS failure**: the Ubuntu server ran the
only AdGuard Home. A network outage took it down and it couldn't self-heal (see
`linux-server/adguard` — the primary's Tailscale sidecar/netns coupling caused a
bootstrap deadlock, now fixed). This node adds a **secondary AdGuard Home** as a
backup resolver so DNS survives the server going down.

## Tailnet access: one node, host `tailscale serve`

The Pi is **one tailnet node**: the host's own tailscaled, tagged `tag:pi`. It
publishes every Pi web service with host `tailscale serve`, from the template
[`tailscale-serve/serve.json`](tailscale-serve/serve.json), applied by the
shared script `../scripts/ts-serve-apply.sh` (the same script the server uses;
see `../linux-server/HTTPS.md` and `docs/ONE_NODE_PER_HOST.md` section 3).
There are no per-service Tailscale sidecars, auth keys or `ts-state/`
directories. Adding a Pi service means adding a handler to the template and
re-running the script; it adds no node.

| Service | Front door | Backend (host) |
|---|---|---|
| homepage | `https://<pi-hostname>.<tailnet>.ts.net/` | `127.0.0.1:3001` |
| motioneye | `https://<pi-hostname>.<tailnet>.ts.net/motioneye/` | `127.0.0.1:8765` (prefix stripped) |
| adguard (web UI) | `https://<pi-hostname>.<tailnet>.ts.net:8443` | `127.0.0.1:80` |
| cups | `https://<pi-hostname>.<tailnet>.ts.net:8449` | `127.0.0.1:8631` shim → `:631` ([`cups/README.md`](cups/README.md)) |

Ports `8443` and `8449` come from the shared registry in
`../linux-server/HTTPS.md`; a service uses the same port on every host.
DNS (`:53`) and IPP printing on the LAN (`:631`) never go through serve.

### Host node setup (one time)

1. If the Pi has no host tailscaled yet, install it with the official Linux
   installer ([KB 1031](https://tailscale.com/kb/1031/install-linux)), then:

   ```bash
   sudo tailscale up --advertise-tags=tag:pi --accept-dns=false
   ```

   Open the printed login URL (HUMAN). `--accept-dns=false` keeps the Pi's
   own resolver, so DNS on the Pi never depends on Tailscale. If it already
   runs one, apply `tag:pi` on the admin console's Machines page instead.
   Either way, disable key expiry for the node there (HUMAN).
2. Let your user run serve without sudo, and install `jq`:

   ```bash
   sudo tailscale set --operator="$USER"
   sudo apt install jq
   ```

3. Admin console, DNS page: **MagicDNS** and **HTTPS certificates** on.

### Applying the serve config

```bash
cd <repo>/linux-pi/tailscale-serve
(umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
cd <repo>
scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json --dry-run
scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json
```

`.env` holds the two render values (`.env.example` shows the format); the
script rejects a value that differs from the live node. `--dry-run` runs only
read-only `tailscale` commands and prints the rendered template, a diff
against the live serve config, and the write it would make. The template has
no Services, so it needs no `--services` flag. Re-running prints `up to date`.
The serve config lives in tailscaled's state, so it survives reboots.

### First HTTPS request provisions a cert (may hang once)

The **first** hit to `https://<pi-hostname>.<tailnet>.ts.net` (any port) makes
tailscaled provision a Let's Encrypt cert for the node. Until it finishes
(seconds up to ~a minute) the TLS handshake hangs and clients time out — this
is **not** a misconfiguration. Wait and retry:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<pi-hostname>.<tailnet>.ts.net/
```

## `adguard/` — secondary AdGuard Home

- **Host-networked** (`network_mode: host`): owns `:53` (tcp+udp) and the `:80`
  admin UI directly on the Pi. **Independent of Tailscale** — DNS keeps serving
  LAN clients even if the tailnet/internet is down. This is the whole point; do
  not put AdGuard behind any Tailscale component.
- The admin UI is on the tailnet at `https://<pi-hostname>.<tailnet>.ts.net:8443`
  through host serve. If tailscaled is down, only that URL is affected.

## `adguardhome-sync/` — config replication

[`bakito/adguardhome-sync`](https://github.com/bakito/adguardhome-sync) runs on
the Pi and pulls the primary's config (filters, rewrites, upstreams, rules,
services) into this replica on a cron, so the two stay in lockstep. DHCP sync is
disabled. The origin is the server's AdGuard port,
`https://<server>.<tailnet>.ts.net:8443`. Because the syncer runs here, the Pi
re-pulls the latest config on start; if the primary is down, the replica simply
keeps its last-good config.

## `homepage/`, `cups/`, MotionEye — Pi dashboard and services

The Pi is a *secondary server* (security cameras via MotionEye, printing via CUPS,
plus the backup AdGuard):

- `homepage/` — a homepage dashboard for the Pi (host-networked on `:3001`) at
  the root of the Pi node. Its cards link to the Pi services' front doors
  (built from `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN`), and it shows the Pi's own
  CPU/mem/disk/temp (the `resources` widget works because homepage runs on the
  Pi host). Widgets and `siteMonitor`s for Pi services call the loopback
  backends.
- MotionEye runs as a host service on `:8765`; serve publishes it at
  `/motioneye/`. It has no stack in this repo.
- `cups/` — host CUPS on `:631`, its reviewed policy installer, and the
  `cups-proxy` Host-rewrite shim on `127.0.0.1:8631` that the `:8449` front
  door needs. See [`cups/README.md`](cups/README.md).

The **main server's** homepage links to the Pi dashboard and pings it (a
`siteMonitor` "Secondary Server (Pi)" card), driven by
`HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` in `linux-server/homepage/.env`, which holds
the Pi node's name.

For CUPS, use the reviewed policy installer. Family LAN/WLAN clients are allowed
to print through the root location; administrative locations remain limited to
localhost. Put the real aliases and canonical private LAN subnet only in the
gitignored `.env`:

```bash
cd linux-pi/cups
cp .env.example .env
# edit .env privately
chmod 600 .env
bash test-setup.sh
bash setup.sh --dry-run
sudo bash setup.sh --prepare-review
```

Inspect the root-only candidate and diff from a separate trusted terminal as
described in `cups/README.md`. After approving both printed hashes, apply exactly
that candidate, then start the shim:

```bash
sudo bash setup.sh --apply-reviewed <source-sha256> <candidate-sha256>
docker compose up -d
```

The installer rejects broad access rules, validates with `cupsd`, handles
socket activation, rolls back on restart or local-probe failure, and never emits
the private aliases, CIDRs, candidate, or diff during its normal output.

## Deploy runbook (on the Pi)

Prerequisites: Raspberry Pi OS/Debian with Git, Docker Engine, and the Compose
plugin installed manually. The root `setup.sh --profile server` targets Ubuntu
Server and is not supported on the Pi yet. Migrating an existing Pi off the
per-service sidecars follows `docs/ONE_NODE_PER_HOST.md` section 4.4 instead.

1. **Free port 53.** Debian's `systemd-resolved` stub may hold `:53`. Set
   `DNSStubListener=no` in resolved's config and restart it (or bind AdGuard to
   the Pi's LAN IP). Standard Pi-hole/AdGuard prerequisite.
2. **Bring up AdGuard:**
   ```bash
   cd linux-pi/adguard
   docker compose up -d
   ```
   Complete the first-run wizard at `http://<pi-lan-ip>:3000` (set the admin
   user/password; configure the UI on `:80`).
3. **Bring up sync:**
   ```bash
   cd ../adguardhome-sync
   cp .env.example .env      # set origin/replica URLs + creds
   docker compose up -d
   ```
   The Pi's filters/rewrites/upstreams should now match the primary.
4. **Wire failover on the router (`<router-ip>`):** in its DHCP settings, set the
   DNS servers to `[<server-ip>, <pi-ip>]` (primary = server, secondary = Pi).
   Renew a client lease to pick it up.
5. **Bring up the Pi dashboard:** in `homepage/`, `cp .env.example .env`, set
   the `HOMEPAGE_VAR_*` names, LAN identity and AdGuard creds, then
   `docker compose up -d`. It is on the LAN at `http://<pi-lan-ip>:3001`.
6. **CUPS:** the reviewed installer and the shim, as above.
7. **Host node and serve:** the host node setup and the apply, as above. The
   dashboard is then at `https://<pi-hostname>.<tailnet>.ts.net`, and the main
   server's homepage shows a "Secondary Server (Pi)" card linking to it.

When upgrading an existing checkout, add new keys from `.env.example` to each
gitignored `.env`, and delete the keys that are gone (`TS_AUTHKEY`,
`HOMEPAGE_VAR_ADGUARD_PI_DOMAIN`, `HOMEPAGE_VAR_MOTIONEYE_DOMAIN`,
`HOMEPAGE_VAR_CUPS_DOMAIN`, `CUPS_SIDECAR_SUBNET`).

## Verification

```bash
dig @<pi-lan-ip> example.com +short          # resolves
dig @<pi-lan-ip> <a-blocked-domain> +short   # returns 0.0.0.0 (filtering works)
tailscale serve status --json                # matches tailscale-serve/serve.json
scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json   # prints "up to date"
```

From another tailnet device:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://<pi-hostname>.<tailnet>.ts.net/                     # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://<pi-hostname>.<tailnet>.ts.net/motioneye/           # 200
curl -sS -o /dev/null -w '%{http_code}\n' https://<pi-hostname>.<tailnet>.ts.net:8443/control/status  # 401 or 403
curl -sS -o /dev/null -w '%{http_code}\n' https://<pi-hostname>.<tailnet>.ts.net:8449/                # 200
```

Resilience proof: `sudo systemctl stop tailscaled` → `dig @<pi-lan-ip>` still
resolves, proving DNS is independent of Tailscale; start it again afterwards.
Failover test: stop the primary AdGuard and confirm a client still resolves via
the Pi.

## Caveat: secondary DNS is not clean failover

OS resolvers treat multiple DHCP-provided nameservers inconsistently — some race
both, some only fall back after a timeout. A secondary buys **resilience, not
seamless behavior**. Running the *same* software (AdGuard) on both keeps ad-
filtering and split-DNS working whichever one answers.

## Privacy

Repo is public. Tracked files use placeholders (`<tailnet>`, `<pi-hostname>`,
`<pi-lan-ip>`, `<server-ip>`); real IPs, hostnames, the tailnet suffix, and
AdGuard credentials live only in gitignored `.env` files.
