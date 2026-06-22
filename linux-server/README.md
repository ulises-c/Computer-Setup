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

`setup.sh` handles the Tailscale web UI service, Docker services, and `.env` scaffolding automatically. See `post-install.md` for the remaining manual steps.

## Files

- [`setup.sh`](setup.sh) — thin shim onto the root [`setup.sh`](../setup.sh) (server platform)
- [`post-install.md`](post-install.md) — step-by-step checklist to follow after setup.sh
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`zshrc.example`](zshrc.example) — server zsh config, deployed to `~/.zshrc` by `setup.sh`; overrides the shared [`dotfiles/zshrc.example`](../dotfiles/zshrc.example) base because the server is headless (no Ghostty/fastfetch/notification hooks)
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

The Tailscale web UI service is installed and started by `setup.sh`. The web UI is available at `localhost:8088` and `tailscale_ip:5252`.

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

Start services in this order. Most just need `docker compose up -d`; exceptions are noted.

```sh
# Homepage — update .env with your server details first (see post-install.md)
cd linux-server/homepage && cp .env.example .env
# edit .env, then:
docker compose up -d
# Access at http://<server-ip>:3000 (or https://<tailscale-hostname> after HTTPS setup)

# Portainer
cd linux-server/portainer && docker compose up -d
# Access at http://<server-ip>:9000 — create admin account within 5 minutes

# Glances
cd linux-server/glances && docker compose up -d
# Access at http://<server-ip>:61208

# Speedtest Tracker — requires APP_KEY before first run
cd linux-server/speedtest-tracker && cp .env.example .env
echo "base64:$(openssl rand -base64 32)"  # paste as APP_KEY in .env
docker compose up -d
# Access at http://<server-ip>:8765

# Filebrowser
cd linux-server/filebrowser && cp .env.example .env
# Optionally set FB_ROOT in .env to limit the browsable path (defaults to /)
docker compose up -d
# Access at http://<server-ip>:8080 — default login: admin / admin (change immediately)

# AdGuard Home — fix systemd-resolved conflict first
sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
cd linux-server/adguard && docker compose up -d
# Open http://<server-ip>:3001 for setup wizard
# Set web UI port → 80, DNS port → 53, create admin account
# After setup: http://<server-ip>:8083
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

Get a TLS cert from Tailscale and configure NPM to terminate HTTPS:

```sh
tailscale cert <your-tailscale-hostname>   # e.g. ollie-server.tail01d63b.ts.net
```

In NPM admin (`http://<server-ip>:81`):
1. **SSL Certificates → Add Custom Certificate** — paste the `.crt` and `.key` file contents
2. **Proxy Hosts → Add** — domain: your Tailscale hostname, forward to `http://<server-ip>:3000`, enable SSL with the custom cert
3. **Redirection Hosts → Add** — domain: `<hostname>.local`, redirect to `https://<tailscale-hostname>` (301)

> Requires enabling HTTPS certificates in the Tailscale admin console: `login.tailscale.com/admin/dns`

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
   3. Access at `http://<server-ip>:3000`
   4. Add new services in `config/services.yaml` — each card supports `server: my-docker` + `container: <name>` for live status

