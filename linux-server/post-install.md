# Post-install checklist

Run through this after `bash linux-server/setup.sh` completes.

---

## 1. Restart your shell

- [ ] Log out and back in (activates zsh as default shell and adds you to the `docker` group)

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
- [ ] Enable the persistent web UI as a user service:
  ```sh
  mkdir -p ~/.config/systemd/user
  cp linux-server/tailscale-web.service ~/.config/systemd/user/
  systemctl --user enable --now tailscale-web
  loginctl enable-linger $USER
  ```
  Web UI available at `localhost:8088` and `<tailscale-ip>:5252`.

---

## 3. SSH / GPG keys

- [ ] Create SSH key and configure remote hosts:
  ```sh
  bash SSH_and_GPG/create_ssh_key.sh
  ```
- [ ] Create GPG key and configure Git commit signing:
  ```sh
  bash SSH_and_GPG/create_gpg_key.sh
  ```

---

## 4. claude-code

- [ ] Install via curl:
  ```sh
  curl -fsSL https://claude.ai/install.sh | bash
  ```

---

## 5. Docker services

### Homepage
- [ ] Configure and start:
  ```sh
  cd linux-server/homepage
  cp .env.example .env
  # edit .env — set HOMEPAGE_VAR_SERVER_IP to your hostname (e.g. ollie-server.local)
  #              set HOMEPAGE_VAR_TAILSCALE_IP (tailscale ip -4)
  docker compose up -d
  ```
  Access at `http://<server-ip>:3000`

### Portainer
- [ ] Start:
  ```sh
  cd linux-server/portainer && docker compose up -d
  ```
  Access at `http://<server-ip>:9000` — create your admin account **within 5 minutes** or the container must be restarted.

### Glances
- [ ] Start:
  ```sh
  cd linux-server/glances && docker compose up -d
  ```
  Access at `http://<server-ip>:61208`

### Speedtest Tracker
- [ ] Generate `APP_KEY`, configure, and start:
  ```sh
  cd linux-server/speedtest-tracker
  cp .env.example .env
  echo "base64:$(openssl rand -base64 32)"   # paste output as APP_KEY in .env
  docker compose up -d
  ```
  Access at `http://<server-ip>:8765`

### Filebrowser
- [ ] Configure and start:
  ```sh
  cd linux-server/filebrowser
  cp .env.example .env          # set FB_ROOT to the path you want to browse
  touch filebrowser.db          # required — prevents Docker creating it as a directory
  docker compose up -d
  ```
  Access at `http://<server-ip>:8080` — default login: `admin` / `admin` (change immediately).

### Watchtower
- [ ] Start:
  ```sh
  cd linux-server/watchtower && docker compose up -d
  ```
  Checks for updated images daily at 3am and restarts containers automatically.

### Uptime Kuma
- [ ] Start:
  ```sh
  cd linux-server/uptime-kuma && docker compose up -d
  ```
  Access at `http://<server-ip>:3001` — create an admin account on first visit.
- [ ] Add monitors for each service (use `http://localhost:<port>` for internal checks).
- [ ] Create a status page with slug `default` (Dashboards → New Status Page) for the Homepage widget.

### Nginx Proxy Manager
- [ ] Start:
  ```sh
  cd linux-server/nginx-proxy-manager && docker compose up -d
  ```
  Access admin UI at `http://<server-ip>:81` — default login: `admin@example.com` / `changeme`.
- [ ] Change email and password immediately after first login.

### ntfy
- [ ] Start:
  ```sh
  cd linux-server/ntfy && docker compose up -d
  ```
  Access at `http://<server-ip>:5080`.
- [ ] Install the ntfy app on your phone, add your server URL, and subscribe to a topic (e.g. `alerts`).
- [ ] Configure Uptime Kuma and Watchtower to send notifications via ntfy.

### Syncthing
- [ ] Add volume mounts to `linux-server/syncthing/docker-compose.yml` for each folder you want to sync.
- [ ] Start:
  ```sh
  cd linux-server/syncthing && docker compose up -d
  ```
  Access at `http://<server-ip>:8384`.
- [ ] Get your API key: Actions → Settings → API Key — add to `linux-server/homepage/.env`:
  ```
  HOMEPAGE_VAR_SYNCTHING_KEY=<api-key>
  ```

### AdGuard Home
- [ ] Free up port 53 from systemd-resolved:
  ```sh
  sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
  sudo systemctl restart systemd-resolved
  ```
- [ ] Start:
  ```sh
  cd linux-server/adguard && docker compose up -d
  ```
- [ ] Open `http://<server-ip>:3003` for the setup wizard:
  - Set web UI port → `80` (maps to host port `8083`)
  - Set DNS port → `53`
  - Create admin username and password
- [ ] Point your router's DNS to `<server-ip>` to enable network-wide filtering.
- [ ] Add credentials to `linux-server/homepage/.env`:
  ```
  HOMEPAGE_VAR_ADGUARD_USER=<your-username>
  HOMEPAGE_VAR_ADGUARD_PASS=<your-password>
  ```

---

## 6. Tailscale widget (Homepage)

- [ ] Create an OAuth client at `tailscale.com/admin/settings/oauth` with the `devices:read` scope.
- [ ] Get your device ID:
  ```sh
  tailscale status --json | jq -r '.Self.ID'
  ```
- [ ] Add to `linux-server/homepage/.env`:
  ```
  HOMEPAGE_VAR_TAILSCALE_DEVICE_ID=<device-id>
  HOMEPAGE_VAR_TAILSCALE_KEY=<oauth-client-secret>
  ```
- [ ] Restart Homepage to apply:
  ```sh
  cd linux-server/homepage && docker compose restart
  ```
