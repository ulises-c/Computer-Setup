# TODO

## Ghostty config standardization

The ghostty config lives in two places (`macOS/ghostty.config`, `linux-desktop/ghostty.config`)
with identical content. Consider extracting a universal `cross-platform/ghostty.config` for shared
settings (`term = xterm-256color`, `theme`, `shell-integration`) and keeping OS-specific
configs additive-only (e.g., macOS font settings, Linux-specific tweaks).

- [ ] Create `cross-platform/ghostty.config` (universal base)
- [ ] Refactor OS configs to extend/override the universal base
- [ ] Update both `setup.sh` scripts to deploy the new layout (universal + OS overlay)

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
(`package_manager.arch`, `arch_name` overrides) but nothing has been tested.

- [ ] Create an Arch-aware setup script (or extend `setup.sh` with distro detection)
- [ ] Verify all `arch_name` overrides resolve to real AUR/pacman packages
- [ ] Test antidote, zsh-notify, eza icons, and zoxide on CachyOS
- [ ] Handle CachyOS defaults that may conflict (e.g., existing fish config)
- [ ] Add personal-only packages: discord, spotify, steam, bolt-launcher, notion
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
