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

## macOS benchmark suite — review fixes (feat/packages-macos-benchmarks)

Findings from the 2026-07 max-effort review of this branch (10 finder angles,
per-finding verification, gap sweep). Ordered by severity — fix top-down.
Most failures are silent (`|| true` / `2>/dev/null` degrade to `null` fields),
so after the P0/P1 fixes, re-run every suite end-to-end on one Mac and check
the result JSON has no unexpected nulls before trusting numbers.

### P0 — measurement paths broken, data corruption, or setup aborts

- [x] `macOS/benchmarks/benchmark.sh:56` (also `stress-test.sh:59,91`) —
      `openssl speed -seconds` is not supported by stock macOS LibreSSL, and the
      unguarded `$( )` under `set -e` kills the script silently right after the
      section header. Resolve a `-seconds`-capable openssl at startup (brew
      `openssl@3` is keg-only — probe `$(brew --prefix openssl@3)/bin/openssl`)
      or die with a clear install hint; never let the substitution abort silently
- [x] `macOS/benchmarks/llm-bench.sh:137` — `llama-bench` does not accept
      `--hf-repo` (that flag belongs to llama-cli/llama-server), so the whole
      llama.cpp half fails arg parsing with stderr discarded. Pre-download the
      GGUF and pass `-m <path>`; stop discarding llama-bench stderr
- [x] `macOS/benchmarks/benchmark.sh:250-253` — GPU llama-bench parse always
      null: the `grep -v "^\["` filter strips the JSON array's opening bracket,
      and `jq -s '.[0].avg_ts'` double-wraps the array (and `[0]` would be the
      pp row, not tg). Either parse like llm-bench.sh does
      (`jq '[.[] | select(...)]'`) or drop the GPU section and defer to
      llm-bench.sh — it duplicates that suite with a nondeterministic
      pick-any-gguf heuristic anyway (`benchmark.sh:234`)
- [x] `macOS/benchmarks/standardized.sh:105` — Cinebench detection uses
      `-maxdepth 3` but the binary sits at depth 4
      (`/Applications/Cinebench.app/Contents/MacOS/Cinebench`); Cinebench is
      never detected even after our own installer runs. Use `-maxdepth 4`
