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
| `HOMEPAGE_VAR_SERVER_IP` | Your server hostname (e.g. `ollie-server.local`) |
| `HOMEPAGE_VAR_TAILSCALE_IP` | `tailscale ip -4` |
| `HOMEPAGE_VAR_ADGUARD_USER` / `_PASS` | Set after AdGuard wizard (step 5 below) |
| `HOMEPAGE_VAR_SYNCTHING_KEY` | Set after Syncthing is running (step 5 below) |
| `HOSTNAME` | `hostname` |
| `SERVER_IP` | `hostname -I \| awk '{print $1}'` |
| `TAILSCALE_HOSTNAME` | `tailscale status --json \| jq -r '.Self.DNSName' \| sed 's/\.$//'` |

---

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

- [ ] Enable HTTPS certificates in the Tailscale admin console: `login.tailscale.com/admin/dns`
- [ ] Get a TLS cert:
  ```sh
  tailscale cert <your-tailscale-hostname>
  # e.g. tailscale cert ollie-server.tail01d63b.ts.net
  ```
- [ ] In NPM admin (`http://<server-ip>:81`):
  - **SSL Certificates → Add Custom Certificate** — paste `.crt` and `.key` file contents; save as e.g. "tailscale cert"
  - **Proxy Hosts → Add** — domain: `<tailscale-hostname>`, forward to `http://<server-ip>:3000`, SSL: select the custom cert
  - **Redirection Hosts → Add** — domain: `<hostname>.local`, scheme: https, forward to `<tailscale-hostname>`, HTTP code: 301

> The Tailscale cert is valid for ~90 days. Renew by re-running `tailscale cert` and updating the cert in NPM.

---

## 7. First-login service setup

### Portainer — http://\<server-ip\>:9000
- [ ] Create admin account **within 5 minutes** — if you miss the window, restart the container

### Filebrowser — http://\<server-ip\>:8080
- [ ] Default login: `admin` / `admin` — change immediately
- [ ] Optionally update `FB_ROOT` in `linux-server/filebrowser/.env` to limit the browsable path, then restart:
  ```sh
  cd linux-server/filebrowser && docker compose restart
  ```

### Uptime Kuma — http://\<server-ip\>:3001
- [ ] Create admin account on first visit
- [ ] Add monitors for each service (use `http://localhost:<port>` for internal checks)
- [ ] Create a status page with slug `default` (used by the Homepage widget)

### Nginx Proxy Manager — http://\<server-ip\>:81
- [ ] Default login: `admin@example.com` / `changeme` — change immediately
- [ ] Configure HTTPS proxy and redirect (see step 6 above)

### ntfy — http://\<server-ip\>:5080
- [ ] Install the ntfy app on your phone, add your server URL, subscribe to a topic (e.g. `alerts`)
- [ ] Configure Uptime Kuma and Watchtower to send notifications via ntfy

### AdGuard Home — http://\<server-ip\>:3003
- [ ] Complete the setup wizard:
  - Web UI port → `80` (maps to host port `8083`)
  - DNS port → `53`
  - Create admin credentials — then add them to `homepage/.env`
- [ ] Point your router's DNS to `<server-ip>` for network-wide filtering

### Syncthing — http://\<server-ip\>:8384
- [ ] Add volume mounts to `linux-server/syncthing/docker-compose.yml` for each folder to sync, then restart:
  ```sh
  cd linux-server/syncthing && docker compose restart
  ```
- [ ] Get API key: Actions → Settings → API Key — add to `homepage/.env` as `HOMEPAGE_VAR_SYNCTHING_KEY`

---

## 8. Service reference

| Service | URL | Notes |
|---|---|---|
| Homepage | https://\<tailscale-hostname\> | Primary; or http://\<server-ip\>:3000 on LAN |
| Portainer | http://\<server-ip\>:9000 | Create admin within 5 min |
| Glances | http://\<server-ip\>:61208 | |
| Speedtest Tracker | http://\<server-ip\>:8765 | |
| Filebrowser | http://\<server-ip\>:8080 | Default: admin / admin |
| Watchtower | — | Background only, no UI |
| Uptime Kuma | http://\<server-ip\>:3001 | |
| Nginx Proxy Manager | http://\<server-ip\>:81 | Default: admin@example.com / changeme |
| ntfy | http://\<server-ip\>:5080 | |
| Syncthing | http://\<server-ip\>:8384 | |
| AdGuard Home | http://\<server-ip\>:8083 | Run setup wizard at :3003 first |
| Cockpit | https://\<server-ip\>:9090 | |
| Tailscale Web UI | http://localhost:8088 | After `tailscale up` |
| Tailscale proxy | http://localhost:8089 | Internal — used by Homepage widget |
