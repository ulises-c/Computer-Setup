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
      — 231 checks passed (platform × manager × priority × work/personal combos;
      gate deleted in Phase 5 along with its legacy-JSON inputs)
- [x] Phase 2 — Extract `lib/core.sh` + `platforms/{macos,arch,ubuntu,server}.sh`; add
      root `setup.sh` dispatcher; gate on `--dry-run` parity vs old scripts
      — `scripts/dryrun-parity.sh` passed 22/22 platform × flag combos (gate deleted in Phase 4)
- [x] Phase 3 — Unify `verify.sh` the same way (shared core + platform checks)
      — `scripts/verify-parity.sh` passed 21/21 platform × flag combos (gate deleted in Phase 4)
- [x] Phase 4 — Convert per-folder `setup.sh`/`verify.sh` into thin shims; update
      `README.md` / `CLAUDE.md` for the root entrypoint
      — shim output diffed byte-identical vs direct root invocation; the script-level
      gates (`dryrun-parity.sh`, `verify-parity.sh`) self-compare post-shim and were
      deleted (last green run at a8d4149); `scripts/dryrun-smoke.sh` (root dry-run on
      all four platforms, also in CI) took their place; `parity-check.sh` stayed
      through Phase 5's final green run
- [x] Phase 5 — Delete the three old per-folder package JSONs once parity is proven
      — legacy JSONs + `scripts/parity-check.sh` (whose inputs they were) deleted;
      server claude-code install folded into `packages.json` (`server: custom`,
      `handled_by_setup: true`); custom-package reminders generalized into
      `lib/core.sh`, so ubuntu now prints manual-install commands for `git-xet` /
      `claude-desktop` instead of silently skipping them (the legacy gap);
      dry-run output diffed vs pre-Phase-5 baseline — identical except that addition
- [x] Resolve open questions: server-as-platform vs profile; `install_command`
      string vs object; keep `priority: "none"` tier? (see UNIFICATION.md)
      — resolved: server is a platform key (option A, locked in Phase 1);
      `install_command` supports both string and per-platform object (`icfor`);
      `priority: "none"` tier kept — reminder/`--all`-only, never auto-installs
- [x] Phase 6 — Merge main (PRs #28 p10k/LACT, #35 railguard, #38 claude-hud) into
      the branch; port the features that landed on the legacy stack into the unified
      one: `zsh-theme-powerlevel10k` + `lact` entries into root `packages.json`,
      `~/.p10k.zsh` deploy (`deploy_config`) into the shared desktop flow.
      Legacy `linux-desktop/setup.sh` stayed a shim; the legacy JSON stayed deleted.
      Gate: per-platform dry-run diff vs pre-merge baseline — only the intended
      additions (two arch packages, p10k deploy lines)
- [x] Phase 7 — Dotfiles consolidation (details in the section below): shared
      `tmux.conf`/`ghostty.config` moved to `dotfiles/`, all engine deploys
      repointed, macOS gains the previously missing tmux deploy.
      Gate: per-platform dry-run diff vs pre-change baseline — identical except
      macOS's new tmux step

## Dotfiles consolidation — DONE as unification Phase 7 (PR #37)

Shared configs were duplicated per-folder and could drift silently across devices.
Folded into #37 once the root engine owned all deploys.

- [x] Create `dotfiles/` and move the byte-identical files: `tmux.conf`, `ghostty.config`
- [x] Point the root engine's deploy steps (`lib/core.sh`, `platforms/macos.sh`,
      `platforms/server.sh`) at the new paths; drop the per-folder copies
- [x] Deploy tmux.conf on macOS too (was the missing platform — Macs showed the
      default green bottom bar while Linux boxes got the blue top bar)
- [x] Ghostty: single universal config in `dotfiles/` (the two copies were already
      byte-identical); no overlay mechanism until an OS-specific setting actually
      exists
- [x] zshrc: `dotfiles/zshrc.example` is the shared base (`deploy_zshrc`); a platform
      folder shipping its own `zshrc.example` overrides it — only `linux-server/`
      does, because it's headless (no Ghostty/fastfetch/notification hooks)
- [x] macOS zsh unification: the dotfiles zshrc is cross-platform (macOS bits guarded
      on `/opt/homebrew`/`$OSTYPE` — Homebrew PATH+FPATH, brew p10k/antidote/fzf
      paths, `ls -G`, `brewup`, `PIPX_DEFAULT_PYTHON`, nvm `--delete-prefix`); macOS
      deploys it + `dotfiles/zsh_plugins.txt` via the engine instead of appending
      lines to `~/.zshrc` (`add_to_zshrc` deleted). antidote/zoxide/fzf/bat/fd/
      terminal-notifier gained `macos: brew` entries; the brew
      zsh-autosuggestions/zsh-syntax-highlighting entries were dropped (antidote
      manages the plugins now — `brew uninstall` them on the Mac after migrating).
      `macOS/zshrc.example` + `zshrc-upgrade.md` deleted (plan absorbed)
      (e.g., macOS font settings, Linux-specific tweaks)