- [x] `platforms/macos.sh:72` — one failing custom installer (e.g. the Cinebench
      DMG URL 404s) aborts the entire remaining setup run under `set -e`.
      Collect failures and continue, like `BREW_FAILURES` (#31 pattern)
- [x] `macOS/benchmarks/compare.sh:117` — a metric missing on machine A crashes
      the comparison mid-table: `pct()` yields null when `av == 0`, `@tsv`
      renders null as an empty field, `IFS=$'\t' read` collapses the adjacent
      tabs (tab is IFS whitespace) shifting `winner` into `pct`, and
      `printf '%+.1f%%'` then fails under `set -e`. Emit the literal string
      `"null"` from jq (matching the existing guard) or a placeholder that
      can't collapse
- [x] `macOS/benchmarks/stress-test.sh:91` — throttle methodology is
      self-defeating: baseline is one openssl thread on an idle machine
      (single-core boost, P-core) but each sample contends with NCPU stressors,
      so a healthy Mac reads ~0.5–0.7 and flags THROTTLE. Rework: e.g. take the
      baseline as the first sample *under* load, or track the sample trend
      instead of an idle-vs-loaded ratio
- [x] `macOS/benchmarks/stress-test.sh:105-114` — powermetrics parse patterns
      are Intel-era and never match Apple Silicon output: frequency lines are
      `... HW active frequency: N MHz` (lowercase f) and power is
      `CPU Power: N mW` (not `Package power:`); also convert mW → W. As shipped,
      the whole sudo path is dead weight on every target Mac (all M-series)
- [x] `macOS/benchmarks/benchmark.sh:124` — memory-bandwidth awk `/stream/`
      matches stress-ng's `dispatching hogs: 1 stream` info line before the
      metrics row, printing 0 every run. Anchor on the metrics row
      (e.g. `/metrc.*stream/`)
- [x] `macOS/benchmarks/omlx-bench.sh:159` — `fire_one` converts failed
      requests (curl error, 429/5xx) into `{}`: token totals silently shrink
      while wall time still includes the failure, corrupting aggregate_tps,
      peak_aggregate_tps, and batching_speedup. Count failures per level,
      surface the count in the result JSON, and warn (or fail the level) when
      any request failed
- [x] `macOS/benchmarks/standardized.sh:142` — Blender's benchmark-launcher-cli
      does not auto-download the runtime/scenes; run `blender download <ver>`
      and `scenes download -b <ver>` first (or die with instructions), else
      blender_benchmark is null on every fresh install
- [x] `macOS/benchmarks/standardized.sh:111-118` — single-core Cinebench parse
      greps the combined raw file (multi wrote first, single appended, failures
      `|| true`-swallowed), so a failed single run silently records the
      multi-core score as cpu_single. Use a separate raw file per run
- [x] `macOS/benchmarks/compare.sh:38-75` — no `stress` case: comparing two
      stress results dies `unknown suite: stress` while the README advertises
      it. Add a stress table (or drop the README claim); also fix the header
      comment, which omits the supported `omlx` suite
- [x] `lib/verify.sh:92` + the new cinebench/omlx `packages.json` entries —
      the macOS custom probe only tries `brew list --formula` / `command -v`,
      so GUI-only .app installs can never verify. Add an app-store-style
      `[[ -d /Applications/<App>.app ]]` probe for custom entries (opt-in via
      a field, or probe the app name)
- [x] `macOS/benchmarks/README.md:85` — the compare example embeds two real
      machine short-hostnames in this public repo (privacy rule: placeholders
      only) and uses a `results/` path that doesn't resolve from the repo root
      the other commands assume. Use `<hostname-a>`/`<hostname-b>` placeholders
      and the `macOS/benchmarks/results/` path

### P1 — moderate correctness

- [x] `macOS/benchmarks/standardized.sh:116` — `--cpu-only` must not skip the
      single-core Cinebench run: it is a CPU test; only Blender/GPU belongs
      behind that flag
- [x] `macOS/benchmarks/llm-bench.sh:99-101` — the PP/TG/MEM parse pipelines
      have no `|| true`; under pipefail a non-matching grep kills the run
      (empirically confirmed) instead of reaching the intended
      `[[ -z ... ]] && ...=null` fallbacks
- [x] `macOS/benchmarks/stress-test.sh:39` / `omlx-bench.sh:74` — INT/TERM
      traps don't `exit`; a plain `kill` mid-run stops the load but the sample
      loop continues on an idle machine and writes a bogus `throttled:false`
      result (empirically confirmed). End the handlers with `exit`
- [x] `macOS/benchmarks/omlx-bench.sh:100` — `OMLX_PORT` builds BASE_URL but is
      never passed to `omlx serve`, so overriding the port polls an address the
      spawned server never binds. Pass the port flag (or reject the override)
- [x] `macOS/benchmarks/stress-test.sh` + README `sudo` instructions — a first
      run under sudo creates root-owned `results/`; later non-sudo suites
      finish their full run then die at the final `> "$OUTFILE"`. Create/chown
      results as `$SUDO_USER` when running under sudo
- [x] `macOS/benchmarks/compare.sh:113,131` — a metric present on only one
      machine renders as 0-vs-real and counts as a win, skewing the summary;
      skip or mark rows where either side is missing
- [x] `macOS/benchmarks/compare.sh:61` — standardized.sh never emits
      `.geekbench_ai.score` (only result_url/mode/note), so the row is dead;
      parse a score or drop the row
- [x] `macOS/benchmarks/benchmark.sh:107` — `scaling_factor` is passed with
      `--arg`, landing as a JSON string (or the literal string `"null"`); use
      `--argjson`/`tonumber` like the `$gbs` field already does

### P2 — minor / latent

- [ ] `platforms/macos.sh:68` — macOS never calls `custom_reminders_section`,
      so any future custom entry without `handled_by_setup: true` is silently
      dropped (install branch filters it out, nothing surfaces it). Wire the
      reminder section into `platform_main` like linux_main
- [ ] `scripts/validate-packages.sh` — validate `handled_by_setup` is a real
      boolean and custom entries carry an `install_command` (a string `"true"`
      or missing command currently passes validation and degrades silently)
- [ ] `macOS/lib-dmg-install.sh:30` — handle hdiutil's already-attached reuse
      (image mounted via Finder → `-mountpoint` ignored, empty mount dir,
      misleading `no .app found` death, pre-existing mount left attached)
- [ ] `platforms/macos.sh` dry-run fidelity — gate the pipx `[i/N]` progress
      line on DRY_RUN (:86), print a `[dry-run] sudo -v` line in
      `mac_prime_sudo` (:96), include `--adopt` in the cask progress/FAIL
      lines (:50, :56)
- [ ] `platforms/macos.sh:99` — sudo keepalive inherits `set -e` (one failed
      `sudo -n true` silently kills it) and holds stdout so a piped run hangs
      up to 60s after exit; add `|| true` and redirect stdout
- [ ] `macOS/benchmarks/standardized.sh:59` — grep the already-captured
      `$GB_RAW` for the Geekbench result URL before re-running the whole CPU
      benchmark (the fallback also truncates the first run's output)
- [ ] `macOS/benchmarks/omlx-bench.sh:127` — when `OMLX_MODEL` is set, don't
      die on an empty `/v1/models` list (lazy-loading servers list nothing
      until the first request)

### P3 — cleanup (dedupe within the new code)

- [ ] `macOS/benchmarks/lib.sh` — add a `bench_init <suite>` helper for the
      SYSINFO/HOSTNAME_SHORT/OUTFILE/banner prologue (now copy-pasted ×5) and
      a single `SUITE_VERSION` constant (literal `"1.0.0"` now ×5)
- [ ] `macOS/benchmarks/lib.sh` — extract the openssl-speed sha256 run+parse
      into one helper (now ×4 across benchmark.sh / stress-test.sh); pairs
      with the P0 LibreSSL fix
- [ ] `platforms/macos.sh` — factor the `[i/N]` progress-counter plumbing
      shared by the brew/cask/pipx tiers (now ×3)
- [ ] `macOS/lib-dmg-install.sh` — move the curl/hdiutil dep checks, the
      already-installed guard, and the success message into the lib; drop its
      duplicate `info`/`die` (identical copies in `benchmarks/lib.sh`)
- [ ] `platforms/macos.sh:285` — drive the codeburn menubar reminder from
      `packages.json` instead of a hardcoded package-name check in
      `platform_main`
- [ ] `macOS/install-cinebench.sh:12` — make `DMG_URL` env-overridable; it pins
      a versioned filename while the comment claims a rolling stable URL

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
- [x] filebrowser — sidecar live at https://filebrowser.<tailnet>.ts.net/,
      homepage link updated
- [x] syncthing — sidecar live at https://syncthing.<tailnet>.ts.net/, homepage
      link & widget url updated; sync `:22000`/`:21027` confirmed published
      on the sidecar
- [x] glances — sidecar live at https://glances.<tailnet>.ts.net/ (proxies via
      `host.docker.internal`, glances untouched), homepage link updated
- [x] adguard — sidecar live at https://adguard.<tailnet>.ts.net/, homepage
      link & widget url updated; DNS `:53` confirmed still resolving on the
      sidecar after recreate
- [x] atvloadly — was never tracked in this repo (lived in an untracked
      `/home/ollie/docker-compose.yml`); migrated into
      `linux-server/atvloadly/`, sidecar live at
      https://atvloadly.<tailnet>.ts.net/, homepage link updated. Apple TV
      discovery (avahi/dbus socket mounts) confirmed unaffected by the netns
      share — no `hostname:` on the app container, that conflicts with
      `network_mode: service:...`
- [x] nginx-proxy-manager — KEPT as the host edge; admin UI sidecar live at
      https://npm.<tailnet>.ts.net/ (proxies host :81 via host.docker.internal,
      no app-side change needed), homepage link updated. NPM keeps binding
      host :80/:443 unchanged
