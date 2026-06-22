# Computer-Setup

Personal machine-provisioning repo: one unified installer for macOS, Linux
desktop (Ubuntu/Arch), and an Ubuntu Server LTS home server, plus per-platform
configs and docs. (A Raspberry Pi — Debian proper — is a future target,
tracked in TODO.md.)

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
- `dotfiles/` — configs shared across platforms (`tmux.conf`,
  `ghostty.config`, `zshrc.example`, `zsh_plugins.txt`); the engine deploys
  them from here. The zshrc base is cross-platform — macOS-specific bits are
  guarded on `/opt/homebrew` or `$OSTYPE` — and has an override system
  (`deploy_zshrc`): a platform folder shipping its own `zshrc.example` wins
  over the dotfiles base. Only `linux-server/` does (headless: no
  Ghostty/fastfetch/notification hooks).
- `macOS/`, `linux-desktop/`, `linux-server/` — platform-specific configs
  (server zshrc override, p10k), docs, and thin shim scripts that exec the
  root entrypoints.
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

## Privacy & Security

This repo is **public**. Never commit identifying or secret information.

- Keep these out of tracked files entirely: tailnet names / MagicDNS suffixes
  (`tailXXXXXX.ts.net`), real hostnames, server IPs, usernames, emails, tokens,
  auth keys, and personal absolute paths.
- Put any machine-specific or private value in a `.env` file (gitignored
  repo-wide) and ship a committed `.env.example` with placeholders instead —
  e.g. `linux-server/forgejo/.env.example`, `macOS/forgejo-runner/.env.example`.
  Scripts read these via `${VAR:-<placeholder>}` and source a local `.env` when
  present; they never hardcode the real value.
- In docs and configs use placeholders: `<tailnet>`, `<server-ip>`,
  `<username>`, `<hostname>`. Default to `.env` whenever a value is
  identifying — prefer one more env var over leaking a real value.
- When editing, scan the diff for accidentally introduced real identifiers
  before committing.
