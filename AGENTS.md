# Computer-Setup

Personal machine-provisioning repo: one unified installer for macOS, Linux
desktop (Ubuntu/Arch), and an Ubuntu Server LTS home server, plus per-platform
configs and docs. A Raspberry Pi (`<pi-hostname>`, Debian) node lives in `linux-pi/`
— currently its own Docker Compose service stacks (a secondary AdGuard resolver);
folding it into the `setup.sh` base provisioning is still tracked in docs/TODO.md.

This file is the shared instruction set for **every** coding agent working in
this repo (Claude Code, opencode, Codex, …). `CLAUDE.md` imports it and adds
Claude-Code-only notes on top; keep cross-agent guidance here, not there.

## Entrypoints

- `setup.sh` — installs everything for the detected platform.
  Flags: `--optional --work --personal --base --tags <csv> --dotfiles --dry-run --platform <macos|ubuntu|arch|server> --profile <desktop|server>`.
  The server platform is never auto-detected (`--profile server` or `--platform server` required).
  `--base` installs only the high-priority base set; `--tags development,terminal`
  installs base + those `packages.json` tag categories; a bare TTY run with no
  selection flag prompts interactively except on the server profile. Selection
  mechanics and the custom-step gating: `docs/PACKAGES.md`.
  `--dotfiles` deploys only the shared dotfiles set and installs no packages — it
  short-circuits in `setup.sh` before tag validation and the interactive prompt,
  so it ignores every selection flag. `deploy_dotfiles()` in `lib/core.sh` is the
  single owner of that set and is what both `platform_main`s call.
- `verify.sh` — read-only health check mirroring `setup.sh`'s selection logic.
  Flags: `--optional --work --personal --all --platform <macos|ubuntu|arch|server>`
  (no `--dry-run`). The server profile additionally checks NUT configuration and
  services. Unknown flags warn and are ignored, they don't abort.

## Architecture

- `packages.json` — single source of truth for all package data. Managers are keyed
  by platform (`{macos, ubuntu, arch, server}`); `<platform>_name` overrides the
  install token; `environment` gates on `--work`/`--personal`; `custom` managers
  carry an `install_command` (auto-run when `handled_by_setup`, else a reminder);
  `tags` is a required category array. The tier/gating fields `priority`, `optional`,
  `environment`, and `install_command` can be a scalar or a per-platform object.
  **Full schema, per-platform resolution, the `environment` caveat, and the tag
  filter live in `docs/PACKAGES.md` — read it before editing `packages.json`.**
- `lib/core.sh` — shared engine: arg parsing, platform detection, env filter,
  jq selection, install loops, config deploys. `lib/verify.sh` — check engine.
- `platforms/<platform>.sh` — per-platform quirks only (bootstrap, manager
  invocations).
- `dotfiles/` — configs shared across platforms (`tmux.conf`,
  `ghostty.config`, `zshrc.example`, `zsh_plugins.txt`); the engine deploys
  them from here. One zshrc base serves every platform including the headless
  server — macOS-specific bits guard on `/opt/homebrew` or `$OSTYPE`, and the
  desktop-only bits self-disable headless (notify hook no-ops without
  `$DISPLAY`/`$WAYLAND_DISPLAY`, fastfetch keys off Ghostty or `$SSH_CONNECTION`,
  version managers/zoxide are command-guarded). The override system
  (`deploy_zshrc`) still lets a platform folder ship its own `zshrc.example` to
  win over the base, but no platform currently does.
- `macOS/`, `linux-desktop/`, `linux-server/` — platform-specific configs,
  docs, and thin shim scripts that exec the root entrypoints. `linux-pi/` holds
  the Raspberry Pi node's Docker Compose service stacks (same
  `<service>/{docker-compose.yml,.env.example,ts-serve.json}` layout as
  `linux-server/`), not yet wired into `setup.sh`.
- `scripts/dryrun-smoke.sh` — runs `setup.sh --dry-run` for every platform and
  asserts it exits clean with install actions; also run in CI.

`docs/UNIFICATION.md` is the design doc for this layout; `docs/CHANGELOG.md` records
what shipped and `docs/TODO.md` tracks remaining work.

## Conventions

- Pre-commit runs `shellcheck --severity=warning` on all shell scripts;
  `zsh -n` checks `.zsh` files and `zshrc.example`; `scripts/validate-packages.sh`
  enforces the `packages.json` schema (platform vocabulary, controlled tag set,
  and the "no silent drop" rule — every platform a package targets must resolve a
  valid priority tier and a boolean optional). All three also run in CI.
- Probe semantics in `lib/verify.sh` are platform-faithful ports — macOS has no
  `command -v` fallback for casks/pipx/app-store, Linux falls back everywhere.
  Don't "fix" the asymmetry without checking `docs/UNIFICATION.md` history.
- `--dry-run` must print every command without executing anything. Before committing
  changes to `setup.sh`, `lib/`, `platforms/`, or `packages.json`, exercise it across
  all four platforms; only one platform can run live.
- Before committing changes to `.env` handling, `custom` `install_command` shell
  execution, or path/network code, perform a security review.
- App-store packages and `priority: "none"` entries are reminders only — never
  auto-installed.

## Coding conventions

These apply to every agent (the repo is almost entirely Bash).

- **Comments:** none by default. Add one only when the *why* is non-obvious — a
  hidden constraint, a bug workaround, a subtle invariant. Never narrate *what*
  the code does; well-named identifiers cover that.
- **No speculative design.** Don't build for hypothetical future requirements;
  three similar lines beat a premature abstraction. Don't add features, refactors,
  or abstractions beyond what the task needs.
- **Validate only at boundaries** (user input, external APIs). Trust internal code
  and framework guarantees — no error handling or fallbacks for cases that can't
  happen.
- **Prefer editing existing files** to creating new ones; delete removed code
  cleanly rather than leaving back-compat shims.
- **Bash style:**
  - `#!/usr/bin/env bash` shebang; `set -euo pipefail` at the top of every
    non-trivial script.
  - `[[ ]]` not `[ ]`; quote all expansions (`"$var"`, `"${arr[@]}"`).
  - `printf` not `echo`; declare function-local vars with `local`; write errors to
    stderr (`printf 'error: %s\n' "$msg" >&2`).
  - `command -v foo` over `which foo`; herestring (`<<< "$var"`) over `echo "$var" |`.

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
