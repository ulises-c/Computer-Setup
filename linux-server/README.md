# Linux server setup

Tested on Ubuntu Server LTS. Most packages work on other Debian-based distros.

## Quick start

```sh
bash linux-server/setup.sh             # core packages + zsh setup
bash linux-server/setup.sh --optional  # also install samba, smartmontools, nmap, ffmpeg, etc.
bash linux-server/setup.sh --dry-run   # preview without installing
```

After running, log out and back in to start using zsh.

After setup.sh completes, authenticate Tailscale and enable the persistent web UI:

```sh
sudo tailscale up
sudo tailscale set --operator=$USER
mkdir -p ~/.config/systemd/user
cp linux-server/tailscale-web.service ~/.config/systemd/user/
systemctl --user enable --now tailscale-web
loginctl enable-linger $USER   # keeps the service running without a login session
```

The web UI runs on `localhost:8088` and `tailscale_ip:5252`. Homepage links to the Tailscale IP for access from any Tailscale device.

To enable the Tailscale widget on Homepage, create an OAuth client at `tailscale.com/admin/settings/oauth` with the `devices:read` scope, then add the credentials to `linux-server/homepage/.env`:

```sh
# Get your device ID
tailscale status --json | jq -r '.Self.ID'
```

## Files

- [`setup.sh`](setup.sh) — automated install script
- [`post-install.md`](post-install.md) — step-by-step checklist to follow after setup.sh
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`zshrc.example`](zshrc.example) — reference zsh config; copied to `~/.zshrc` by `setup.sh` if none exists
- [`tmux.conf`](tmux.conf) — tmux config with mouse support, vi copy mode, and a status bar; copied to `~/.tmux.conf` by `setup.sh`
- [`linux_server_packages.json`](linux_server_packages.json) — machine-readable package manifest used by `setup.sh`

## Next steps

`setup.sh` handles packages, zsh, tmux, Tailscale, and Docker. Everything below is manual and should be done in order after the script finishes.

### 1. Restart your shell

Log out and back in. This activates zsh as your default shell and adds you to the `docker` group (required to run Docker without sudo).

### 2. Tailscale

```sh
sudo tailscale up
sudo tailscale set --operator=$USER
mkdir -p ~/.config/systemd/user
cp linux-server/tailscale-web.service ~/.config/systemd/user/
systemctl --user enable --now tailscale-web
loginctl enable-linger $USER
```

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
# Homepage — update .env with your server hostname and Tailscale IP first
cd linux-server/homepage && cp .env.example .env
# edit .env, then:
docker compose up -d
# Access at http://<server-ip>:3000

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

# Filebrowser — touch db file first or Docker creates it as a directory
cd linux-server/filebrowser && cp .env.example .env
touch filebrowser.db
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

### 6. Tailscale widget credentials

Create an OAuth client at `tailscale.com/admin/settings/oauth` with the `devices:read` scope, then fill in `linux-server/homepage/.env`:

```sh
tailscale status --json | jq -r '.Self.ID'   # your device ID
```

Set `HOMEPAGE_VAR_TAILSCALE_DEVICE_ID` and `HOMEPAGE_VAR_TAILSCALE_KEY` in the `.env`, then restart Homepage:

```sh
cd linux-server/homepage && docker compose restart
```

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
      cp .env.example .env        # set FB_ROOT to the path you want to browse
      touch filebrowser.db        # required — prevents Docker creating it as a directory
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

10. nginx proxy manager | [GitHub](https://github.com/jc21/nginx-proxy-manager) | [Docs](https://nginxproxymanager.com/guide/)
    1. Reverse proxy with a web UI — assign clean hostnames to services and get SSL certs via Let's Encrypt automatically
    2. Deploy:
       ```sh
       cd linux-server/nginx-proxy-manager && docker compose up -d
       ```
    3. Access admin UI at `http://<server-ip>:81`; default login: `admin@example.com` / `changeme` — update immediately

11. ntfy | [GitHub](https://github.com/binwiederhier/ntfy) | [Docs](https://docs.ntfy.sh)
    1. Self-hosted push notification service — send alerts from any service to your phone or desktop via the ntfy app
    2. Deploy:
       ```sh
       cd linux-server/ntfy && docker compose up -d
       ```
    3. Access at `http://<server-ip>:5080`; subscribe to topics in the ntfy app using your server URL

12. syncthing | [GitHub](https://github.com/syncthing/syncthing) | [Docs](https://docs.syncthing.net)
    1. Decentralized file sync across devices — no cloud required; syncs directly between your server and other devices
    2. Deploy:
       ```sh
       cd linux-server/syncthing && docker compose up -d
       ```
    3. Access at `http://<server-ip>:8384`
    4. Add volume mounts to `docker-compose.yml` for each folder you want to sync, then configure them in the web UI
    5. Get your API key from Actions → Settings → API Key and add it to `linux-server/homepage/.env` for the Homepage widget

13. AdGuard Home | [GitHub](https://github.com/AdguardTeam/AdGuardHome) | [Docs](https://adguard-dns.io/kb/adguard-home/overview/)
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

14. pi-hole | [GitHub](https://github.com/pi-hole/pi-hole) | [Docs](https://docs.pi-hole.net)
    1. Network-wide DNS ad blocker — alternative to AdGuard Home
    2. Not yet configured

15. Immich | [GitHub](https://github.com/immich-app/immich) | [Docs](https://immich.app/docs)
    1. Self-hosted photo and video backup — Google Photos alternative with mobile apps, face recognition, and timeline view
    2. Not yet configured

16. Jellyfin | [GitHub](https://github.com/jellyfin/jellyfin) | [Docs](https://jellyfin.org/docs/)
    1. Self-hosted media server — stream your own movies, TV shows, and music to any device
    2. Not yet configured

17. Home Assistant | [GitHub](https://github.com/home-assistant/core) | [Docs](https://www.home-assistant.io/docs/)
    1. Open source smart home hub — integrates with thousands of devices and services
    2. Not yet configured