- [ ] Mac mini live-run cleanup (from the 2026-06 `brew leaves` audit): `brew
      uninstall` the testing leftovers `forgejo`, `tea`, and `python@3.12`
      (project Pythons come from pyenv/uv), plus `zsh-autosuggestions` /
      `zsh-syntax-highlighting` / `powerlevel10k` (antidote manages them now),
      and `brew uninstall --cask claude-code` (repo installs it via curl)
- [ ] MBP live-run cleanup (same audit): `brew uninstall tea python-tk@3.11
      python@3.11 zsh-autosuggestions zsh-syntax-highlighting powerlevel10k`;
      pre-existing casks (anki, ghostty, obsidian) get picked up by the cask
      `--adopt` flag
- [x] Ubuntu desktop live run (2026-06, at `eb0fe49`): gh migrated to the
      official cli.github.com apt repo, micro/obsidian snaps in, uv via pipx,
      shared zshrc + p10k + ghostty deployed (zshrc auto-backup worked).
      `verify.sh --work` green except the by-design manual installs
      (forgejo-cli, opencode, zen-browser, anki)
- [x] Ubuntu live-run follow-up: p10k never loaded — the only installer was the
      arch-only `zsh-theme-powerlevel10k` yay entry, so Ubuntu/macOS fell back to
      vcs_info. Dropped the entry; `romkatv/powerlevel10k` is now an antidote
      plugin on all desktops and the zshrc guards the fallback on
      `$+functions[p10k]`
- [ ] Dropped when PR #38 auto-closed #34: track the claude-hud display config
      (`~/.claude/plugins/claude-hud/config.json`) under `agentic-ai/Claude/` and
      symlink it from `install.sh` (#34 task 2). Task 3 — the statusLine
      `/usr/bin/node` hardcode — is fixed on this branch (runtime `command -v
      node` with an nvm-glob fallback)
- [ ] Ubuntu desktop leftover: `sudo apt remove micro` — the stale apt 2.0.13
      still shadows the snap (`/usr/bin` precedes `/snap/bin` in PATH)
- [ ] Caveat for the remaining live runs (CachyOS, both Macs): setup migrates
      install methods but never uninstalls the old copy — after each run,
      `command -v` every migrated tool to catch shadowed binaries
- [ ] Later: consider base + per-platform overlay for zshrc (desktop vs server vs macOS)

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

## Per-service HTTPS rollout (linux-server)

Convert each self-hosted service from `http://<server-ip>:<port>` to its own
`https://<svc>.<tailnet>.ts.net/` via a Tailscale sidecar. Pattern, prereqs,
and full rollout table in [linux-server/HTTPS.md](linux-server/HTTPS.md).

- [x] forgejo — reference impl (sidecar + SSH :22), done in 8ff8a2c
- [x] portainer — sidecar live at https://portainer.<tailnet>.ts.net/, homepage
      link updated
- [x] uptime-kuma — sidecar live at https://uptime-kuma.<tailnet>.ts.net/,
      homepage link & widget url updated
- [x] speedtest-tracker — sidecar live at https://speedtest.<tailnet>.ts.net/,
      homepage link & widget url updated
- [x] ntfy — sidecar live at https://ntfy.<tailnet>.ts.net/, homepage link
      updated
- [ ] filebrowser
- [ ] syncthing — GUI only; sync ports stay host-published
- [ ] glances
- [ ] adguard — admin UI only; DNS :53 stays host-published
- [ ] nginx-proxy-manager — optional, only if NPM is kept
- [ ] homepage — special case: `tailscale serve` on the main node, not a sidecar
- [ ] cockpit — host service, not a container; use host `tailscale serve`
- [x] Decide auth method: OAuth client + `tag:container` (reusing the elevated
      tailscale-proxy client) — resolved during the Forgejo rollout, see HTTPS.md
- [ ] Decide whether to retire NPM (tailnet-only) or keep it for LAN/`.local` HTTPS
- [ ] Update Homepage hrefs to HTTPS as each service converts; a service's widget
      `url:` must move to the HTTPS domain too (localhost stops resolving once the
      host port is dropped)

## linux-server — Raspberry Pi 4

Set up the Raspberry Pi 4 headless server config under `linux-server/`.

- [ ] Audit existing linux-server/ files and update as needed
- [ ] Create or update packages JSON for the Pi (arm64, Debian-based)
- [ ] Create setup script for headless server (no GUI packages, no snap)
- [ ] Zsh config (server variant — no Ghostty, no fastfetch on launch, no desktop notifications)
- [ ] Tailscale, Docker, SSH hardening
- [ ] Homepage dashboard config (already exists under linux-server/homepage/)
- [ ] Test on Raspberry Pi 4
