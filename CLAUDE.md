# Computer-Setup

Personal machine-provisioning repo: one unified installer for macOS, Linux
desktop (Ubuntu/Arch), and an Ubuntu Server LTS home server, plus per-platform
configs and docs. (A Raspberry Pi — Debian proper — is a future target,
tracked in TODO.md.)

## Entrypoints

- `setup.sh` — installs everything for the detected platform.
  Flags: `--optional --work --personal --base --tags <csv> --dry-run --platform <macos|ubuntu|arch|server> --profile <desktop|server>`.
  The server platform is never auto-detected (`--profile server` or `--platform server` required).
  Category selection: `--base` installs only the high-priority base set; `--tags
  development,terminal` installs base + those `packages.json` tag categories
  (enabled work/personal apps install regardless of category). Run bare on a TTY
  with no selection flag and `core_maybe_prompt_selection` prompts interactively;
  it is skipped on the server profile and in non-interactive/CI runs. The filter
  is implemented by `tagok()` in `CORE_JQ_DEFS`, which reads `TAG_FILTER_ACTIVE`
  and `SELECTED_TAGS` from the environment — inactive by default, so flag-driven
  and CI runs are unchanged.
- `verify.sh` — read-only health check mirroring `setup.sh`'s selection logic.
  Flags: `--optional --work --personal --all --platform <macos|ubuntu|arch>`
  (no `--dry-run`; `--platform server`/`--profile server` is rejected — nothing
  legacy existed to port). Unknown flags warn and are ignored, they don't abort.

## Architecture

- `packages.json` — single source of truth for all package data. Managers are
  keyed by platform (`{macos, ubuntu, arch, server}`); `<platform>_name`
  overrides the install token; `environment` gates on `--work`/`--personal`;
  `custom` managers carry `install_command` (string or per-platform object) —
  run by the engine when `handled_by_setup` is true, otherwise printed as a
  manual-install reminder.
  - `priority`, `optional`, `environment`, and `install_command` each accept a
    **scalar** (applies to every platform) **or a per-platform object** keyed by
    platform (e.g. `"priority": { "macos": "medium", "ubuntu": "none" }`). The
    engine resolves them via the `prfor`/`optfor`/`envfor`/`icfor` jq defs in
    `lib/core.sh`. This is what lets one entry serve platforms that differ in
    tier/optionality/gating, instead of splitting into duplicate entries.
  - **`environment` caveat:** its scalar form is itself an *array* (`["work"]`),
    so the per-platform form is detected as an *object* (`{ "ubuntu": ["work"] }`)
    — array means legacy/all-platforms, object means per-platform. Keep the
    per-platform value an object-of-arrays.
  - `tags` — required non-empty array of descriptive categories from the
    controlled vocabulary in `scripts/validate-packages.sh`. Metadata only
    (grouping/docs); the install engine ignores them.
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
  docs, and thin shim scripts that exec the root entrypoints.
- `scripts/dryrun-smoke.sh` — runs `setup.sh --dry-run` for every platform and
  asserts it exits clean with install actions; also run in CI.

`UNIFICATION.md` is the design doc for this layout; `TODO.md` tracks remaining
phases.

## Conventions

- Pre-commit runs `shellcheck --severity=warning` on all shell scripts;
  `zsh -n` checks `.zsh` files and `zshrc.example`; `scripts/validate-packages.sh`
  enforces the `packages.json` schema (platform vocabulary, controlled tag set,
  and the "no silent drop" rule — every platform a package targets must resolve a
  valid priority tier and a boolean optional). All three also run in CI.
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
