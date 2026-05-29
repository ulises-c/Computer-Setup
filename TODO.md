# TODO

## macOS zshrc modernization

Port the linux-desktop zsh enhancements to the macOS config. See
[macOS/zshrc-upgrade.md](macOS/zshrc-upgrade.md) for the full plan.

- [ ] Switch from manual Homebrew plugin sourcing to antidote
- [ ] Add eza aliases with `--icons --group-directories-first`
- [ ] Add RPROMPT with command duration
- [ ] Add colorized man pages via bat
- [ ] Add zsh-notify for desktop notifications on long commands
- [ ] Add fish-style abbreviations via zsh-abbr
- [ ] Add zsh-history-substring-search with Up/Down keybindings
- [ ] Add grouped completion descriptions
- [ ] Add path underlining in syntax highlighting
- [ ] Add zoxide init
- [ ] Add FZF keybindings and completion (Homebrew paths)
- [ ] Create macOS zsh_plugins.txt

## linux-desktop (personal) — CachyOS / Arch

Test and validate the linux-desktop setup on the personal CachyOS desktop
(Arch-based, yay as AUR helper). The package JSON already has Arch support
(`package_manager.arch`, `arch_name` overrides).

- [x] Create an Arch-aware setup script (or extend `setup.sh` with distro detection)
      — `setup.sh` auto-detects ubuntu/arch from `/etc/os-release`, bootstraps `yay`
      via pacman, and drives repo+AUR installs through `yay`
- [x] Verify all `arch_name` overrides resolve to real AUR/pacman packages
      — all resolve; fixed `huggingface-hub` → `python-huggingface-hub`; pyenv/nvm
      switched to the curl installers (unified `~/.pyenv` / `~/.nvm` across all OSes)
- [x] Handle CachyOS defaults that may conflict (e.g., existing fish config)
      — login shell switch reads the real shell via `getent` and switches fish → zsh;
      existing `~/.zshrc` is backed up before replacement
- [x] Add personal-only packages: discord, spotify, steam, bolt-launcher, notion
      — present in `linux_desktop_packages.json` with `environment: ["personal"]`
- [x] Test antidote, zsh-notify, eza icons, and zoxide on CachyOS (after first run)
      — verified via `verify.sh --work` (52/52); antidote clones plugins on first
      zsh launch; zoxide/eza installed. zsh-notify reports "unsupported environment"
      over SSH (no graphical session) — expected, works locally.
- [x] Add a `verify.sh` for linux-desktop (mirrors setup.sh selection + runtime checks)
- [ ] Test `--personal` flag end-to-end
- [ ] Create PR for CachyOS support

## linux-server — Raspberry Pi 4

Set up the Raspberry Pi 4 headless server config under `linux-server/`.

- [ ] Audit existing linux-server/ files and update as needed
- [ ] Create or update packages JSON for the Pi (arm64, Debian-based)
- [ ] Create setup script for headless server (no GUI packages, no snap)
- [ ] Zsh config (server variant — no Ghostty, no fastfetch on launch, no desktop notifications)
- [ ] Tailscale, Docker, SSH hardening
- [ ] Homepage dashboard config (already exists under linux-server/homepage/)
- [ ] Test on Raspberry Pi 4
