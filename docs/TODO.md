# TODO

Open work only. Completed work is recorded in [CHANGELOG.md](CHANGELOG.md); the
unified-layout design rationale is in [UNIFICATION.md](UNIFICATION.md).

## RuneScape: Dragonwilds follow-ups

- [ ] Keep `MAX_PLAYERS=6` for normal operation; if testing 10 or 20, make a
      fresh stopped-world backup, verify the startup log's effective capacity,
      and test real joins beyond six before treating it as usable.
- [ ] Retest the join-code route from a Tailscale client; the documented evidence
      shows EOS can advertise the WAN address while direct tailnet-IP connect works.
- [ ] Arrange recurring off-host backups for this host's `Saved/Config`,
      `Saved/SaveGames`, and private deployment `.env`; the rename backup is only
      a rollback point, not recurring coverage.

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

## Server UPS — EcoFlow `ups.load` (NUT master build)

**Parked (2026-09-25):** the EcoFlow is disconnected from the server and will
move to another device. Its NUT config lives on, undeployed, in
`linux-server/ups/ecoflow.ups.conf` + `udev-ecoflow.rules`; resume this on
whichever host it lands on.

NUT monitors the EcoFlow River 3 Plus, but `ups.load`
shows empty. Root cause: the EcoFlow firmware exposes **no load percentage over
USB HID** (confirmed by the `EcoFlow HID` subdriver author and EcoFlow support —
see NUT PR #2837). The fix is NUT's **CDC serial companion**
(`ecoflow-hid-aux-cdc.c`), which derives `ups.load` from
`output_power / rated_output_power`, plus per-outlet power, frequency,
temperature, and AC input telemetry. It is enabled by `ecoflow_cdc_port` in
`ups.conf`.

**This is not available in any packaged NUT.** Ubuntu 26.04 ships 2.8.4, which
the subdriver `driver.version.data: EcoFlow HID 0.01` reflects — it rejects the
variable with `Fatal error: 'ecoflow_cdc_port' is not a valid variable name`.
Even the latest stable **2.8.5 lacks it**; the CDC feature landed post-2.8.5 in
**NUT master**. So the only way to get `ups.load` is to build NUT from git master.

State before this was attempted (don't skip these notes):
- `/dev/serial/by-id/usb-EcoFlow_EF-UPS_RIVER_3_Plus_...-if01` → `/dev/ttyACM0`
  already exists (the unit exposes the CDC ACM interface; group `dialout`).
- `ecoflow.ups.conf` intentionally does **not** carry `ecoflow_cdc_port` yet — adding it
  to the 2.8.4 driver makes `nut-driver@ecoflow` die in a restart loop
  (`result 'protocol'`). It must be added **after** the master build replaces the
  driver.

### Build + install (run as root on the server)

```sh
# 1. Build deps (autotools + libusb + ssl for the NUT build)
apt install -y git build-essential autoconf automake libtool pkg-config \
  libtool-bin libusb-1.0-0-dev libssl-dev

# 2. Clone master (depth-1 is fine)
git clone --depth 1 https://github.com/networkupstools/nut /usr/local/src/nut
cd /usr/local/src/nut

# 3. Generate configure + build flags tailored to the Ubuntu usrmerge layout
./autogen.sh
./configure \
  --with-usb=yes \
  --with-serial=yes \
  --with-statepath=/run/nut \
  --with-pidpath=/run/nut \
  --with-altpidpath=/var/run/nut \
  --prefix=/usr \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --with-drvpath=/usr/libexec/nut \
  --with-cgipath=/usr/lib/cgi-bin/nut \
  --with-udev-dir=/lib/udev \
  --with-confdir=/etc/nut

# 4. Build (parallel; -j to taste)
make -j"$(nproc)"

# 5. Back up the distro binaries in case apt re-packages later
cp -a /usr/sbin/upsd{,,.distro} && cp -a /usr/sbin/upsdrvctl{,,.distro} \
  && cp -a /usr/sbin/upsmon{,,.distro} && cp -a /usr/bin/upsc{,,.distro} \
  && cp -a /usr/libexec/nut/usbhid-ups{,,.distro}

# 6. Install (overwrites the distro binaries; configs stay in /etc/nut)
make install
ldconfig

# 7. Confirm the new driver now understands the CDC variable
upsdrvctl -h | grep -i cdc        # or: /usr/libexec/nut/usbhid-ups -h | grep cdc

# 8. Add the CDC port to the ecoflow stanza in ups.conf, then redeploy
#    (this deferred change is tracked right below)
cd ~/github/Computer-Setup/linux-server/ups
sudo bash setup.sh                  # restarts nut-driver@ecoflow
upsc ecoflow ups.load               # expect a percentage, e.g. 0 - 100
```

Caveats:
- Master is development code. If something's wrong, restore the `.distro`
  binaries (`mv ...`.distro back into place) — `/etc/nut` configs are untouched
  either way.
- An `apt upgrade` of the `nut` package would overwrite the source build; the
  `.distro` backups make the rollback obvious.
- If the CDC poll fails, HID monitoring stays authoritative (by design); only
  the enriched fields (`ups.load`, `input.*`, `outlet.*`, temperatures) go stale
  — see `ecoflow-hid-aux-cdc.c` (`ecoflow_cdc_poll`).

### Deferred ups.conf change (do this only after the master build is live)

Add to the `[ecoflow]` stanza in `linux-server/ups/ecoflow.ups.conf` (substitute the
actual serial suffix from your unit):

```
    ecoflow_cdc_port = /dev/serial/by-id/usb-EcoFlow_EF-UPS_RIVER_3_Plus_<serial>-if01
```

Use the persistent by-id path, not the transient `/dev/ttyACM0`. Then commit
the `ups.conf` change. (Deliberately *not* committed yet: the 2.8.4 driver in
current service rejects it and enters a restart loop.)

## macOS benchmark verification

- [ ] Re-run every benchmark suite end-to-end on one Mac and confirm the result
      JSON has no unexpected `null` fields before treating the measurements as
      validated. The review fixes landed, but no completed post-fix suite run is
      recorded yet.

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

## HTTPS over Tailscale (linux-server) — [#86](https://github.com/ulises-c/Computer-Setup/issues/86)

Every web service is published by host `tailscale serve` on one node per host
(see CHANGELOG); the repo side is done and the live migration is the runbook in
[ONE_NODE_PER_HOST.md](ONE_NODE_PER_HOST.md) section 4. Reference:
[../linux-server/HTTPS.md](../linux-server/HTTPS.md).

- [ ] Run the migration on the server, then the Pi (ONE_NODE_PER_HOST.md 4.1–4.6)
- [ ] After the 7-day soak (4.7): delete the old sidecar nodes, `*/ts-state/`
      and `TS_AUTHKEY` lines on each host, drop the Auth Keys scope from the
      OAuth client, remove `tag:container` from `tagOwners`, and then remove the
      `linux-server/*/ts-state/` and `linux-pi/*/ts-state/` lines from
      `.gitignore` and the `ts-state` exclude from the backup scripts
- [ ] Glances entrypoint writes `allowed_hosts` under `[outputs]`, but Glances
      reads `webui_allowed_hosts` for its Host check, so `GLANCES_ALLOWED_HOSTS`
      may not take effect (`linux-server/glances/entrypoint.sh`). Verify on the
      server after the migration and fix the key if `/glances/` returns 400
- [ ] Set up the NPM trusted-HTTPS edge (domain `ulises-c.me`, already owned):
      NPM wildcard Let's Encrypt cert for `*.home.ulises-c.me` via DNS-01, AdGuard
      rewrite `*.home.ulises-c.me` → LAN IP, then per-service proxy hosts. Not
      started — documented in HTTPS.md to pick up later.

## Server observability & hardening (post-HTTPS rollout) — [#49](https://github.com/ulises-c/Computer-Setup/issues/49)

Improvements identified once every service was wired up for HTTPS. #86 replaced
the per-service sidecars with host `tailscale serve`, which made three items
obsolete (closed below).

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

- [x] ~~**Pin the Tailscale sidecar image.**~~ Obsolete with #86: no sidecars
      are left, and the host tailscaled is updated by the package manager, not
      watchtower.
- [x] ~~**DRY the sidecar boilerplate.**~~ Obsolete with #86: one serve
      template per host (`<host-dir>/tailscale-serve/serve.json`).
- [x] ~~**One shared `TS_AUTHKEY`.**~~ Obsolete with #86: the host node
      authenticates once; no stack carries an auth key.
- [ ] **Validation script for the server stacks** (CI, like `dryrun-smoke.sh`):
      every serve-template mount points at a port its compose file publishes on
      `127.0.0.1`, no stack carries a `TS_AUTHKEY` or `ts-state/`, and every
      `linux-server/*/` with a compose file has an `.env.example` when it reads
      `.env`. `scripts/test-ts-serve-apply.sh` already covers the template's own
      validation rules.
- [ ] **Tighten the Tailscale ACL** — least-privilege grants for `tag:server`,
      `tag:pi` and the three Services (`svc:forgejo`, `svc:ntfy`, `svc:immich`),
      using the port list in [ONE_NODE_PER_HOST.md](ONE_NODE_PER_HOST.md)
      section 2 (currently the default member-to-device rule).
- [ ] **Forward-auth for the NPM public edge** (Authelia/Authentik) — bundle with the
      `*.home.ulises-c.me` NPM setup, since services like filebrowser/glances have
      weak/no auth once exposed off-tailnet.

### DNS resilience (from the 2026-07 outage)

The scheduled-maintenance outage took the whole LAN's DNS down and it couldn't
self-heal — the server ran the only resolver, and a latent bootstrap deadlock
kept the primary AdGuard from recovering.

- [x] **Fix the bootstrap deadlock.** The primary AdGuard rode its Tailscale
      sidecar's netns, and the sidecar's OAuth bootstrap needed DNS — so a cold
      start deadlocked (sidecar needs DNS → DNS needs the sidecar). Pinned static
      resolvers on `adguard-ts` (`dns: [9.9.9.10, 1.1.1.1]`). #86 then removed
      the sidecar entirely: AdGuard's DNS no longer depends on any tailscaled.
- [x] **Secondary DNS on the Pi.** Kill the single point of failure: a backup
      AdGuard on `<pi-hostname>`, host-networked (independent of Tailscale) and
      config-synced from the primary, handed out as secondary DNS by the router —
      `linux-pi/adguard` + `linux-pi/adguardhome-sync`.
- [ ] **Secondary DHCP.** DHCP is still single-homed on the server; a server
      outage means no new leases. Add a secondary scope (Pi/router) or long leases.

## Server Docker network sprawl — [#75](https://github.com/ulises-c/Computer-Setup/issues/75)

The host carries 23 IPv4 addresses, 21 of them Docker bridges — one
`<project>_default` per compose project, not one per Tailscale sidecar
(`backup` and `dragonwilds` have no sidecar and still get a bridge). With
`default-address-pools` unset, Docker has spilled six bridges into
`192.168.16.0`–`192.168.111.255`, which is home-LAN space and can collide with a
LAN reached over Tailscale.

Suspected cause of Unreal's LAN discovery advertising an unreachable address in
`linux-server/dragonwilds` (README pain point 11) — the server appears in the
game browser but joining that entry fails, while a typed address works.

- [ ] Pin `default-address-pools` to `172.16.0.0/12` in `/etc/docker/daemon.json`
      and recreate the six `192.168.x` networks — fixes the collision risk with no
      service changes. `setup.sh --profile server` now deploys the pin (with
      rollback) and `verify.sh` checks the file, the live daemon, and names stray
      bridges; applying it on the live server and recreating the networks
      (`linux-server/README.md` step 8) is still manual
- [ ] Decide whether to collapse the per-project bridges onto one shared external
      network. The `{service}.<tailnet>.ts.net` → `<host>.<tailnet>.ts.net/{service}`
      rework ([#86](https://github.com/ulises-c/Computer-Setup/issues/86)) removed
      the sidecars and their tailnet nodes, but no bridges: each project still
      gets its own `<project>_default`
- [ ] Re-test Dragonwilds LAN discovery afterwards; if it still advertises a
      bridge address, the only fixes left are `-MULTIHOME=<ip>` or direct connect

## qBittorrent — VPN routing

`linux-server/qbittorrent` currently runs without a VPN (fine for academic/legal
torrents only). Before broader use, route all torrent traffic through a VPN.

- [ ] Add a `qmcgaw/gluetun` sidecar; set qBittorrent to `network_mode: service:gluetun`
      (move the `6881` + web UI port mappings onto the gluetun service, add a kill-switch)
- [ ] Pick a provider — evaluate free Cloudflare WARP vs a paid WireGuard provider
- [ ] Add the provider creds to `.env.example` / `.env`

## linux-game-server

Dedicated game host (`linux-game-server/`), currently Homepage and the native
Dragonwilds server, migrated off the NAS host.

- [ ] **Backups.** Add restic to the game host, snapshotting `Saved/SaveGames`,
      `Saved/Config` and the private `.env` files into a repository on the NAS
      host's backup drive, and test a restore. Keep the configuration under
      `linux-game-server/`; the NAS side should only provide the target
- [ ] After a verified restore, set `AUTO_UPDATE_RESTART=true` and configure
      ntfy in `linux-game-server/dragonwilds/.env`
- [ ] Reserve the game host's LAN address in the router's DHCP table so the
      Direct-connect address and the Homepage card stay stable
- [ ] Independent review of `feat/linux-game-server`, then open the PR

## linux-pi — Raspberry Pi 4

Docker Compose service stacks now live under `linux-pi/`; base OS provisioning is
still separate from the unified Ubuntu Server profile.

- [x] Secondary AdGuard Home with config sync
- [x] Pi Homepage dashboard and Tailscale front doors
- [x] MotionEye, CUPS, and backup service configuration
- [ ] Add a Debian/arm64 Pi platform to the root provisioning engine (no snap/PPA)
- [ ] Add the shared headless zsh/Tailscale/Docker/SSH base without duplicating
      `platforms/server.sh`
- [ ] Run and record the complete provisioning and service verification on Pi hardware
