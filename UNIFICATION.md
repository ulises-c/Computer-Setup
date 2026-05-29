# Setup-script unification plan

Status: **planned — not yet implemented.** This document is the spec for a future
PR. It is intentionally detailed so it can be picked up cold without re-deriving the
analysis below.

## Goal

Collapse the three diverged setup stacks (`macOS/`, `linux-desktop/`,
`linux-server/`) into **one main `setup.sh` at the repo root** backed by **one
`packages.json`**, with platform-specific quirks isolated in small modules under
subfolders. Per-folder configs (zshrc, ghostty.config, etc.) stay where they are;
only the *install/orchestration logic and package data* get unified.

### Locked decisions (agreed before this plan was written)

1. **Single `packages.json`** at the repo root. `package_manager` becomes an object
   keyed by platform: `{macos, ubuntu, arch, server}`. Entries omit keys for
   platforms they don't apply to.
2. **Root `setup.sh` + platform modules.** `setup.sh` detects the platform, sources a
   shared core (`lib/core.sh`) and a platform module (`platforms/<platform>.sh`) for
   bootstrap quirks. Per-folder `setup.sh` scripts become thin shims (or are removed).
3. **Incremental migration**, verifying each phase (dry-run parity gates) before the
   next.

## Current state (the problem)

Three scripts that do the same job with three different schemas:

| Aspect | `macOS/setup.sh` (323 ln) | `linux-desktop/setup.sh` (644 ln) | `linux-server/setup.sh` (346 ln) |
|---|---|---|---|
| `package_manager` | flat string | **object keyed by distro** (`ubuntu`/`arch`) | flat string |
| Env targeting | `work: true` boolean | `environment: ["work","personal"]` tag array | none |
| Name overrides | none | `ubuntu_name` / `arch_name` (`// .name` fallback) | none |
| Custom installs | `curl` + `custom` w/ `install_command` | `custom` w/ `install_command` | `custom` w/ `install_command` + `handled_by_setup` |
| Output style | `printf` | `echo` | `echo` |
| Flags | `--optional --work --dry-run` | `--optional --work --personal --dry-run --distro` | `--optional --dry-run` |
| Related-scripts footer | yes (mirrored from linux-desktop) | yes (`RELATED_SCRIPTS` array) | no |
| Package count | 59 | 61 | 31 |

`linux-desktop/setup.sh` is the most evolved and is the **superset model** everything
else migrates onto (`env_filter()`, distro-keyed managers, `<distro>_name` overrides,
`RELATED_SCRIPTS`).

### Manager inventory (current, per platform)

- macOS: `brew`, `brew-cask`, `app-store`, `curl`, `npm`, `pipx`
- linux-desktop: `apt`, `yay`, `snap`, `curl`, `custom`, `npm`, `pipx`
- linux-server: `apt`, `custom`

### Field inventory (current)

- macOS: `name`, `package_manager`, `priority`, `optional`, `description`, `install_command`, `work`
- linux-desktop: `name`, `package_manager`, `priority`, `optional`, `description`, `install_command`, `environment`, `ubuntu_name`, `arch_name`
- linux-server: `name`, `package_manager`, `priority`, `optional`, `description`, `install_command`, `handled_by_setup`

## Target architecture

```
setup.sh                       # root dispatcher: detect platform → source core + module → run
packages.json                  # unified package data (single source of truth)
verify.sh                      # root dispatcher for the read-only health check
lib/
  core.sh                      # shared engine (see below)
platforms/
  macos.sh                     # Homebrew bootstrap; brew / brew-cask / app-store handling; mac quirks
  arch.sh                      # yay bootstrap (via pacman); fish→zsh login-shell switch
  ubuntu.sh                    # apt update; snap handling
  server.sh                    # apt; no-GUI profile; SSH hardening / tailscale / docker steps
macOS/  linux-desktop/  linux-server/
                               # configs stay (zshrc, ghostty.config, zsh_plugins.txt, homepage/, …)
                               # each folder's setup.sh/verify.sh become thin shims that exec the root
                               # script with the right platform/profile, preserving documented usage
```

### `lib/core.sh` responsibilities (platform-agnostic)

- Arg parsing → flags: `--optional --work --personal --dry-run --distro <x> --profile <server|desktop>`.
- `run` / `run_eval` dry-run wrappers (unify `printf` vs `echo` on one style — pick `printf`).
- Platform detection (see below); sets `PLATFORM` ∈ {macos, ubuntu, arch, server}.
- `env_filter()` — the linux-desktop logic: packages with no `environment` always
  install; `work`/`personal`-tagged ones gate on `--work`/`--personal`.
- `pkg_names(manager, priority)` — jq query honoring `package_manager[$PLATFORM]`,
  `<platform>_name // .name`, env filter, priority.
