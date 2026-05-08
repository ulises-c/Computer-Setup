# Linux server apt packages

Install via `sudo apt install <name>` unless noted otherwise.
Tested on Ubuntu Server LTS. Most packages work on other Debian-based distros.

## Shell

1. zsh | [apt](https://packages.ubuntu.com/search?keywords=zsh) | [Homepage](https://www.zsh.org/)
   1. Z shell — consistent shell across all devices; set as default by `setup.sh`
2. zsh-autosuggestions | [apt](https://packages.ubuntu.com/search?keywords=zsh-autosuggestions) | [GitHub](https://github.com/zsh-users/zsh-autosuggestions)
   1. Fish-style history-based suggestions for zsh — press → to accept
3. zsh-syntax-highlighting | [apt](https://packages.ubuntu.com/search?keywords=zsh-syntax-highlighting) | [GitHub](https://github.com/zsh-users/zsh-syntax-highlighting)
   1. Real-time syntax highlighting in zsh — valid commands appear green, invalid ones red, before pressing Enter

## CLI Tools

4. fastfetch | [PPA](https://launchpad.net/~zhangsongcui3371/+archive/ubuntu/fastfetch) | [GitHub](https://github.com/fastfetch-cli/fastfetch)
   1. Fast, customizable system info display — shown on every interactive shell startup in the example zshrc
   2. Not in standard Ubuntu repos; `setup.sh` adds the official PPA automatically
5. fzf | [apt](https://packages.ubuntu.com/search?keywords=fzf) | [GitHub](https://github.com/junegunn/fzf)
   1. Fuzzy finder — Ctrl+R for history search, Ctrl+T for file search; key bindings sourced in zshrc
6. ripgrep | [apt](https://packages.ubuntu.com/search?keywords=ripgrep) | [GitHub](https://github.com/BurntSushi/ripgrep)
   1. Fast recursive grep replacement — command: `rg`
7. bat | [apt](https://packages.ubuntu.com/search?keywords=bat) | [GitHub](https://github.com/sharkdp/bat)
   1. `cat` with syntax highlighting and git integration
   2. Ubuntu installs the binary as `batcat` due to a naming conflict; zshrc aliases `bat=batcat` and `setup.sh` creates a symlink
8. fd-find | [apt](https://packages.ubuntu.com/search?keywords=fd-find) | [GitHub](https://github.com/sharkdp/fd)
   1. Fast and user-friendly `find` alternative — command: `fd`
   2. Ubuntu installs the binary as `fdfind`; zshrc aliases `fd=fdfind` and `setup.sh` creates a symlink
9. eza | [apt](https://github.com/eza-community/eza/blob/main/INSTALL.md) | [GitHub](https://github.com/eza-community/eza)
   1. Modern `ls` replacement with icons, colors, and git status per file
   2. Not in standard Ubuntu repos; `setup.sh` adds the eza community apt repo automatically
   3. Used for `ll` and `la` aliases in zshrc: `ll='eza -lAh --git'`

## Development

10. gh | [apt](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) | [GitHub](https://github.com/cli/cli)
    1. GitHub CLI — create PRs, manage issues, clone repos, and trigger Actions from the terminal
    2. `setup.sh` adds the official GitHub CLI apt repo automatically
11. git | [apt](https://packages.ubuntu.com/search?keywords=git) | [Homepage](https://git-scm.com/)
    1. Version control — usually pre-installed on Ubuntu Server
12. git-lfs | [apt](https://packages.ubuntu.com/search?keywords=git-lfs) | [GitHub](https://github.com/git-lfs/git-lfs)
    1. Git extension for versioning large binary files (datasets, model weights, media)
13. gnupg | [apt](https://packages.ubuntu.com/search?keywords=gnupg) | [Homepage](https://gnupg.org/)
    1. GPG — required for commit signing; used by `SSH_and_GPG/create_gpg_key.sh`

## System Monitoring

14. htop | [apt](https://packages.ubuntu.com/search?keywords=htop) | [GitHub](https://github.com/htop-dev/htop)
    1. Interactive process viewer — colorized, scrollable alternative to `top` with per-core CPU, memory, and swap meters
15. nvtop | [apt](https://packages.ubuntu.com/search?keywords=nvtop) | [GitHub](https://github.com/Syllo/nvtop)
    1. GPU process monitor similar to htop — supports NVIDIA, AMD, Intel, and integrated GPUs

## Server Utilities

16. tmux | [apt](https://packages.ubuntu.com/search?keywords=tmux) | [GitHub](https://github.com/tmux/tmux)
    1. Terminal multiplexer — split panes, persist sessions across SSH disconnects, run background processes
17. micro | [apt](https://packages.ubuntu.com/search?keywords=micro) | [GitHub](https://github.com/zyedidia/micro)
    1. Modern terminal text editor with mouse support, syntax highlighting, and familiar keybindings (Ctrl+S, Ctrl+C, etc.)
18. ncdu | [apt](https://packages.ubuntu.com/search?keywords=ncdu) | [Homepage](https://dev.yorhel.nl/ncdu)
    1. Interactive disk usage analyzer — essential for managing storage on a file server
19. sshpass | [apt](https://packages.ubuntu.com/search?keywords=sshpass) | [Homepage](https://sourceforge.net/projects/sshpass/)
    1. Non-interactive SSH password authentication — used by `SSH_and_GPG/add_remote_host.sh`

## Optional

Install with `bash linux-server/setup.sh --optional`.

1. samba | [apt](https://packages.ubuntu.com/search?keywords=samba) | [Homepage](https://www.samba.org/)
   1. SMB/CIFS file sharing — exposes network shares to macOS and Windows clients
   2. Requires manual `/etc/samba/smb.conf` configuration after install
2. smartmontools | [apt](https://packages.ubuntu.com/search?keywords=smartmontools) | [Homepage](https://www.smartmontools.org/)
   1. Monitor SSD/HDD health via S.M.A.R.T. data — `smartctl -a /dev/sdX`
3. nmap | [apt](https://packages.ubuntu.com/search?keywords=nmap) | [Homepage](https://nmap.org/)
   1. Network scanner — discover hosts and open ports on the local network
4. net-tools | [apt](https://packages.ubuntu.com/search?keywords=net-tools)
   1. Legacy network utilities — `ifconfig`, `netstat`, `route`
5. ffmpeg | [apt](https://packages.ubuntu.com/search?keywords=ffmpeg) | [Homepage](https://ffmpeg.org/)
   1. Audio/video processing toolkit — convert, trim, encode, and extract frames from media files
6. libimage-exiftool-perl | [apt](https://packages.ubuntu.com/search?keywords=libimage-exiftool-perl) | [Homepage](https://exiftool.org/)
   1. Read and write metadata (EXIF, IPTC, XMP) in photos, videos, and other files — command: `exiftool`

## Manual installs

These require their own installer or setup — not handled by `setup.sh`.

1. nvm | [GitHub](https://github.com/nvm-sh/nvm)
   1. Node version manager — required before installing any npm packages (e.g. claude-code)
   2. After install, run: `nvm install lts/* && nvm alias default lts/*`
   3. **Default (curl):** `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash`
   4. **Alternatives:**
      - wget: `wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash`
      - apt (system Node, no version management): `sudo apt install nodejs npm`
2. claude-code | [npm](https://www.npmjs.com/package/@anthropic-ai/claude-code) | [Docs](https://docs.anthropic.com/en/docs/claude-code)
   1. Terminal-based AI coding assistant from Anthropic — agentic coding, file editing, shell commands, and MCP integrations
   2. Requires nvm + Node installed first: `npm install -g @anthropic-ai/claude-code`
3. docker-ce | [Docs](https://docs.docker.com/engine/install/ubuntu/) | [GitHub](https://github.com/docker/docker-ce)
   1. Container platform — official Docker Engine for Linux
   2. Convenience script (installs CE, CLI, compose plugin, and containerd): `curl -fsSL https://get.docker.com | sudo sh`
4. tailscale | [Docs](https://tailscale.com/download/linux) | [Homepage](https://tailscale.com/)
   1. Zero-config VPN — access the server from anywhere without port forwarding or firewall rules
   2. Use `setup_tailscale.sh` rather than installing manually — it handles install, authentication, and optional flags:
      ```sh
      bash linux-server/setup_tailscale.sh                        # basic
      bash linux-server/setup_tailscale.sh --ssh                  # enable Tailscale SSH
      bash linux-server/setup_tailscale.sh --advertise-exit-node  # use server as exit node
      ```