2. portainer | [GitHub](https://github.com/portainer/portainer) | [Docs](https://docs.portainer.io)
   1. Web UI for managing Docker containers, images, volumes, and networks
   2. Deploy:
      ```sh
      cd linux-server/portainer
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:9000` (HTTP) or `https://<server-ip>:9443` (HTTPS, self-signed cert)
   4. On first launch, set up an admin account within 5 minutes or the setup will time out

3. atvloadly | [GitHub](https://github.com/bitxeno/atvloadly)
   1. Self-hosted web app for sideloading IPA files onto Apple TV — a self-deployable alternative to AltStore/Sideloadly
   2. Deploy: `docker run -d --name atvloadly --restart=unless-stopped -p 5533:80 bitxeno/atvloadly`

4. filebrowser | [GitHub](https://github.com/filebrowser/filebrowser) | [Docs](https://filebrowser.org)
   1. Web-based file manager — browse, upload, download, edit, and share files on the server from any browser
   2. Deploy:
      ```sh
      cd linux-server/filebrowser
      cp .env.example .env        # optionally set FB_ROOT to limit the browsable path (defaults to /)
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:8080`; default login is `admin` / `admin` — change on first login

5. cockpit | [GitHub](https://github.com/cockpit-project/cockpit) | [Docs](https://cockpit-project.org)
   1. Web-based server admin UI — system metrics, journal logs, network config, storage, and service management
   2. Installed as a system package by `setup.sh` (not Docker); enabled automatically via systemd socket activation
   3. Access at `https://<server-ip>:9090`; log in with your Linux username and password

6. glances | [GitHub](https://github.com/nicolargo/glances) | [Docs](https://glances.readthedocs.io)
   1. Real-time system monitor — CPU, memory, disk I/O, network, processes, temperatures, and Docker containers in one view
   2. Deploy:
      ```sh
      cd linux-server/glances
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:61208`; the Homepage widget shows live CPU stats on the service card

7. speedtest tracker | [GitHub](https://github.com/alexjustesen/speedtest-tracker) | [Docs](https://docs.speedtest-tracker.dev)
   1. Scheduled ISP speed tests with history graphs — tracks ping, download, and upload over time
   2. Deploy:
      ```sh
      cd linux-server/speedtest-tracker
      cp .env.example .env
      echo "base64:$(openssl rand -base64 32)"   # paste output as APP_KEY in .env
      docker compose up -d
      ```
   3. Access at `http://<server-ip>:8765`; runs a test every 6 hours by default (configurable via `SPEEDTEST_SCHEDULE` in `.env`)

8. watchtower | [GitHub](https://github.com/containrrr/watchtower) | [Docs](https://containrrr.dev/watchtower/)
   1. Automatically pulls updated Docker images and restarts containers — runs daily at 3am by default
   2. Deploy:
      ```sh
      cd linux-server/watchtower && docker compose up -d
      ```

9. uptime kuma | [GitHub](https://github.com/louislam/uptime-kuma) | [Docs](https://github.com/louislam/uptime-kuma/wiki)
   1. Self-hosted uptime monitor with status pages and alerts (email, ntfy, Discord, etc.)
   2. Deploy:
      ```sh
      cd linux-server/uptime-kuma && docker compose up -d
      ```
   3. Access at `http://<server-ip>:3001`; create an admin account on first visit
   4. Add monitors for each service, then create a status page with slug `default` for the Homepage widget

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
    1. Reverse proxy with a web UI — handles HTTPS termination for Homepage (Tailscale cert) and HTTP→HTTPS redirect
    2. Deploy:
       ```sh
       cd linux-server/nginx-proxy-manager && docker compose up -d
       ```
    3. Access admin UI at `http://<server-ip>:81`; default login: `admin@example.com` / `changeme` — update immediately
    4. See step 7 above for HTTPS configuration

12. ntfy | [GitHub](https://github.com/binwiederhier/ntfy) | [Docs](https://docs.ntfy.sh)
    1. Self-hosted push notification service — send alerts from any service to your phone or desktop via the ntfy app
    2. Deploy:
       ```sh
       cd linux-server/ntfy && docker compose up -d
       ```
    3. Access at `http://<server-ip>:5080`; subscribe to topics in the ntfy app using your server URL

13. syncthing | [GitHub](https://github.com/syncthing/syncthing) | [Docs](https://docs.syncthing.net)
    1. Decentralized file sync across devices — no cloud required; syncs directly between your server and other devices
    2. Deploy:
       ```sh
       cd linux-server/syncthing && docker compose up -d
       ```
    3. Access at `http://<server-ip>:8384`
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
   4. Open `http://<server-ip>:3003` for the first-run setup wizard
      - Set the web UI port to **80** (maps to host port 8083)
      - Set the DNS port to **53**
      - Create your admin username and password
   5. After setup, access the web UI at `http://<server-ip>:8083`
   6. Point your router's DNS (or individual devices) to `<server-ip>` to start filtering
   7. Add credentials to `linux-server/homepage/.env` to enable the stats widget on Homepage

15. forgejo | [Codeberg](https://codeberg.org/forgejo/forgejo) | [Docs](https://forgejo.org/docs/)
    1. Lightweight self-hosted git service — GitHub-like web UI, SSH push/pull, repo mirroring; LAN/Tailscale only, no public exposure
    2. Deploy:
       ```sh
       cd linux-server/forgejo
       cp .env.example .env   # set FORGEJO_DOMAIN (forgejo.<tailnet>.ts.net) and TS_AUTHKEY; optionally FORGEJO_DATA_PATH for external drive
       docker compose up -d
       ```
    3. Runs behind a Tailscale sidecar (its own tailnet device), so it's reachable only on the tailnet — no host port. Web UI at `http://forgejo.<tailnet>.ts.net:3000` — complete the setup wizard on first visit, create admin account
    4. Git over SSH on port `22` (the sidecar's own tailnet device, no conflict with the host's sshd):
       ```sh
       git clone ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git
       ```
    5. Add your SSH public key in **Settings → SSH / GPG Keys** after creating your account
    6. To migrate from GitHub: use Forgejo's built-in migration (**+ → New Migration → GitHub**), then optionally configure a push mirror back to GitHub under repo **Settings → Push Mirrors** while validating the setup

16. pi-hole | [GitHub](https://github.com/pi-hole/pi-hole) | [Docs](https://docs.pi-hole.net)
    1. Network-wide DNS ad blocker — alternative to AdGuard Home
    2. Not yet configured

17. Immich | [GitHub](https://github.com/immich-app/immich) | [Docs](https://immich.app/docs)
    1. Self-hosted photo and video backup — Google Photos alternative with mobile apps, face recognition, and timeline view
    2. Not yet configured

18. Jellyfin | [GitHub](https://github.com/jellyfin/jellyfin) | [Docs](https://jellyfin.org/docs/)
    1. Self-hosted media server — stream your own movies, TV shows, and music to any device
    2. Not yet configured

19. Home Assistant | [GitHub](https://github.com/home-assistant/core) | [Docs](https://www.home-assistant.io/docs/)
    1. Open source smart home hub — integrates with thousands of devices and services
    2. Not yet configured