- `custom_installs(priority)` — run `install_command[$PLATFORM]` (or string form) for
  `custom` packages; respect `handled_by_setup` (auto-run vs print-as-reminder).
- Install loops by priority tier (high → medium → low/optional).
- Shared post-install configure steps: pyenv (`~/.pyenv`), nvm (`~/.nvm`), Ghostty
  config deploy, `.zshrc` deploy, GPG signing hookup.
- `print_related_scripts()` from a `RELATED_SCRIPTS` array (already exists in both
  desktop scripts).
- App-store reminders (macOS only; no-op elsewhere).

### `platforms/<platform>.sh` responsibilities (quirks only)

- **macos.sh**: install Homebrew if missing; `expat` before pyenv (Tahoe build fix);
  `brew install` / `brew install --cask`; App Store reminder printing; Spark Mail via
  App Store (not brew).
- **arch.sh**: bootstrap `yay` via `pacman`; skip already-satisfied pyenv build deps;
  fish→zsh login-shell switch via `getent`; harden `yay` batch install (lessons already
  encoded in current `linux-desktop/setup.sh` — port verbatim).
- **ubuntu.sh**: `sudo apt update`; `apt install -y`; `snap install`.
- **server.sh**: apt only; exclude GUI/desktop packages; SSH hardening, Tailscale,
  Docker, homepage dashboard (see `linux-server/` TODO).

## Unified `packages.json` schema

One array of package objects. Field-by-field:

```jsonc
{
  "name": "zsh",                       // canonical name; default install token
  "package_manager": {                 // object keyed by platform; omit platforms N/A
    "macos":  "brew",
    "ubuntu": "apt",
    "arch":   "yay",
    "server": "apt"
  },
  "macos_name":  "…",                  // optional per-platform install-token override
  "ubuntu_name": "…",                  //   (core reads  .<platform>_name // .name)
  "arch_name":   "…",
  "server_name": "…",
  "priority": "high",                  // high | medium | low | none
  "optional": false,                   // low/none + optional → only with --optional
  "environment": ["work", "personal"], // optional; absent ⇒ always installs
  "install_command": {                 // only for manager == "custom"; per-platform
    "macos":  "curl … | bash",
    "ubuntu": "…"
  },
  "handled_by_setup": true,            // custom pkg: auto-run (true) vs print reminder (false)
  "description": "…"
}
```

### Migration rules (old → unified)

1. **`package_manager` string → object.** Wrap each platform's current flat value
   under its platform key. macOS `brew`→`{macos:"brew"}`, server `apt`→`{server:"apt"}`,
   etc. Merge duplicate logical packages across files into one entry with multiple keys.
2. **`work: true` → `environment: ["work"]`.** (macOS only uses `work`; the array form
   from linux-desktop wins.)
3. **Fold `curl` manager into `custom`.** macOS's `curl` entries (nvm) are just custom
   installs with an `install_command`; standardize on `custom`.
4. **`install_command` string → object keyed by platform** (parallel to
   `package_manager`). Core should accept either a bare string (applies to every
   platform whose manager is `custom`) or the object form. nvm's curl command is
   cross-platform identical; macOS `mongodb-community` brew-tap command is macOS-only.
5. **Preserve `<platform>_name` overrides** already present for ubuntu/arch (e.g.
   `huggingface-hub` → arch `python-huggingface-hub`). Add `macos_name`/`server_name`
   only where the install token differs from `name`.
6. **Keep `priority` / `optional` / `description` verbatim.** Reconcile descriptions
   when merging duplicates (prefer the most informative; note platform caveats inline).
7. **App-store** stays a macOS-only `package_manager.macos: "app-store"` → printed as a
   manual reminder, never auto-installed.

### "server" modeling — OPEN DECISION (resolve in implementation PR)

The chosen schema lists `server` as a 4th `package_manager` key, but the Pi is
Debian/apt — same manager as `ubuntu`. Two viable models:

- **(A) Server as a platform key** (as the locked schema implies): explicit
  `server: "apt"`; duplicates ubuntu's apt token for shared packages but is unambiguous.
- **(B) Server as a *profile* over the debian/apt platform**: platform stays the
  manager dimension (macos/debian/arch); "desktop vs server" is a `--profile`
  dimension that filters out GUI packages and adds server-only steps. Less duplication.

Recommendation: start with **(A)** to honor the locked schema and keep the engine
simple; revisit (B) only if the duplication becomes painful. Either way, GUI/desktop
packages must be excluded on server — model that with an `environment`/profile tag
(e.g. `environment: ["desktop"]` excluded unless `--profile desktop`).

## Platform detection