- [x] homepage — sidecar live at https://homepage.<tailnet>.ts.net/, confirmed
      `HOMEPAGE_ALLOWED_HOSTS` includes the new domain and container is
      healthy post-recreate
- [x] cockpit — sidecar live at https://cockpit.<tailnet>.ts.net/, homepage
      link updated. `cockpit.conf.example`'s Origins allow-list turned out
      unnecessary — verified via raw WebSocket upgrade (101 with matching
      Origin, 403 with a foreign one)
- [x] tailscale-web — not in the original rollout; added because the homepage
      Tailscale tile linked plain HTTP. New `linux-server/tailscale-web/`
      sidecar-only stack live at https://tailscale-web.<tailnet>.ts.net/,
      homepage link updated. Host's `tailscale-web.service` unit now runs
      `tailscale web --listen 0.0.0.0:8088 --origin
      https://tailscale-web.<tailnet>.ts.net`; sidecar proxies to
      `host.docker.internal:8088`. Verified 200 with no redirect, real page
      content, confirmed in browser. Don't use port `:5252` — see HTTPS.md
      Gotchas
- [x] watchtower — sidecar live at https://watchtower.<tailnet>.ts.net/v1/metrics
      (no UI, metrics-only API; confirmed 401 unauthenticated / 200 with the
      Bearer token, and the 3am schedule is unaffected). Still need: the
      Uptime Kuma HTTP monitor pointed at it (recipe in HTTPS.md).
