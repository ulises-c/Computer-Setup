# Computer-Setup

Personal machine-provisioning repo: one unified installer for macOS, Linux
desktop (Ubuntu/Arch), and a Debian-based home server, plus per-platform
configs and docs.

## Entrypoints

- `setup.sh` — installs everything for the detected platform.
  Flags: `--optional --work --personal --dry-run --platform <macos|ubuntu|arch|server> --profile <desktop|server>`.
  The server platform is never auto-detected (`--profile server` or `--platform server` required).
- `verify.sh` — read-only health check mirroring `setup.sh`'s selection logic.
  Flags: `--optional --work --personal --all --platform <macos|ubuntu|arch>`
  (no `--dry-run`; `--platform server`/`--profile server` is rejected — nothing
  legacy existed to port). Unknown flags warn and are ignored, they don't abort.

## Architecture

- `packages.json` — single source of truth for all package data. Managers are
  keyed by platform (`{macos, ubuntu, arch, server}`); `<platform>_name`
  overrides the install token; `environment` tags gate on `--work`/`--personal`;
  `custom` managers carry `install_command` (string or per-platform object) —
  run by the engine when `handled_by_setup` is true, otherwise printed as a
  manual-install reminder.
- `lib/core.sh` — shared engine: arg parsing, platform detection, env filter,
  jq selection, install loops, config deploys. `lib/verify.sh` — check engine.
- `platforms/<platform>.sh` — per-platform quirks only (bootstrap, manager
  invocations).
- `macOS/`, `linux-desktop/`, `linux-server/` — configs, docs, and thin shim
  scripts that exec the root entrypoints.
- `scripts/dryrun-smoke.sh` — runs `setup.sh --dry-run` for every platform and
  asserts it exits clean with install actions; also run in CI.

`UNIFICATION.md` is the design doc for this layout; `TODO.md` tracks remaining
phases.

## Conventions

- Pre-commit runs `shellcheck --severity=warning` on all shell scripts;
  `zsh -n` checks `.zsh` files and `zshrc.example`.
- Probe semantics in `lib/verify.sh` are platform-faithful ports — macOS has no
  `command -v` fallback for casks/pipx/app-store, Linux falls back everywhere.
  Don't "fix" the asymmetry without checking `UNIFICATION.md` history.
- `--dry-run` must print every command without executing anything; it is the
  primary cross-platform test mechanism (only one platform can run live).
- App-store packages and `priority: "none"` entries are reminders only — never
  auto-installed.
