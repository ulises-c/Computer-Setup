# Linux server setup

Tested on Ubuntu Server LTS. Most packages work on other Debian-based distros.

## Quick start

```sh
bash setup.sh --profile server             # core packages + zsh setup
bash setup.sh --profile server --optional  # also install samba, smartmontools, nmap, ffmpeg, etc.
bash setup.sh --profile server --dry-run   # preview without installing
```

(Run from the repo root; `linux-server/setup.sh` is a thin shim onto it.)

After running, log out and back in to start using zsh.

After setup.sh completes, authenticate Tailscale:

```sh
sudo tailscale up
```

`setup.sh` handles the Tailscale web UI service, Docker services, and `.env` scaffolding automatically. Publishing the services on the tailnet is one more step, [`HTTPS.md`](HTTPS.md) → "Applying the serve config". See `post-install.md` for the remaining manual steps.

## Files

- [`setup.sh`](setup.sh) — thin shim onto the root [`setup.sh`](../setup.sh) (server platform)
- [`post-install.md`](post-install.md) — step-by-step checklist to follow after setup.sh
- [`HTTPS.md`](HTTPS.md) — how every service is published on the tailnet (host `tailscale serve`, one node per host)
- [`tailscale-serve/serve.json`](tailscale-serve/serve.json) — the serve template, applied by [`../scripts/ts-serve-apply.sh`](../scripts/ts-serve-apply.sh)
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`benchmark-nas.md`](benchmark-nas.md) — how to measure LAN vs. real-world NAS throughput (`dd` over Samba + OpenSpeedTest)
- [`../dotfiles/zshrc.example`](../dotfiles/zshrc.example) — shared zsh config (incl. Powerlevel10k), deployed to `~/.zshrc` by `setup.sh`; the desktop-only bits self-disable headless, so the server uses the same base as every other platform
- [`../dotfiles/zsh_plugins.txt`](../dotfiles/zsh_plugins.txt) — shared antidote plugin list, deployed to `~/.zsh_plugins.txt` and pre-cloned by `setup.sh`
- [`../dotfiles/tmux.conf`](../dotfiles/tmux.conf) — tmux config with mouse support, vi copy mode, and a status bar (shared across all platforms); copied to `~/.tmux.conf` by `setup.sh`
- [`../packages.json`](../packages.json) — machine-readable package manifest (shared across all platforms)

## Next steps

`setup.sh` handles packages, zsh, tmux, Tailscale, and Docker. Everything below is manual and should be done in order after the script finishes.

### 1. Restart your shell

Log out and back in. This activates zsh as your default shell and adds you to the `docker` group (required to run Docker without sudo).

### 2. Tailscale

```sh
sudo tailscale up
sudo tailscale set --operator=$USER
```

The Tailscale web UI service is installed and started by `setup.sh` once the node is logged in (re-run `setup.sh` after `tailscale up`). It listens on `127.0.0.1:8088` and is served at `https://<server>.<tailnet>.ts.net/tailscale-web/`.

### 3. SSH / GPG keys

```sh
bash SSH_and_GPG/create_ssh_key.sh
bash SSH_and_GPG/create_gpg_key.sh
```

### 4. claude-code

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

### 5. Docker services