- [x] Decide auth method: OAuth client + `tag:container` (reusing the elevated
      tailscale-proxy client) — resolved during the Forgejo rollout, see HTTPS.md
- [x] Decide whether to retire NPM or keep it — KEEP, as the non-tailnet HTTPS
      edge (trusted certs for LAN/public clients like a Plex TV that can't join
      the tailnet). See HTTPS.md → "NPM — trusted HTTPS for non-tailnet clients"
- [ ] Set up the NPM trusted-HTTPS edge (domain `ulises-c.me`, already owned):
      NPM wildcard Let's Encrypt cert for `*.home.ulises-c.me` via DNS-01, AdGuard
      rewrite `*.home.ulises-c.me` → LAN IP, then per-service proxy hosts. Not
      started — documented in HTTPS.md to pick up later.
- [ ] Update Homepage hrefs to HTTPS as each service converts; a service's widget
      `url:` must move to the HTTPS domain too (localhost stops resolving once the
      host port is dropped)

## Server observability & hardening (post-HTTPS rollout) — [#49](https://github.com/ulises-c/Computer-Setup/issues/49)

Improvements identified once every service was wired up with a Tailscale sidecar.

### Watchtower observability — "what updated, and when"

Watchtower has no native history UI, and its `/v1/metrics` endpoint (now monitored
by Uptime Kuma) is only cumulative **counters** (`watchtower_containers_updated` /
`_failed` / `_scanned`, `watchtower_scans_total`) — no container names or image
versions. So the "what was actually updated" has to come from notifications or
logs, not metrics. Build it up in layers:

- [ ] **Tier 1 — ntfy notifications (quick win, reuses the existing ntfy).** On the
      watchtower service set `WATCHTOWER_NOTIFICATION_URL` to a shoutrrr ntfy URL
      pointing at our ntfy instance (dedicated topic, e.g. `watchtower`) and
      `WATCHTOWER_NOTIFICATION_REPORT=true` for a per-run report (which containers
      updated/failed/skipped, old→new image). Gives a timestamped, persistent
      history in ntfy + a phone push — directly answers "what & when." Lowest effort.
