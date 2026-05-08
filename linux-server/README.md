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

The web UI runs on `localhost:8088` and `tailscale_ip:5252`. Homepage uses the localhost ping for its status dot and links to the Tailscale IP for access from any Tailscale device.

## Files

- [`setup.sh`](setup.sh) — automated install script
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`zshrc.example`](zshrc.example) — reference zsh config; copied to `~/.zshrc` by `setup.sh` if none exists
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

2. atvloadly | [GitHub](https://github.com/bitxeno/atvloadly)
   1. Self-hosted web app for sideloading IPA files onto Apple TV — a self-deployable alternative to AltStore/Sideloadly
   2. Deploy: `docker run -d --name atvloadly --restart=unless-stopped -p 5533:80 bitxeno/atvloadly`
