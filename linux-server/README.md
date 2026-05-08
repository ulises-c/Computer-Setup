# Linux server setup

Tested on Ubuntu Server LTS. Most packages work on other Debian-based distros.

## Quick start

```sh
bash linux-server/setup.sh             # core packages + zsh setup
bash linux-server/setup.sh --optional  # also install samba, smartmontools, nmap, ffmpeg, etc.
bash linux-server/setup.sh --dry-run   # preview without installing
```

After running, log out and back in to start using zsh.

## Files

- [`setup.sh`](setup.sh) — automated install script
- [`apt_packages.md`](apt_packages.md) — full package list with descriptions and links
- [`zshrc.example`](zshrc.example) — reference zsh config; copied to `~/.zshrc` by `setup.sh` if none exists
- [`linux_server_packages.json`](linux_server_packages.json) — machine-readable package manifest used by `setup.sh`

## Docker services

1. atvloadly | [GitHub](https://github.com/bitxeno/atvloadly)
   1. Self-hosted web app for sideloading IPA files onto Apple TV — a self-deployable alternative to AltStore/Sideloadly
   2. Deploy: `docker run -d --name atvloadly --restart=unless-stopped -p 5533:80 bitxeno/atvloadly`