- [ ] **Tier 2 — Prometheus + Grafana on the existing `/v1/metrics`.** Scrape the
      counters, dashboard the update/scan trend, alert on
      `watchtower_containers_failed > 0`. Counts only (no names) — pairs with Tier 1
      for the "what." Heavier (new stack); also becomes the home for other metrics
      (glances, node-exporter, cAdvisor).
- [ ] **Tier 3 (optional) — dedicated update tracker with a UI.** Evaluate What's Up
      Docker (WUD) or Diun, which show per-container available/applied updates in a
      UI. Could complement or take over watchtower's notification role.

### Broader improvements (from the post-rollout review)

- [ ] **Pin the Tailscale sidecar image.** All ~13 sidecars run
      `tailscale/tailscale:latest` and watchtower auto-updates them — a bad release
      could drop every HTTPS front door at once. Pin a stable tag (bump
      deliberately) or exclude the sidecars from watchtower. Cheap, high-value.
- [x] **Backups.** Nightly restic backup of all persistent server state to the
      dedicated 1TB drive (+ optional 14TB second copy), encrypted/deduplicated/pruned,
      with ntfy alerts and a homepage status card — `linux-server/backup/` (6965c1b).
      Covers Forgejo (repos+LFS+DB), all SQLite app DBs (online `.backup`, no downtime),
      Portainer BoltDB, certs/configs, and every `.env`. `ts-state/` deliberately
      excluded (re-auth via `TS_AUTHKEY` regenerates node keys). systemd timer (03:30,
      Persistent) + OnFailure alert; restore runbook in `linux-server/backup/README.md`.
- [ ] **DRY the sidecar boilerplate.** ~13 near-identical `<svc>-ts` blocks +
      `ts-serve.json` (differ only by hostname/port). Use Compose `extends` from a
      shared base so a global change (the image pin above, `TS_EXTRA_ARGS`) is one
      edit, not 13. Medium effort — touches all stacks, needs live re-verify.
- [ ] **One shared `TS_AUTHKEY`.** The same OAuth secret is copied into ~13 `.env`
      files; rotation/rebuild means editing all of them. Share one env file.
- [ ] **Validation script for the server stacks** (CI, like `dryrun-smoke.sh`):
      assert every `linux-server/*/` has matching compose + `ts-serve.json` +
      `.env.example`, valid YAML/JSON, serve port == container port, `ts-state/`
      gitignored. Catches the drift that bit us mid-rollout (wrong port, stale config).
- [ ] **Tighten the Tailscale ACL** — least-privilege for the `tag:container` nodes
      (currently default allow-all).
- [ ] **Forward-auth for the NPM public edge** (Authelia/Authentik) — bundle with the
      `*.home.ulises-c.me` NPM setup, since services like filebrowser/glances have
      weak/no auth once exposed off-tailnet.

## qBittorrent — VPN routing

`linux-server/qbittorrent` currently runs without a VPN (fine for academic/legal
torrents only). Before broader use, route all torrent traffic through a VPN.

- [ ] Add a `qmcgaw/gluetun` sidecar; set qBittorrent to `network_mode: service:gluetun`
      (move the `6881` + web UI port mappings onto the gluetun service, add a kill-switch)
- [ ] Pick a provider — evaluate free Cloudflare WARP vs a paid WireGuard provider
- [ ] Add the provider creds to `.env.example` / `.env`

## linux-server — Raspberry Pi 4

Set up the Raspberry Pi 4 headless server config under `linux-server/`.

- [ ] Audit existing linux-server/ files and update as needed
- [ ] Create or update packages JSON for the Pi (arm64, Debian-based)
- [ ] Create setup script for headless server (no GUI packages, no snap)
- [ ] Zsh config (server variant — no Ghostty, no fastfetch on launch, no desktop notifications)
- [ ] Tailscale, Docker, SSH hardening
- [ ] Homepage dashboard config (already exists under linux-server/homepage/)
- [ ] Test on Raspberry Pi 4
