# Post-setup configuration

`setup.sh` has installed packages and started all Docker services.
Complete these remaining steps.

---

## 1. Restart your shell

- [ ] Log out and back in — activates zsh as default shell and enables `docker` without sudo

---

## 2. Tailscale

- [ ] Authenticate and connect to your Tailnet:
  ```sh
  sudo tailscale up
  ```
- [ ] Allow running Tailscale commands without sudo:
  ```sh
  sudo tailscale set --operator=$USER
  ```

---

## 3. SSH / GPG keys

- [ ] Create SSH key:
  ```sh
  bash SSH_and_GPG/create_ssh_key.sh
  ```
- [ ] Create GPG key and configure Git commit signing:
  ```sh
  bash SSH_and_GPG/create_gpg_key.sh
  ```

---

## 4. Homepage .env

Edit `linux-server/homepage/.env`, then restart:
```sh
cd linux-server/homepage && docker compose restart
```

| Variable | How to get the value |
|---|---|
| `HOMEPAGE_VAR_SERVER_IP` | Your server hostname (e.g. `<hostname>.local`) |
| `HOMEPAGE_VAR_HOMEPAGE_DOMAIN` | The server node's MagicDNS name, same as `TAILSCALE_HOSTNAME`; setup.sh fills it. Every card link is built from it |
| `HOMEPAGE_VAR_ADGUARD_USER` / `_PASS` | Set after AdGuard wizard (step 7 below) |
| `HOMEPAGE_VAR_SYNCTHING_KEY` | Set after Syncthing is running (step 7 below) |
| `HOSTNAME` | `hostname` |
| `SERVER_IP` | `hostname -I \| awk '{print $1}'` |
| `TAILSCALE_HOSTNAME` | `tailscale status --json \| jq -r '.Self.DNSName' \| sed 's/\.$//'` |

---

## 5. Tailscale widget (tailscale-proxy)

The Homepage Tailscale widget uses a local OAuth proxy to avoid 90-day key rotation.

- [ ] Create an OAuth client at `tailscale.com/admin/settings/oauth` — scope: **Core - Read**
- [ ] Fill in `linux-server/tailscale-proxy/.env`:

  | Variable | Value |
  |---|---|
  | `TAILSCALE_CLIENT_ID` | OAuth client ID |
  | `TAILSCALE_CLIENT_SECRET` | OAuth client secret |
  | `TAILSCALE_DEVICE_ID` | `tailscale status --json \| jq -r '.Self.ID'` |

- [ ] Start the proxy:
  ```sh
  cd linux-server/tailscale-proxy && docker compose up -d
  ```

---

## 6. HTTPS

Every web UI is published on the tailnet by host `tailscale serve` on the
server's own node. Full reference: [`HTTPS.md`](HTTPS.md).

- [ ] Enable MagicDNS and HTTPS certificates in the Tailscale admin console: `login.tailscale.com/admin/dns`
- [ ] Create the render `.env` and apply the node-level config (paths and registry ports):
  ```sh
  cd linux-server/tailscale-serve
  (umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
  cd ../..
  scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none --dry-run
  scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none
  ```
- [ ] Tailscale Services for forgejo, ntfy and immich: tag the node `tag:server`,
      define each Service in the admin console, then apply it
      (`--services svc:ntfy`, …). Steps in [`HTTPS.md`](HTTPS.md) → "Adding a Tailscale Service"
- [ ] Cockpit: `sudo cp linux-server/cockpit/cockpit.conf.example /etc/cockpit/cockpit.conf`,
      replace the `<...>` placeholders, `sudo systemctl restart cockpit`
