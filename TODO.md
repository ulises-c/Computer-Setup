# TODO

Open work only. Completed work is recorded in [CHANGELOG.md](CHANGELOG.md); the
unified-layout design rationale is in [docs/UNIFICATION.md](docs/UNIFICATION.md).

## Live-run cleanup & follow-ups (unification / dotfiles)

Setup migrates install methods but never uninstalls the old copy, so each live
run leaves shadowed binaries to reconcile.

- [ ] Mac mini live-run cleanup (from the 2026-06 `brew leaves` audit): `brew
      uninstall` the testing leftovers `forgejo`, `tea`, and `python@3.12`
      (project Pythons come from pyenv/uv), plus `zsh-autosuggestions` /
      `zsh-syntax-highlighting` / `powerlevel10k` (antidote manages them now),
      and `brew uninstall --cask claude-code` (repo installs it via curl)
- [ ] MBP live-run cleanup (same audit): `brew uninstall tea python-tk@3.11
      python@3.11 zsh-autosuggestions zsh-syntax-highlighting powerlevel10k`;
      pre-existing casks (anki, ghostty, obsidian) get picked up by the cask
      `--adopt` flag
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

Core Arch/CachyOS support shipped in PR #18 (see CHANGELOG). Remaining:

- [ ] Test `--personal` flag end-to-end
- [ ] Create PR for CachyOS support

## Per-service HTTPS rollout (linux-server)

Every tailnet-facing service is converted (see CHANGELOG); the non-tailnet edge
is what's left. Pattern and full rollout table in
[linux-server/HTTPS.md](linux-server/HTTPS.md).

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
