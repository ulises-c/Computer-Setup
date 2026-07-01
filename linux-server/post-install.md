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
  # e.g. tailscale cert <hostname>.<tailnet>.ts.net
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

### Forgejo — https://\<tailscale-hostname\>/

Forgejo runs behind a Tailscale sidecar (HTTPS via `tailscale serve`), so it is
reachable only on the tailnet at `https://forgejo.<tailnet>.ts.net/` — there is
no `<server-ip>` host port.

- [ ] Copy and edit the env file:
  ```sh
  cd linux-server/forgejo && cp .env.example .env
  # Set FORGEJO_DOMAIN to forgejo.<tailnet>.ts.net
  # Set TS_AUTHKEY (tailscale.com/admin/settings/keys) so the sidecar can join
  # Optionally set FORGEJO_DATA_PATH to an external drive path
  ```
- [ ] Start Forgejo:
  ```sh
  docker compose up -d
  ```
- [ ] Open `https://forgejo.<tailnet>.ts.net/` and complete the setup wizard:
  - Database: SQLite (pre-set)
  - SSH server domain and port: pre-filled from `.env` — verify they look correct
  - Application URL: should match `https://forgejo.<tailnet>.ts.net/`
  - Create the admin account at the bottom of the wizard page
- [ ] Generate a personal access token for the Homepage widget:
  - Top-right avatar → **Settings → Applications → Generate Token** — scope: all (or read-only is enough for the widget)
  - Add to `homepage/.env`:
    - `HOMEPAGE_VAR_FORGEJO_TOKEN=<token>`
    - `HOMEPAGE_VAR_FORGEJO_DOMAIN=<tailscale-hostname>`
  - Restart Homepage: `cd linux-server/homepage && docker compose restart`
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
runner (see [`../../macOS/forgejo-runner/`](../../macOS/forgejo-runner/)) is
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
  sudo cp forgejo-runner-status.service forgejo-runner-status.timer /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now forgejo-runner-status.timer
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

- [ ] In Uptime Kuma (`https://uptime-kuma.<tailnet>.ts.net`): **Add New
      Monitor → Monitor Type: `Push`**. Name it e.g. `Forgejo runner (m4-mini)`.
- [ ] Match the timer: **Heartbeat Interval 120s**, **Retries 2**, **Retry
      Interval 20s**. The retries give ~160s of slack before a down, so normal
      jitter on the 2-minute push doesn't trip a false alarm.
- [ ] Save, then copy the generated push URL (through `/api/push/<token>` — the
      script appends its own `status`/`msg` params) into `KUMA_PUSH_URL` in
      `forgejo/.env`.
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

### Syncthing — http://\<server-ip\>:8384
- [ ] Add volume mounts to `linux-server/syncthing/docker-compose.yml` for each folder to sync, then restart:
  ```sh
  cd linux-server/syncthing && docker compose restart
  ```
- [ ] Get API key: Actions → Settings → API Key — add to `homepage/.env` as `HOMEPAGE_VAR_SYNCTHING_KEY`

### UPS (NUT) — host service, no UI

Monitors the CyberPower UPS over USB; alerts via ntfy and shuts the server down
cleanly on low battery. Full runbook in [`ups/README.md`](ups/README.md).

- [ ] Configure and deploy:
  ```sh
  cd linux-server/ups
  cp .env.example .env   # set UPSMON_PASSWORD (openssl rand -hex 16) + ntfy
  sudo bash setup.sh
  ```
- [ ] Verify: `upsc cyberpower ups.status` prints `OL`
- [ ] Start the PeaNUT dashboard (`docker compose up -d`) — graphs at
      `http://<server-ip>:8097`, and the homepage **ups** card goes live
- [ ] Subscribe to the `server-ups` ntfy topic on your phone
- [ ] Set BIOS **Restore on AC Power Loss → Power On**

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
| PeaNUT (UPS) | http://\<server-ip\>:8097 | Homepage ups card reads it via localhost |
| Tailscale Web UI | http://localhost:8088 | After `tailscale up` |
| Tailscale proxy | http://localhost:8089 | Internal — used by Homepage widget |
| Forgejo | https://forgejo.\<tailnet\>.ts.net/ | Tailscale sidecar (HTTPS via serve); Git over SSH on port 22 |
