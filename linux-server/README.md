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
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`zshrc.example`](zshrc.example) — reference zsh config; copied to `~/.zshrc` by `setup.sh` if none exists
- [`tmux.conf`](tmux.conf) — tmux config with mouse support, vi copy mode, and a status bar; copied to `~/.tmux.conf` by `setup.sh`
- [`linux_server_packages.json`](linux_server_packages.json) — machine-readable package manifest used by `setup.sh`

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

8. pi-hole | [GitHub](https://github.com/pi-hole/pi-hole) | [Docs](https://docs.pi-hole.net)
   1. Network-wide DNS ad blocker — blocks ads and trackers at the DNS level for every device on the network; includes a query log and allowlist/blocklist management
   2. Not yet configured

9. AdGuard Home | [GitHub](https://github.com/AdguardTeam/AdGuardHome) | [Docs](https://adguard-dns.io/kb/adguard-home/overview/)
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
   4. Open `http://<server-ip>:3001` for the first-run setup wizard
      - Set the web UI port to **80** (maps to host port 8083)
      - Set the DNS port to **53**
      - Create your admin username and password
   5. After setup, access the web UI at `http://<server-ip>:8083`
   6. Point your router's DNS (or individual devices) to `<server-ip>` to start filtering
   7. Add credentials to `linux-server/homepage/.env` to enable the stats widget on Homepage