```
macos   → uname -s == Darwin
linux   → /etc/os-release: ID/ID_LIKE → ubuntu (debian-like) | arch (arch-like)
server  → explicit --profile server (and/or --server); NOT auto-distinguished from
          ubuntu by distro alone since both are apt-based
```

Reuse the existing `detect_distro()` from `linux-desktop/setup.sh` (handles
ubuntu/debian/mint/pop and arch/cachyos/manjaro/endeavouros/garuda/arcolinux, with
`--distro` override) and extend it with the macOS branch + server profile.

## Phased work breakdown

Each phase is independently committable and gated by a verification step. Phases 1–5
are the future PR(s); Phase 0 is this document.

- **Phase 0 — Plan (this PR).** Add `UNIFICATION.md` + TODO items. No behavior change.

- **Phase 1 — Unified data + parity harness.**
  - Author root `packages.json` by merging the three files per the migration rules.
  - Write `scripts/parity-check.sh`: for every `(platform × priority × flag-combo)`,
    compute the install list from the **new** `packages.json` (via the planned core
    jq) and diff it against the list the **current** per-folder script computes from
    its **old** JSON. **Acceptance: zero diffs** (modulo intentional, documented
    changes like curl→custom folding).
  - Keep old scripts/JSONs untouched in this phase; the new JSON is validated in
    isolation first.

- **Phase 2 — Engine extraction + root dispatcher.**
  - Build `lib/core.sh` and `platforms/{macos,arch,ubuntu,server}.sh` by lifting logic
    from `linux-desktop/setup.sh` (the superset) and grafting macOS/server quirks.
  - Add root `setup.sh` that detects platform → sources core + module → runs.
  - **Acceptance:** `setup.sh --dry-run [flags]` output matches the corresponding old
    `<folder>/setup.sh --dry-run [flags]` for every platform and flag combination
    (cosmetic differences allowed; install/eval lines must match).

- **Phase 3 — verify.sh unification.**
  - Same treatment for `macOS/verify.sh` (183 ln) and `linux-desktop/verify.sh`
    (249 ln): shared `verify` core + platform checks; root `verify.sh` dispatcher.
  - **Acceptance:** root `verify.sh` reproduces each platform's current check counts
    (e.g. linux-desktop's 52/52).

- **Phase 4 — Shims + docs.**
  - Convert `macOS/setup.sh`, `linux-desktop/setup.sh`, `linux-server/setup.sh` (and
    the verify scripts) into thin shims that `exec` the root script with the right
    platform/profile, so existing READMEs/muscle-memory keep working.
  - Update `README.md` and `CLAUDE.md` to document the root entrypoint.

- **Phase 5 — Cleanup.**
  - Once parity is proven and shims are in place, delete the three old per-folder JSONs
    (their data now lives in root `packages.json`). Keep configs (zshrc, ghostty, etc.).

## Verification strategy

- **Dry-run parity is the primary gate.** This environment can only execute the Arch
  path live (CachyOS); brew/apt/snap aren't available here. `--dry-run` prints commands
  without executing, so parity can be checked on every platform regardless of host.
- Run `shellcheck` on all new scripts; preserve the `# shellcheck disable=SC2086`
  directives where unquoted `$names` word-splitting is intentional (already in the
  scripts today).
- Re-run `linux-desktop/verify.sh --work` on real CachyOS after Phase 2/3 to confirm no
  regression in the one path that can be fully exercised here.

## Risks & gotchas to carry forward

- **Can't run macOS/Ubuntu/server natively here** → lean entirely on dry-run parity +
  shellcheck; do not claim live verification for those platforms.
- **`set -e` + pyenv init** aborts setup — already fixed in `linux-desktop/setup.sh`
  (commit 3b946c4); port the guard, don't reintroduce the bug.
- **pyenv build deps on Arch** must skip already-satisfied packages (commit 303f803).
- **macOS schema change is the biggest data risk**: `work:true`→`environment` and
  string→object managers touch all 59 macOS entries. The parity harness exists
  specifically to catch mistakes here.
- **App-store packages are reminders only** — must never end up in an auto-install list.
- **Spark Mail** installs via App Store, not brew (commit 48d03ac) — preserve.

## Open questions (decide during implementation)

1. server-as-platform vs server-as-profile (see above) — recommend platform key (A).
2. `install_command` string vs per-platform object — support **both** (string = all
   custom platforms; object = per-platform).
3. Keep the `priority: "none"` tier, or fold into `low + optional`? (Currently macOS
   uses `none` for octave/qemu/mongodb/Pixelmator/Amphetamine.)
4. Single root `packages.json` vs `packages/` split by domain if the file grows
   unwieldy (>150 entries). Start single; revisit only if needed.