- [ ] NPM: set `NPM_BIND_IP` (the server's LAN IP) in `linux-server/nginx-proxy-manager/.env`,
      then `docker compose up -d` there. NPM is the LAN HTTPS edge for clients
      that can't join the tailnet; see [`HTTPS.md`](HTTPS.md) → "NPM — trusted HTTPS for non-tailnet clients"

`<server>.<tailnet>.ts.net` below is the server's node (`TAILSCALE_HOSTNAME`).

---

## 7. First-login service setup

### Portainer — https://\<server\>.\<tailnet\>.ts.net/portainer/
- [ ] Create admin account **within 5 minutes** — if you miss the window, restart the container

### Filebrowser — https://\<server\>.\<tailnet\>.ts.net/filebrowser/
- [ ] Default login: `admin` / `admin` — change immediately
- [ ] Optionally update `FB_ROOT` in `linux-server/filebrowser/.env` to limit the browsable path, then restart:
  ```sh
  cd linux-server/filebrowser && docker compose restart
  ```

### Uptime Kuma — https://\<server\>.\<tailnet\>.ts.net:8444
- [ ] Create admin account on first visit
- [ ] Add the monitors listed in [`uptime-kuma/monitors.md`](uptime-kuma/monitors.md)
- [ ] Create a status page with slug `default` (used by the Homepage widget)

### Nginx Proxy Manager — http://\<server-ip\>:81 or https://\<server\>.\<tailnet\>.ts.net:8447
- [ ] Default login: `admin@example.com` / `changeme` — change immediately

### ntfy — https://ntfy.\<tailnet\>.ts.net
- [ ] Install the ntfy app on your phone, add your server URL, subscribe to a topic (e.g. `alerts`)
- [ ] Configure Uptime Kuma and Watchtower to send notifications via ntfy.
      Publishers on the server use `http://127.0.0.1:8103` (`NTFY_URL` in each `.env`)

### AdGuard Home — https://\<server\>.\<tailnet\>.ts.net:8443
- [ ] Complete the setup wizard (temporarily map `"127.0.0.1:3003:3000/tcp"` on
      `adguardhome` and reach it over `ssh -L 3003:127.0.0.1:3003 <server>`):
  - Web UI port → `80` (published as `127.0.0.1:8100`, the serve backend)
  - DNS port → `53`
  - Create admin credentials — then add them to `homepage/.env`
- [ ] Point your router's DNS to `<server-ip>` for network-wide filtering

### Forgejo — https://forgejo.\<tailnet\>.ts.net/

Forgejo is the `svc:forgejo` Tailscale Service, hosted by the server's node
(HTTPS via `tailscale serve`). It is reachable only on the tailnet — the
container publishes on `127.0.0.1` only.

- [ ] Copy and edit the env file:
  ```sh
  cd linux-server/forgejo && cp .env.example .env
  # Set FORGEJO_DOMAIN to forgejo.<tailnet>.ts.net
  # Optionally set FORGEJO_DATA_PATH to an external drive path
  ```
- [ ] Start Forgejo:
  ```sh
  docker compose up -d
  ```
- [ ] Apply `svc:forgejo` (step 6), then open `https://forgejo.<tailnet>.ts.net/` and complete the setup wizard:
  - Database: SQLite (pre-set)
  - SSH server domain and port: pre-filled from `.env` — verify they look correct
  - Application URL: should match `https://forgejo.<tailnet>.ts.net/`
  - Create the admin account at the bottom of the wizard page
- [ ] Generate a personal access token for the Homepage widget:
  - Top-right avatar → **Settings → Applications → Generate Token** — scope: all (or read-only is enough for the widget)
  - Add to `homepage/.env`:
    - `HOMEPAGE_VAR_FORGEJO_TOKEN=<token>`
    - `HOMEPAGE_VAR_FORGEJO_DOMAIN=forgejo.<tailnet>.ts.net`
  - Recreate Homepage: `cd linux-server/homepage && docker compose up -d`
- [ ] Add your SSH public key to Forgejo:
  - **Settings → SSH / GPG Keys → Add Key** — paste `~/.ssh/id_ed25519.pub` (or your key from `create_ssh_key.sh`)

#### Backup

Everything Forgejo needs to restore from scratch lives in `FORGEJO_DATA_PATH` (default: `linux-server/forgejo/data/`). Back up this directory to recover repos, config, SSH host keys, and the SQLite database.

| What | Path inside data dir | Notes |
|---|---|---|
| Git repositories | `gitea/repositories/` | The actual repo data |
| SQLite database | `gitea/forgejo.db` | Users, issues, settings |
| Config | `gitea/conf/app.ini` | Generated by setup wizard |
| SSH host keys | `gitea/conf/` (`*.rsa`, `*.ed25519`, etc.) | **Critical** — if lost, all clients get MITM warnings |

> Hot backups of the SQLite database are safe with Forgejo — it uses WAL mode. A simple `cp` or `rsync` of the data directory while Forgejo is running is sufficient.

#### Runner status monitor

A host timer (`runner-status.sh`) asks Forgejo whether the Mac mini Actions
runner (see [`../macOS/forgejo-runner/`](../macOS/forgejo-runner/)) is
connected, and surfaces it three ways: the homepage **forgejo-runner** card,
an Uptime Kuma push monitor, and an ntfy alert when it drops (and recovers).
Optional — skip if you aren't running CI.

- [ ] In `forgejo/.env`, set `FORGEJO_RUNNER_API_TOKEN` (a Forgejo token that can
      read runners; the default API URL is instance/admin scope) and
      `RUNNER_NAME` (the name shown under **Settings → Actions → Runners**,
      default `m4-mini`). Optionally set `KUMA_PUSH_URL` (see *Uptime Kuma push
      monitor* below) and the `NTFY_*` vars.
- [ ] Start the loopback status server (shipped in `forgejo/docker-compose.yml`):
  ```sh
  cd linux-server/forgejo && docker compose up -d forgejo-runner-status
  ```
- [ ] Install the timer (polls every 2 minutes):
  ```sh
  bash setup-runner-status.sh --dry-run
  sudo bash setup-runner-status.sh
  ```
- [ ] Verify:
  ```sh
  sudo systemctl start forgejo-runner-status.service
  cat runner-status/runner-status.json   # "state": "up" when connected
  ```
  The homepage card reads the same JSON; Uptime Kuma shows up/down history.

##### Uptime Kuma push monitor

The script's `kuma_push` fires on every run — wiring it up is config only, no
code changes.

- [ ] In Uptime Kuma (`https://<server>.<tailnet>.ts.net:8444`): **Add New
      Monitor → Monitor Type: `Push`**. Name it e.g. `Forgejo runner (m4-mini)`.
- [ ] Match the timer: **Heartbeat Interval 120s**, **Retries 2**, **Retry
      Interval 20s**. The retries give ~160s of slack before a down, so normal
      jitter on the 2-minute push doesn't trip a false alarm.
- [ ] Save, then copy the generated push URL (through `/api/push/<token>` — the
      script appends its own `status`/`msg` params) into `KUMA_PUSH_URL` in
      `forgejo/.env`, with the host swapped for loopback:
      `http://127.0.0.1:3001/api/push/<token>` (the script runs on the server).
- [ ] Fire one push: `sudo systemctl start forgejo-runner-status.service`. The
      monitor goes green within a cycle.

Coverage is dual on purpose: the script pushes an explicit `status=down` when
Forgejo can't see the runner, while a missed heartbeat catches the script/timer
/server itself dying — so Kuma distinguishes "runner is down" from "monitoring
path is down."

#### Cloning / remotes from Mac

```sh
# SSH clone (use this for all git operations on Mac)
git clone ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git

# Set as remote on an existing repo
git remote set-url origin ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git
```

#### Migrating an existing repo (e.g. Obsidian vault) from GitHub

1. In Forgejo web UI: **+ → New Migration → GitHub** — imports history, branches, and tags
2. On Mac, point the local repo at Forgejo:
   ```sh
   git remote set-url origin ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git
   ```
3. Add GitHub as a push mirror for validation while you transition:
   - In Forgejo: repo **Settings → Git Hooks → Push Mirrors → Add Push Mirror**
   - Mirror URL: `https://<github-username>:<github-pat>@github.com/<username>/<repo>.git`
   - Interval: `24h` (or `0` to push only on demand)
   - When you're satisfied with Forgejo, delete the mirror and archive the GitHub repo

### Syncthing — https://\<server\>.\<tailnet\>.ts.net/syncthing/
- [ ] Set a GUI user and password on first visit (Actions → Settings → GUI)
- [ ] Add volume mounts to `linux-server/syncthing/docker-compose.yml` for each folder to sync, then restart:
  ```sh
  cd linux-server/syncthing && docker compose restart
  ```
- [ ] Get API key: Actions → Settings → API Key — add to `homepage/.env` as `HOMEPAGE_VAR_SYNCTHING_KEY`

### Immich — https://immich.\<tailnet\>.ts.net
- [ ] Create the admin account (first sign-up becomes admin)
- [ ] Administration → Settings: set **External domain**, pick **Quick Sync** under Video Transcoding → Hardware Acceleration, confirm database dumps are on
- [ ] Create an API key with `server.statistics` → `HOMEPAGE_VAR_IMMICH_KEY` in `homepage/.env`
- [ ] Install the phone app, point it at the server URL, enable backup — see [`immich/README.md`](immich/README.md)

### UPS (NUT) — host service, no UI

Monitors the CyberPower UPS over USB (clean shutdown on low battery).
ntfy alerts on power events. Full runbook in [`ups/README.md`](ups/README.md).

- [ ] Configure and deploy:
  ```sh
  cd linux-server/ups
  cp .env.example .env   # set UPSMON_PASSWORD (openssl rand -hex 16) + ntfy
  sudo bash setup.sh
  ```
- [ ] Verify: `upsc cyberpower ups.status` prints `OL`
- [ ] Run `bash verify.sh --platform server` from the repo root
- [ ] Start the PeaNUT dashboard (`docker compose up -d`) — graphs at
      `https://<server>.<tailnet>.ts.net:8446`, and the homepage
      **ups** card goes live
- [ ] Subscribe to the `server-ups` ntfy topic on your phone
- [ ] Set BIOS **Restore on AC Power Loss → Power On**

---

## 8. DAS drives (Thunderbolt enclosure)

Three drives are attached via a TerraMas Thunderbolt DAS enclosure:

| Label | Mount | Size | Use |
|-------|-------|------|-----|
| `Seagate_4TB` | `/mnt/seagate4tb` | 3.6 TB | General storage |
| `WD_1TB` | `/mnt/wd1tb` | 931 GB | Backup target (restic) |
| `WD14TB` | `/mnt/wd14tb` | 12.7 TB | Media, torrents, bulk data |

- **fstab** entries use `nofail,x-systemd.device-timeout=10` — if the DAS is
  disconnected at boot, the system continues without them.
- **Glances disk renaming** — kernel device names (`sda`/`sdb`/`sdc`) can shuffle
  when the enclosure is reconnected. The Glances patch resolves
  `/dev/disk/by-label/` through sysfs on every refresh, so Homepage widgets see
  persistent label-based names even after a late mount or device reshuffle. Patch
  installation or API failures are written to the container log. See
  `glances/rename_disks.py`.
- **Homepage widgets** — the capacity widgets use `fs:/mnt/<path>` (stable mount
  points); the R/W speed widgets use `disk:<label>` resolved by the Glances
  patch above.
- **If drives are disconnected and reconnected**: mount them with `sudo mount -a`;
  Glances picks up the new device mapping on its next refresh. Restart only services
  that require the mounts themselves, such as qBittorrent.

---

## 9. Service reference

`<server>` is the server's node, `<server>.<tailnet>.ts.net`. Routes are defined
in [`tailscale-serve/serve.json`](tailscale-serve/serve.json); see [`HTTPS.md`](HTTPS.md).

| Service | URL | Notes |
|---|---|---|
| Homepage | https://\<server\>/ | Or http://\<server-ip\>:3000 on LAN |
| Portainer | https://\<server\>/portainer/ | Create admin within 5 min |
| Glances | https://\<server\>/glances/ | Or http://\<server-ip\>:61208 on LAN |
| Speedtest Tracker | https://\<server\>:8445 | |
| Filebrowser | https://\<server\>/filebrowser/ | Default: admin / admin |
| Watchtower | https://\<server\>/watchtower/v1/metrics | No UI; token-gated metrics only |
| Uptime Kuma | https://\<server\>:8444 | Monitors: [`uptime-kuma/monitors.md`](uptime-kuma/monitors.md) |
| Nginx Proxy Manager | https://\<server\>:8447 | Or http://\<server-ip\>:81 on LAN; default: admin@example.com / changeme |
| ntfy | https://ntfy.\<tailnet\>.ts.net | Tailscale Service `svc:ntfy`; on the server: http://127.0.0.1:8103 |
| Syncthing | https://\<server\>/syncthing/ | Sync ports :22000/:21027 on the host |
| qBittorrent | https://\<server\>/qbittorrent/ | BitTorrent :6881 on the host |
| OpenSpeedTest | https://\<server\>/openspeedtest/ | LAN tests: http://\<server-ip\>:3030 |
| AdGuard Home | https://\<server\>:8443 | DNS published on host :53 |
| Cockpit | https://\<server\>/cockpit-ui/ | Or https://\<server-ip\>:9090/cockpit-ui/ on LAN |
| PeaNUT (UPS) | https://\<server\>:8446 | Homepage ups card reads it via localhost :8097 |
| atvloadly | https://\<server\>:8448 | |
| Tailscale Web UI | https://\<server\>/tailscale-web/ | Host user unit on 127.0.0.1:8088 |
| Tailscale proxy | http://localhost:8089 | Internal — used by Homepage widget |
| Immich | https://immich.\<tailnet\>.ts.net/ | Tailscale Service `svc:immich`; excluded from watchtower; media on `UPLOAD_LOCATION`, not yet backed up (#87) |
| Forgejo | https://forgejo.\<tailnet\>.ts.net/ | Tailscale Service `svc:forgejo`; Git over SSH on the Service's port 22 |
