# Changelog

Notable changes to this personal machine-provisioning repo. There are no tagged
releases; entries are grouped by the date work merged to `main`, newest first.
Format loosely follows [Keep a Changelog](https://keepachangelog.com). Remaining
work lives in [TODO.md](TODO.md); the design rationale for the unified layout is
in [UNIFICATION.md](docs/UNIFICATION.md).

## 2026-07-11 — UPS monitoring, server ([#59](https://github.com/ulises-c/Computer-Setup/pull/59))

### Added
- NUT support for the CyberPower PR1500LCDRT2U under `linux-server/ups/`.
- PeaNUT UPS dashboard, fronted by a Tailscale HTTPS sidecar
  (`https://peanut.<tailnet>.ts.net/`) with a homepage widget.

## 2026-07-01 — macOS benchmark suite ([#53](https://github.com/ulises-c/Computer-Setup/pull/53))

### Added
- `macOS/benchmarks/`: benchmark, stress-test, LLM (llama.cpp), and oMLX suites,
  plus a standardized suite (Cinebench, Blender, Geekbench, Geekbench AI).
- `stats` macOS menubar system monitor and a `benchmarking` tag category in
  `packages.json`; app-store-style `.app` verify probe for GUI-only custom entries.

### Fixed
- Resolved 30 findings from a max-effort review of the suite (full record:
  [docs/macos-benchmark-review.md](docs/macos-benchmark-review.md)):
  - **P0** — broken measurement paths and silent data corruption: LibreSSL
    `openssl speed -seconds` unsupported, `llama-bench --hf-repo` arg failure,
    null GPU/Cinebench/Blender parses, throttle-methodology and Apple-Silicon
    powermetrics mismatches, failed-request accounting in the oMLX suite, and a
    `set -e` abort when a custom installer 404s.
  - **P1** — correctness: `--cpu-only` skipping single-core Cinebench, missing
    `|| true` guards under pipefail, INT/TERM traps not exiting, `OMLX_PORT`
    never passed to the server, sudo-owned `results/`, and JSON string-vs-number
    field types.
  - **P2/P3** — latent bugs and dedupe: wired macOS custom reminders,
    `handled_by_setup`/`install_command` schema validation, hdiutil reuse
    handling, dry-run fidelity, and shared helpers (`bench_init`, `SUITE_VERSION`,
    `mac_install_list`, openssl-speed helper).

## 2026-06-24 — Per-platform package tags ([#52](https://github.com/ulises-c/Computer-Setup/pull/52))

### Added
- Per-platform object forms for `priority`, `optional`, `environment`, and
  `install_command` in `packages.json` (resolved by `prfor`/`optfor`/`envfor`/
  `icfor` in `lib/core.sh`), so one entry can serve platforms that differ in tier
  or gating instead of splitting into duplicates.
- Required `tags` field with a controlled vocabulary enforced by
  `scripts/validate-packages.sh`, and category-based install selection via
  `--base` / `--tags <csv>` (with an interactive prompt on a bare TTY run).
- Tailscale / claude-code / docker custom steps now gate on `pkg_selected` so
  they honor the same selection (server profile keeps the filter inactive).

## 2026-06-21 — Nightly server backups

### Added
- `linux-server/backup/`: nightly restic backup of all persistent server state
  (Forgejo repos+LFS+DB, SQLite app DBs via online `.backup`, Portainer BoltDB,
  certs/configs, every `.env`) to a dedicated 1TB drive, encrypted/deduplicated/
  pruned, with ntfy alerts, a homepage status card, and a restore runbook.
  systemd timer at 03:30 (Persistent) with an OnFailure alert; `ts-state/`
  deliberately excluded.

## 2026-06-17 — Per-service HTTPS over Tailscale, server

### Added
- Every self-hosted service moved from `http://<server-ip>:<port>` to its own
  `https://<svc>.<tailnet>.ts.net/` via a Tailscale HTTPS sidecar, with the
  pattern and rollout table documented in `linux-server/HTTPS.md`. Forgejo is the
  reference implementation; converted: portainer, uptime-kuma, speedtest-tracker,
  ntfy, filebrowser, syncthing, glances, adguard, atvloadly (migrated into the
  repo), homepage, cockpit, tailscale-web, and watchtower (metrics-only API).
- Homepage links/widget URLs updated per service; NPM kept as the non-tailnet
  HTTPS edge (host :80/:443) with its admin UI also behind a sidecar. Auth via an
  OAuth client + `tag:container`.

## 2026-06-14 — Setup-script unification ([#37](https://github.com/ulises-c/Computer-Setup/pull/37))

Collapsed the three diverged setup stacks (`macOS/`, `linux-desktop/`,
`linux-server/`) into one root `setup.sh` + one `packages.json`. Full design and
phased breakdown in [UNIFICATION.md](docs/UNIFICATION.md).

### Added
- Root `setup.sh` / `verify.sh` dispatchers, a shared `lib/core.sh` engine and
  `lib/verify.sh` check engine, and `platforms/{macos,arch,ubuntu,server}.sh` for
  per-platform quirks.
- Single root `packages.json` as the source of truth (managers keyed by
  `{macos,ubuntu,arch,server}`; per-platform `<platform>_name` overrides; `custom`
  managers with string or per-platform `install_command`).
- `scripts/dryrun-smoke.sh` (root dry-run across all four platforms, run in CI).
- `dotfiles/` consolidation (Phase 7): shared `tmux.conf`, `ghostty.config`,
  `zshrc.example`, `zsh_plugins.txt`, `p10k.zsh.example` moved out of per-folder
  copies; the cross-platform zshrc guards macOS/desktop/headless bits at runtime;
  macOS gained the previously missing tmux deploy.
- `zsh-theme-powerlevel10k` + `lact` ported into the unified stack, `~/.p10k.zsh`
  deploy (Phase 6, folding in [#28](https://github.com/ulises-c/Computer-Setup/pull/28)
  p10k/LACT, [#35](https://github.com/ulises-c/Computer-Setup/pull/35) railguard,
  [#38](https://github.com/ulises-c/Computer-Setup/pull/38) claude-hud).

### Changed
- Per-folder `setup.sh` / `verify.sh` reduced to thin shims that exec the root
  entrypoints (byte-identical output).
- macOS migrated from `work: true` booleans and flat string managers to
  `environment` arrays and platform-keyed manager objects.
- Resolved the design's open questions: server is a platform key (option A),
  `install_command` accepts both string and per-platform object, and the
  `priority: "none"` reminder tier is kept.

### Removed
- The three legacy per-folder package JSONs and the temporary parity harnesses
  (`parity-check.sh`, `dryrun-parity.sh`, `verify-parity.sh`) once dry-run parity
  was proven and the smoke test took their place.

### Fixed
- Ubuntu now prints manual-install reminders for `git-xet` / `claude-desktop`
  instead of silently skipping them (the legacy gap); custom-package reminders
  generalized into `lib/core.sh`.
- The powerlevel10k theme is an antidote plugin on all desktops (the previous
  yay-only entry meant Ubuntu/macOS silently fell back to `vcs_info`).

## 2026-05-28 — CachyOS / Arch desktop support ([#18](https://github.com/ulises-c/Computer-Setup/pull/18))

### Added
- Arch/CachyOS detection in `setup.sh` (via `/etc/os-release`), `yay` bootstrap
  through pacman, and repo+AUR installs driven through `yay`.
- Personal-only packages (discord, spotify, steam, bolt-launcher, notion) and a
  `verify.sh` mirroring the setup selection + runtime checks.

### Changed
- `arch_name` overrides verified against real AUR/pacman packages (e.g.
  `huggingface-hub` → `python-huggingface-hub`); pyenv/nvm switched to the curl
  installers for a unified `~/.pyenv` / `~/.nvm` across platforms.
- Login-shell switch reads the real shell via `getent` and switches fish → zsh;
  existing `~/.zshrc` is backed up before replacement.

### Fixed
- pyenv init no longer aborts setup under `set -e`; hardened `yay` batch installs
  to skip already-satisfied build deps.