Start services in this order. Most just need `docker compose up -d`; exceptions are noted. Every web UI publishes on `127.0.0.1` only, so it answers on the tailnet once the serve config is applied ([step 7](#7-https)); the URLs below are those front doors (`<server>.<tailnet>.ts.net` is the server's own node).

```sh
# Homepage — update .env with your server details first (see post-install.md)
cd linux-server/homepage && cp .env.example .env
# Existing .env: add new .env.example keys, including HOMEPAGE_VAR_PI_HOSTNAME.
# edit .env, then:
docker compose up -d
# Access at http://<server-ip>:3000 on the LAN, or https://<server>.<tailnet>.ts.net/

# Portainer
cd linux-server/portainer && docker compose up -d
# Access at https://<server>.<tailnet>.ts.net/portainer/ — create admin account within 5 minutes

# Glances
cd linux-server/glances && cp .env.example .env   # GLANCES_ALLOWED_HOSTS
docker compose up -d
# Access at http://<server-ip>:61208 or https://<server>.<tailnet>.ts.net/glances/

# Speedtest Tracker — requires APP_KEY before first run
cd linux-server/speedtest-tracker && cp .env.example .env
echo "base64:$(openssl rand -base64 32)"  # paste as APP_KEY in .env; set APP_URL/ASSET_URL
docker compose up -d
# Access at https://<server>.<tailnet>.ts.net:8445

# Filebrowser
cd linux-server/filebrowser && cp .env.example .env
# Optionally set FB_ROOT in .env to limit the browsable path (defaults to /)
docker compose up -d
# Access at https://<server>.<tailnet>.ts.net/filebrowser/ — default login: admin / admin (change immediately)

# AdGuard Home — fix systemd-resolved conflict first
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
cd linux-server/adguard && docker compose up -d
# UI at https://<server>.<tailnet>.ts.net:8443; DNS on host :53.
# First-run only: temporarily add "127.0.0.1:3003:3000/tcp" to adguardhome's
# ports, browse to it over an SSH tunnel (ssh -L 3003:127.0.0.1:3003 <server>),
# set DNS port → 53 (UI stays :80), create admin.

# qBittorrent
cd linux-server/qbittorrent && cp .env.example .env
# optionally set QBITTORRENT_DOWNLOADS_PATH for an external drive, then:
docker compose up -d
# Access at https://<server>.<tailnet>.ts.net/qbittorrent/
# First run: get the temporary admin password from the logs and change it:
#   docker compose logs qbittorrent | grep -i password

# OpenSpeedTest
cd linux-server/openspeedtest && docker compose up -d
# Tailnet UI at https://<server>.<tailnet>.ts.net/openspeedtest/ — but run LAN
# tests via http://<server-ip>:3030 so you measure the local network, not the tailnet

# Immich — needs DB_PASSWORD; see immich/README.md
cd linux-server/immich && cp .env.example .env
# edit .env, then:
docker compose up -d
# Access at https://immich.<tailnet>.ts.net/ (Tailscale Service) — first sign-up becomes admin
```

### 6. Tailscale widget

The Tailscale widget uses a local OAuth proxy (`linux-server/tailscale-proxy`) to avoid 90-day API key rotation.

1. Create an OAuth client at `tailscale.com/admin/settings/oauth` with scope **Core - Read**
2. Get your device ID: `tailscale status --json | jq -r '.Self.ID'`
3. Fill in `linux-server/tailscale-proxy/.env` with the client ID, client secret, and device ID
4. Start the proxy:
   ```sh
   cd linux-server/tailscale-proxy && docker compose up -d
   ```

### 7. HTTPS

Every web UI is published on the tailnet by host `tailscale serve`, through the
server's own node: paths and registry ports on `https://<server>.<tailnet>.ts.net`,
plus three Tailscale Services (forgejo, ntfy, immich). Enable HTTPS certificates
in the Tailscale admin console (`login.tailscale.com/admin/dns`), then:

```sh
cd linux-server/tailscale-serve
(umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
cd ../..
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none --dry-run
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none
```

The Services need a tagged node and admin-console setup first; see
[`HTTPS.md`](HTTPS.md) → "Adding a Tailscale Service". To migrate a server that
still runs the old per-service sidecars, follow the runbook in
[`../docs/ONE_NODE_PER_HOST.md`](../docs/ONE_NODE_PER_HOST.md) section 4.

NPM is separate: it is the LAN HTTPS edge for clients that can't join the
tailnet, bound to `NPM_BIND_IP` (the server's LAN IP) in
`nginx-proxy-manager/.env`. See [`HTTPS.md`](HTTPS.md) → "NPM — trusted HTTPS
for non-tailnet clients".

### 8. Docker address pools

`setup.sh` merges [`docker/daemon.json`](docker/daemon.json) into
`/etc/docker/daemon.json`, preserving other keys such as the nvidia runtime and
the file's mode, and restarts Docker. From then on, every new compose network
gets a `/24` inside `172.16.0.0/12` (4096 networks). Without the pin, Docker's
default pools spill into `192.168.0.0/16` once `172.17`–`172.31` fill, which
collides with home-LAN space ([#75](https://github.com/ulises-c/Computer-Setup/issues/75)).

**The first run after this change restarts Docker.** Every container stops and
comes back (`restart: unless-stopped`), and host DNS on `:53` (AdGuard) drops for
the duration, so the Pi resolver carries DNS meanwhile. Run it in a quiet moment.
Later runs restart nothing unless the file or the running daemon's pools differ
from the repo. If Docker does not come back with the pinned pools, the step
restores the previous `daemon.json` (backup in `/etc/docker/daemon.json.bak.*`),
clears systemd's start limit, restarts Docker on the old config, and exits
non-zero.

On that restart Docker rebuilds its default `docker0` bridge from the new pool,
so `docker0` moves off `172.17.0.1`.

Compose networks keep their old subnets until they are recreated. `verify.sh
--profile server` names every IPv4 bridge outside `172.16.0.0/12` as
`<network>=<subnet>`. For each one, find its project and recreate it:

```sh
docker network inspect <network> --format '{{index .Labels "com.docker.compose.project"}}'
cd linux-server/<project> && docker compose down && docker compose up -d
```

`down` removes the project network, and `up` recreates it from the pinned pool.
Bind-mounted app data is untouched. Only the container-internal
`172.x`/`192.168.x` address changes, and nothing addresses a container by that
address: serve reaches every app through its `127.0.0.1` publish.

---

## Docker services

1. homepage | [GitHub](https://github.com/gethomepage/homepage) | [Docs](https://gethomepage.dev)
   1. Lightweight server dashboard — system stats, running service cards with live Docker status
   2. Deploy:
      ```sh
      cd linux-server/homepage
      cp .env.example .env        # update HOMEPAGE_VAR_SERVER_IP
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:3000` on the LAN, or `https://<server>.<tailnet>.ts.net/` (the root of the server's node)
   4. Add new services in `config/services.yaml` — each card supports `server: my-docker` + `container: <name>` for live status

2. portainer | [GitHub](https://github.com/portainer/portainer) | [Docs](https://docs.portainer.io)
   1. Web UI for managing Docker containers, images, volumes, and networks
   2. Deploy:
      ```sh
      cd linux-server/portainer
      docker compose up -d
      ```
   3. Access at `https://<server>.<tailnet>.ts.net/portainer/` (`--base-url /portainer`; the plaintext UI is published on `127.0.0.1:9000` only)
   4. On first launch, set up an admin account within 5 minutes or the setup will time out

3. atvloadly | [GitHub](https://github.com/bitxeno/atvloadly)
   1. Self-hosted web app for sideloading IPA files onto Apple TV — a self-deployable alternative to AltStore/Sideloadly
   2. Deploy: `cd linux-server/atvloadly && docker compose up -d`
   3. Access at `https://<server>.<tailnet>.ts.net:8448`

4. filebrowser | [GitHub](https://github.com/filebrowser/filebrowser) | [Docs](https://filebrowser.org)
   1. Web-based file manager — browse, upload, download, edit, and share files on the server from any browser
   2. Deploy:
      ```sh
      cd linux-server/filebrowser
      cp .env.example .env        # optionally set FB_ROOT to limit the browsable path (defaults to /)
      docker compose up -d
      ```
   3. Access at `https://<server>.<tailnet>.ts.net/filebrowser/`; default login is `admin` / `admin` — change on first login

5. cockpit | [GitHub](https://github.com/cockpit-project/cockpit) | [Docs](https://cockpit-project.org)
   1. Web-based server admin UI — system metrics, journal logs, network config, storage, and service management
   2. Installed as a system package by `setup.sh` (not Docker); enabled automatically via systemd socket activation
   3. Deploy [`cockpit/cockpit.conf.example`](cockpit/cockpit.conf.example) to `/etc/cockpit/cockpit.conf` (it sets `UrlRoot=/cockpit-ui` and the tailnet `Origins`), then `sudo systemctl restart cockpit`
   4. Access at `https://<server>.<tailnet>.ts.net/cockpit-ui/`, or `https://<server-ip>:9090/cockpit-ui/` on the LAN; log in with your Linux username and password

6. glances | [GitHub](https://github.com/nicolargo/glances) | [Docs](https://glances.readthedocs.io)
   1. Real-time system monitor — CPU, memory, disk I/O, network, processes, temperatures, and Docker containers in one view
   2. Deploy:
      ```sh
      cd linux-server/glances
      cp .env.example .env        # GLANCES_ALLOWED_HOSTS must list the server's MagicDNS name
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:61208` or `https://<server>.<tailnet>.ts.net/glances/`; the Homepage widget shows live CPU stats on the service card

7. speedtest tracker | [GitHub](https://github.com/alexjustesen/speedtest-tracker) | [Docs](https://docs.speedtest-tracker.dev)
   1. Scheduled ISP speed tests with history graphs — tracks ping, download, and upload over time
   2. Deploy:
      ```sh
      cd linux-server/speedtest-tracker
      cp .env.example .env
      echo "base64:$(openssl rand -base64 32)"   # paste output as APP_KEY in .env
      docker compose up -d
      ```
   3. Access at `https://<server>.<tailnet>.ts.net:8445` (`APP_URL` and `ASSET_URL` must be that URL); runs a test every 6 hours by default (configurable via `SPEEDTEST_SCHEDULE` in `.env`)

8. watchtower | [GitHub](https://github.com/containrrr/watchtower) | [Docs](https://containrrr.dev/watchtower/)
   1. Automatically pulls updated Docker images and restarts containers — runs daily at 3am by default
   2. Deploy:
      ```sh
      cd linux-server/watchtower && docker compose up -d
      ```
   3. No UI; its token-gated metrics API is at `https://<server>.<tailnet>.ts.net/watchtower/v1/metrics` for Uptime Kuma

9. uptime kuma | [GitHub](https://github.com/louislam/uptime-kuma) | [Docs](https://github.com/louislam/uptime-kuma/wiki)
   1. Self-hosted uptime monitor with status pages and alerts (email, ntfy, Discord, etc.)
   2. Deploy:
      ```sh
      cd linux-server/uptime-kuma && docker compose up -d
      ```
   3. Access at `https://<server>.<tailnet>.ts.net:8444`; create an admin account on first visit
   4. Add the monitors in [`uptime-kuma/monitors.md`](uptime-kuma/monitors.md), then create a status page with slug `default` for the Homepage widget

10. tailscale-proxy
    1. Tiny local HTTP server that exchanges Tailscale OAuth credentials for an access token and proxies device API requests — used by the Homepage Tailscale widget to avoid 90-day key rotation
    2. Deploy:
       ```sh
       cd linux-server/tailscale-proxy
       cp .env.example .env   # fill in TAILSCALE_CLIENT_ID, TAILSCALE_CLIENT_SECRET, TAILSCALE_DEVICE_ID
       docker compose up -d   # builds the image on first run
       ```
    3. Listens on `localhost:8089`; Homepage queries it via `customapi` widget

11. nginx proxy manager | [GitHub](https://github.com/jc21/nginx-proxy-manager) | [Docs](https://nginxproxymanager.com/guide/)
    1. Reverse proxy with a web UI — the non-tailnet HTTPS edge: trusted certs for
       LAN/public clients that can't join the tailnet (host `tailscale serve` covers
       on-tailnet HTTPS). See [HTTPS.md](HTTPS.md) → "NPM — trusted HTTPS for non-tailnet clients"
    2. Deploy:
       ```sh
       cd linux-server/nginx-proxy-manager
       cp .env.example .env   # NPM_BIND_IP = the server's LAN IP (keeps NPM off the tailnet IP's :443)
       docker compose up -d
       ```
    3. Admin UI at `http://<server-ip>:81` on the LAN or `https://<server>.<tailnet>.ts.net:8447`; default login: `admin@example.com` / `changeme` — update immediately

12. ntfy | [GitHub](https://github.com/binwiederhier/ntfy) | [Docs](https://docs.ntfy.sh)
    1. Self-hosted push notification service — send alerts from any service to your phone or desktop via the ntfy app
    2. Deploy:
       ```sh
       cd linux-server/ntfy && cp .env.example .env && docker compose up -d
       ```
    3. Access at `https://ntfy.<tailnet>.ts.net` (the `svc:ntfy` Tailscale Service); subscribe to topics in the ntfy app using that URL. Publishers on the server itself use `http://127.0.0.1:8103`

13. syncthing | [GitHub](https://github.com/syncthing/syncthing) | [Docs](https://docs.syncthing.net)
    1. Decentralized file sync across devices — no cloud required; syncs directly between your server and other devices
    2. Deploy:
       ```sh
       cd linux-server/syncthing && docker compose up -d
       ```
    3. Access at `https://<server>.<tailnet>.ts.net/syncthing/`; set a GUI password on first visit (the GUI's Host check is off, so the password is the guard)
    4. Add volume mounts to `docker-compose.yml` for each folder you want to sync, then configure them in the web UI
    5. Get your API key from Actions → Settings → API Key and add it to `linux-server/homepage/.env` for the Homepage widget

14. AdGuard Home | [GitHub](https://github.com/AdguardTeam/AdGuardHome) | [Docs](https://adguard-dns.io/kb/adguard-home/overview/)
   1. Network-wide DNS ad and tracker blocker — modern UI, DNS-over-HTTPS/TLS, and per-client rules
   2. **Prerequisites** — Ubuntu's `systemd-resolved` binds to port 53 and must be told to stop using it:
      ```sh
      sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
      sudo systemctl restart systemd-resolved
      ```
   3. Deploy:
      ```sh
      cd linux-server/adguard
      docker compose up -d
      ```
   4. First-run setup wizard (only if never configured): temporarily add
      `"127.0.0.1:3003:3000/tcp"` to `adguardhome`'s `ports:` in `docker-compose.yml`, then
      `docker compose up -d` and open it through an SSH tunnel
      (`ssh -L 3003:127.0.0.1:3003 <server>`, then `http://localhost:3003`)
      - Set the DNS port to **53**; leave the web UI on **80** (published as
        `127.0.0.1:8100`, the serve backend)
      - Create your admin username and password, then remove the `3003` mapping and
        `docker compose up -d` again
   5. Access the web UI at `https://<server>.<tailnet>.ts.net:8443`; DNS is host-published
      on `:53`, independent of tailscaled
   6. Point your router's DNS (or individual devices) to `<server-ip>` to start filtering
   7. Add credentials to `linux-server/homepage/.env` to enable the stats widget on Homepage

15. forgejo | [Codeberg](https://codeberg.org/forgejo/forgejo) | [Docs](https://forgejo.org/docs/)
    1. Lightweight self-hosted git service — GitHub-like web UI, SSH push/pull, repo mirroring; LAN/Tailscale only, no public exposure
    2. Deploy:
       ```sh
       cd linux-server/forgejo
       cp .env.example .env   # set FORGEJO_DOMAIN (forgejo.<tailnet>.ts.net); optionally FORGEJO_DATA_PATH for external drive
       docker compose up -d
       ```
    3. Served by the `svc:forgejo` Tailscale Service, hosted on the server's node ([`HTTPS.md`](HTTPS.md)); the container publishes on loopback only. Web UI at `https://forgejo.<tailnet>.ts.net/` — complete the setup wizard on first visit, create admin account
    4. Git over SSH on port `22` of the Service (its own tailnet IP, so no conflict with the host's sshd):
       ```sh
       git clone ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git
       ```
    5. Add your SSH public key in **Settings → SSH / GPG Keys** after creating your account
    6. To migrate from GitHub: use Forgejo's built-in migration (**+ → New Migration → GitHub**), then optionally configure a push mirror back to GitHub under repo **Settings → Push Mirrors** while validating the setup

16. qBittorrent | [GitHub](https://github.com/qbittorrent/qBittorrent) | [Docs](https://github.com/linuxserver/docker-qbittorrent)
    1. BitTorrent client with a full web UI — currently used for academic torrents. Served at a path on the server's node (see [`HTTPS.md`](HTTPS.md))
    2. Deploy:
       ```sh
       cd linux-server/qbittorrent
       cp .env.example .env   # optionally set QBITTORRENT_DOWNLOADS_PATH for an external drive
       docker compose up -d
       ```
    3. Access at `https://<server>.<tailnet>.ts.net/qbittorrent/`
    4. On first run, the LinuxServer image generates a temporary admin password — find it with `docker compose logs qbittorrent | grep -i password`, log in as `admin`, then change it in **Options → Web UI** (and add the new login to `HOMEPAGE_VAR_QBITTORRENT_PASSWORD` in `linux-server/homepage/.env` for the widget)
    5. In **Options → Web UI**, leave the "IP address" at `*` (all interfaces). The container's publish is `127.0.0.1:8080` on the host, so the UI is still loopback-only; a `127.0.0.1` setting inside the container would make it unreachable
    6. BitTorrent `:6881` (tcp/udp) is published by the container. **Not routed through a VPN** — fine for academic/legal torrents; see [`../docs/TODO.md`](../docs/TODO.md) for the planned Gluetun VPN sidecar before any other use

17. OpenSpeedTest | [GitHub](https://github.com/openspeedtest/Speed-Test) | [Docs](https://openspeedtest.com/selfhosted-speedtest)
    1. Self-hosted browser speed test for the **LAN** (the local-network counterpart to speedtest-tracker's ISP test) — any device opens it in a browser and measures its throughput to the server. Also served at a path on the server's node (see [`HTTPS.md`](HTTPS.md))
    2. Deploy:
       ```sh
       cd linux-server/openspeedtest
       docker compose up -d
       ```
    3. Tailnet UI at `https://<server>.<tailnet>.ts.net/openspeedtest/`. For an accurate **LAN** result, test against the LAN IP instead — `http://<server-ip>:3030` — or the result reflects the tailnet path rather than the local network
    4. LAN ports `:3030`/`:3031` are published on all interfaces (not the default `:3000`/`:3001`, which collide with homepage and uptime-kuma); `:3030` is also the serve backend

18. backup | [restic](https://restic.net) | [Docs](https://restic.readthedocs.io)
    1. Nightly encrypted, deduplicated backup of all persistent service state (SQLite DBs, Forgejo git repos, certs, configs, `.env`s) to the 1TB drive, with an optional second copy to the 14TB drive. systemd timer + ntfy alerts + a homepage status card. Full setup and restore runbook in [`backup/README.md`](backup/README.md)
    2. Deploy:
       ```sh
       sudo apt install restic sqlite3 jq
       cd linux-server/backup
       cp .env.example .env   # set RESTIC_PASSWORD (save it in Bitwarden!) + ntfy
       sudo touch /mnt/wd1tb/.backup-target-ok
       docker compose up -d   # status-card server (loopback :8099)
       bash setup.sh --dry-run
       sudo bash setup.sh
       ```
    3. The status card on Homepage shows last-run time, status, and repo size; failures push to ntfy

19. UPS | [NUT](https://networkupstools.org/) | [Docs](https://networkupstools.org/docs/man/)
    1. Battery-backup monitoring over USB — CyberPower CST135UC2 (primary: ntfy alerts, clean shutdown on low battery, auto-restart when wall power returns) plus an EcoFlow River 3 Plus (monitoring-only) wired upstream as a battery bank (`wall -> EcoFlow -> CyberPower -> server`). Full runbook in [`ups/README.md`](ups/README.md)
    2. Deploy:
       ```sh
       sudo apt install nut   # or rerun the root setup.sh --profile server
       cd linux-server/ups
       cp .env.example .env   # set UPSMON_PASSWORD (openssl rand -hex 16) + ntfy
       sudo bash setup.sh
       upsc cyberpower ups.status   # expect: OL
       upsc ecoflow ups.status      # expect: OL
       docker compose up -d         # PeaNUT dashboard + homepage widgets
       ```
    3. Dashboard (charge/load/runtime graphs) at `https://<server>.<tailnet>.ts.net:8446`; the homepage **ups** card reads it via the `peanut` widget on localhost
    4. Set BIOS **Restore on AC Power Loss → Power On** so the server boots unattended after an outage

20. pi-hole | [GitHub](https://github.com/pi-hole/pi-hole) | [Docs](https://docs.pi-hole.net)
    1. Network-wide DNS ad blocker — alternative to AdGuard Home
    2. Not yet configured

21. Immich | [GitHub](https://github.com/immich-app/immich) | [Docs](https://docs.immich.app)
    1. Self-hosted photo and video backup — Google Photos alternative with mobile apps, face recognition, and timeline view. Served by the `svc:immich` Tailscale Service (see [`HTTPS.md`](HTTPS.md)); alternatives considered and the full runbook in [`immich/README.md`](immich/README.md)
    2. Deploy:
       ```sh
       cd linux-server/immich
       cp .env.example .env   # set DB_PASSWORD (openssl rand -hex 24); check UPLOAD_LOCATION
       docker compose up -d
       ```
    3. Access at `https://immich.<tailnet>.ts.net/` — the first sign-up becomes admin. Media on `UPLOAD_LOCATION` (14TB drive), Postgres on the SSD
    4. Excluded from watchtower (Immich upgrades can break); upgrade by hand after reading the release notes

22. Jellyfin | [GitHub](https://github.com/jellyfin/jellyfin) | [Docs](https://jellyfin.org/docs/)
    1. Self-hosted media server — stream your own movies, TV shows, and music to any device
    2. Not yet configured

23. Home Assistant | [GitHub](https://github.com/home-assistant/core) | [Docs](https://www.home-assistant.io/docs/)
    1. Open source smart home hub — integrates with thousands of devices and services
    2. Not yet configured
