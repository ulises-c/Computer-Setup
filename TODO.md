# TODO

## Setup-script unification (separate PR) — [#36](https://github.com/ulises-c/Computer-Setup/issues/36)

Collapse the three diverged setup stacks (`macOS/`, `linux-desktop/`, `linux-server/`)
into one root `setup.sh` + one `packages.json`, with platform quirks in `platforms/`
and a shared `lib/core.sh`. Full spec, schema, and phased breakdown in
[UNIFICATION.md](UNIFICATION.md). Decisions locked: single `packages.json` (managers
keyed by `{macos,ubuntu,arch,server}`), root dispatcher + platform modules, incremental
migration gated on dry-run parity.

- [x] Phase 1 — Author unified root `packages.json`; build `scripts/parity-check.sh`
      proving per-platform install lists match the current per-folder scripts
      — 231 checks pass (platform × manager × priority × work/personal combos)
- [x] Phase 2 — Extract `lib/core.sh` + `platforms/{macos,arch,ubuntu,server}.sh`; add
      root `setup.sh` dispatcher; gate on `--dry-run` parity vs old scripts
      — `scripts/dryrun-parity.sh` passes 22/22 platform × flag combos
- [ ] Phase 3 — Unify `verify.sh` the same way (shared core + platform checks)
- [ ] Phase 4 — Convert per-folder `setup.sh`/`verify.sh` into thin shims; update
      `README.md` / `CLAUDE.md` for the root entrypoint
- [ ] Phase 5 — Delete the three old per-folder package JSONs once parity is proven
- [ ] Resolve open questions: server-as-platform vs profile; `install_command`
      string vs object; keep `priority: "none"` tier? (see UNIFICATION.md)

## Ghostty config standardization

The ghostty config lives in two places (`macOS/ghostty.config`, `linux-desktop/ghostty.config`)
with identical content. Consider extracting a universal `cross-platform/ghostty.config` for shared
settings (`term = xterm-256color`, `theme`, `shell-integration`) and keeping OS-specific
configs additive-only (e.g., macOS font settings, Linux-specific tweaks).

- [ ] Create `cross-platform/ghostty.config` (universal base)
- [ ] Refactor OS configs to extend/override the universal base
- [ ] Update both `setup.sh` scripts to deploy the new layout (universal + OS overlay)

## OpenCode local models

Config uses `mlx_lm.server` with Qwen 3.5 9B (4bit, MLX) on the Mac Mini M4.
`opencode-local` script auto-discovers models in `~/.models/`, starts the
server, and launches OpenCode.

Still to explore:

- [ ] Test tool-calling quality with Qwen 3.5 9B (does it work well for agentic coding?)
- [ ] Set up on CachyOS/AMD R9700 with Gemma 4 and Qwen 3.6 (via llama.cpp or lemonade)
- [ ] Add CachyOS provider config once the model/runtime is chosen
- [ ] Consider `small_model` for lightweight tasks (title gen, etc.)
- [ ] Install `opencode-local` via install.sh and verify PATH

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
