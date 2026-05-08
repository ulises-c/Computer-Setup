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
| `HOMEPAGE_VAR_TAILSCALE_DEVICE_ID` | `tailscale status --json \| jq -r '.Self.ID'` |
| `HOMEPAGE_VAR_TAILSCALE_KEY` | OAuth client from `tailscale.com/admin/settings/oauth` (scope: `devices:read`) |
| `HOMEPAGE_VAR_ADGUARD_USER` / `_PASS` | Set after AdGuard wizard (step 5 below) |
| `HOMEPAGE_VAR_SYNCTHING_KEY` | Set after Syncthing is running (step 5 below) |

---

## 5. First-login service setup

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

## 6. Service reference

| Service | URL | Notes |
|---|---|---|
| Homepage | http://\<server-ip\>:3000 | |
| Portainer | http://\<server-ip\>:9000 | Create admin within 5 min |
| Glances | http://\<server-ip\>:61208 | |
| Speedtest Tracker | http://\<server-ip\>:8765 | |
| Filebrowser | http://\<server-ip\>:8080 | Default: admin / admin |
| Watchtower | — | Background only, no UI |
| Uptime Kuma | http://\<server-ip\>:3001 | |
| Nginx Proxy Manager | http://\<server-ip\>:81 | Default: admin@example.com / changeme |
| ntfy | http://\<server-ip\>:5080 | |
| Syncthing | http://\<server-ip\>:8384 | |
| AdGuard Home | http://\<server-ip\>:3003 | Run setup wizard |
| Cockpit | https://\<server-ip\>:9090 | |
| Tailscale Web UI | http://localhost:8088 | After `tailscale up` |
