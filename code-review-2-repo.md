# Code Review 2 — Repo-wide: PRs #58, #59, #60, #61 (residual)

Max-effort review: 10 finder angles (9 agent runs; 5 re-run after a session-limit interruption)
→ 4 subsystem verifiers → gap sweep. Companion to `code-review-1-agents.md`
(which covered AGENTS.md/CLAUDE.md/agentic-ai on PR #61).
Review artifact for PR #61.

## Top findings (ranked)

### 1. Backup failure-notifier dies at the same guard that killed the main run — CONFIRMED
`linux-pi/backup/backup.sh:28` — `.env` is sourced (l.12-17), the `:?` guards run
(l.28-29), and the `notify-failure` branch is only dispatched at l.74. A missing/bad
`.env` kills the 03:45 run before the EXIT trap is even installed (l.92), then
`pi-backup-failure.service` re-runs the script and dies at the identical guard —
**no ntfy, no Kuma push, ever**. Backups stop silently. Fix: dispatch `notify-failure`
(or install the trap) before the guards, and let the guards themselves notify.

### 2. Second-repo copy failure aborts the whole run — README promises the opposite — CONFIRMED
`backup.sh:153-165` — only `restic cat config` sits in a set-e-exempt position, and
its failure is indistinguishable from "repo not initialized": an unreachable second
target falls into the `restic init` branch, which fails as a bare statement → whole
script aborts through the failure trap → urgent FAILED alert although the primary
backup, prune, and check all succeeded. README (l.32-33, 183-184) claims the copy "is
silently skipped" on SFTP failure. Fix: probe reachability separately and guard the
whole second-repo block with an explicit skip + notice.

### 3. Nightly backup can hang forever and silently stop all future runs — CONFIRMED
`pi-backup.service` — `Type=oneshot` (default `TimeoutStartSec=infinity`), no
`RuntimeMaxSec`, and restic-over-SFTP with no ServerAlive/connect timeout anywhere. A
black-holed TCP connection leaves the unit "activating" indefinitely: the timer won't
re-fire while active and OnFailure never triggers (nothing failed). Fix:
`RuntimeMaxSec=` (e.g. 2h) on the unit and/or `-o sftp.args` keepalives.

### 4. UPS tuning flow silently doesn't apply — driver never restarted — CONFIRMED
`linux-server/ups/setup.sh:77-83` restarts only `nut-server`/`nut-monitor`. The
`override.battery.charge.low/runtime.low` lines README tells you to uncomment "and
re-run setup.sh" are **driver** (usbhid-ups) settings; the running driver keeps the
old ~10% LOWBATT until reboot. The safety margin you configured doesn't exist during
the next outage. Fix: restart `nut-driver@cyberpower` (or `nut-driver.target`) when
ups.conf changed.

### 5. `nut` installs inert (MODE=none) and is structurally unverifiable — CONFIRMED
`packages.json:413` installs nut via plain `apt` on server — not a `custom` manager,
so the engine never runs nor even *reminds* about `linux-server/ups/setup.sh` (the
pointer lives only in the free-text description; reminders print only for `custom`).
Debian's default is `MODE=none`: a fresh provision has no UPS monitoring or shutdown.
And `lib/verify.sh:282-284` hard-rejects `--platform server`, so the one machine that
needs nut can never be health-checked. Fix: make nut a `custom` entry (or add a
server-profile custom step), and revisit verify.sh's server rejection now that
server-only packages exist.

### 6. Pi AdGuard replication can't work as documented — ORIGIN_URL hits NPM, not AdGuard — CONFIRMED (2 independent finders)
`linux-pi/adguardhome-sync/.env.example:6` — `ORIGIN_URL=http://<server-ip>` with the
comment "always reachable, no Tailscale dependency". But the primary AdGuard publishes
only 53/tcp+udp on the LAN IP; its UI/API lives in the adguard-ts netns behind
tailscale serve, and host :80 belongs to nginx-proxy-manager. Every sync fails; the
backup resolver never mirrors filters — noticed only during a failover. Fix: point
ORIGIN_URL at the tailnet HTTPS name (accepting the dependency) or publish the API
port on the LAN.

### 7. Pi homepage on host :3000 collides with AdGuard's first-run wizard — CONFIRMED
`linux-pi/homepage/docker-compose.yml:31,42-43` — homepage is host-networked on
:3000; Pi adguardhome is **also** host-netns (unlike the server, where it hides in
the sidecar netns). A wiped/fresh AdGuard conf makes its wizard bind :3000 → bind
failure crash-loop, on the backup-DNS box, during a recovery scenario. The server
variant documents a temporary `3003:3000` mapping; the Pi has nothing. Fix: move Pi
homepage off 3000 or document the wizard-port conflict beside the compose.

### 8. Backup stages all service secrets world-readable in /var/tmp — PLAUSIBLE→likely CONFIRMED (sweep)
`backup.sh:117` — `.env` files (TS_AUTHKEY, AdGuard creds, RESTIC_PASSWORD, tokens)
are `cp -a`'d into `/var/tmp/pi-backup-staging` (default-umask 755 dirs), no
`PrivateTmp=` on the unit, cleanup only via the EXIT trap. SIGKILL/OOM/power-loss
leaves the plaintext bundle persisting across reboots. Fix: staging dir under
`/root` with 700, `PrivateTmp=yes`, or back up the paths directly without staging.

### 9. Privacy leaks: real username, home path, and server hostname committed — CONFIRMED
`pi-backup.service:8` + `pi-backup-failure.service:8` (`/home/ollie/...` ExecStart),
`linux-pi/homepage/config/services.yaml:45` (`ollie-server — primary home server`),
`linux-pi/backup/LEARNINGS.md:50` (`` `ollie` ``), `linux-pi/README.md:118`
(`192.168.1.1`). All contradict AGENTS.md's own privacy section in a public repo.
The units also break on any other checkout path — ship them as templates rendered at
install (the ups setup.sh sed pattern already exists in-repo).

### 10. Backup snapshots capture AdGuard's live databases mid-write — sweep
`backup.sh:101` — `adguard/work` (querylog/stats DBs, continuously written) is in the
source set with no quiesce/exclude; the server's own script stops portainer for
exactly this reason. Restores can yield a corrupt DB; the churn also bloats every
SFTP transfer. Fix: exclude `work/` (conf/ is the restorable state) or stop/start the
container around the snapshot.

### 11. The Glances disk-rename chain fails silently three different ways — CONFIRMED + sweep
`linux-server/glances/rename_disks.py` + `entrypoint.sh`: (a) the monkey-patch wraps
everything in `except Exception: pass` with zero logging, on an unpinned
`:latest-full` image whose internal plugin API has renamed before; (b) the `sed`
parent-disk derivation breaks on `nvme…`/`mmcblk…` names AND the `^[a-z]+$` filter
would reject them anyway — silent no-op for any non-sdX device; (c) mapping is built
once at container start, but the DAS mounts `nofail` — boot with the enclosure
absent/late and glances runs unpatched until a manual restart. Widgets just go blank;
nothing signals why. Fix: log on patch failure, pin the image, fix the derivation
(`lsblk -no pkname`), and re-resolve labels inside `patched()` (also kills the
restart-after-reshuffle toil).

### 12. Pi dashboard rejects all LAN access — ALLOWED_HOSTS dropped every local identity — CONFIRMED
`linux-pi/homepage/docker-compose.yml:41` — only `localhost,<ts.net domain>`; the
server variant allow-lists hostname/.local/LAN-IP/tailscale variants. Host-networked
on :3000, so LAN requests reach it and get "Host validation failed" — the dashboard
is tailnet-only, failing exactly when the tailnet is down (its raison d'être).

### 13. CUPS sidecar connects from the bridge gateway, but cupsd listens on localhost only — CONFIRMED (2 finders)
`linux-pi/cups/ts-serve.json:5` proxies to `host.docker.internal:631`; Debian default
is `Listen localhost:631` + local-only `<Location>` policy. Connection refused/403
before the documented ServerAlias fix is ever reached. Fix: document the required
`Listen`/`Allow` change next to the ServerAlias note.

### 14. Pi README tells you to run `setup.sh --profile server` on Debian — it will abort — CONFIRMED
`linux-pi/README.md:96` — the server platform snap-installs micro/nvtop and
apt_bootstrap adds an Ubuntu PPA; Raspberry Pi OS has no snapd and no PPAs, and under
`set -euo pipefail` the run dies mid-provision. `platforms/server.sh:7` itself calls
the Pi "a future target". Fix: reword to the manual prerequisite list until the Pi is
a real platform.

### 15. UPS notifications: no curl timeout + NOCOMM re-fires every 5 min — CONFIRMED
`ups-notify.sh:24-26` — no `--max-time`; during an outage (router down) each event's
curl can block ~2 min, and alerts for the shutdown sequence are delayed/lost.
Compounding: `upsmon.conf.template` `NOCOMMWARNTIME 300` + `NOTIFYFLAG NOCOMM
SYSLOG+EXEC` = an urgent push every 5 minutes for a loose USB cable (~576/weekend) —
alert-fatigue that gets the topic muted before a real outage. Fix: `--max-time 10`,
and NOCOMM to SYSLOG-only (COMMBAD/COMMOK already signal the state change).

## Also confirmed (below the top-15 cut)

- **Boot race:** `pi-backup.service` has `After=network-online.target` but no
  `Wants=` — with `Persistent=true`, every power-restore boot fires a backup before
  the network is up → spurious FAILED alert. One-line fix.
- **Double-alert + status clobber:** every failure sends 2× ntfy + 2× Kuma (EXIT trap
  and OnFailure unit), and the second `write_status` zeroes the duration/snapshot the
  trap recorded.
- **peanut-ts missing the `dns:` bootstrap guard** every other sidecar got (#59
  merged before #58's fix pattern; same deadlock class on cold boot).
- **Timer contention (sweep):** Pi's 03:45 job overlaps the server's 03:30
  backup+prune+check on the same DAS spindles on exactly the slow nights; nothing
  serializes them.
- **9.9.9.10 (sweep):** the sidecar bootstrap DNS is Quad9's *unsecured* tier (no
  DNSSEC/filtering), now copy-pasted into 5 files — deliberate or a typo for 9.9.9.9?
- **Docs migration losses (#60):** the Ubuntu-desktop live-run record (`eb0fe49`,
  verify green) exists nowhere at HEAD; CHANGELOG says "30 findings" (actual: 36);
  the CachyOS zsh-notify caveat and the 14TB-second-copy detail were dropped; the
  open "re-run suites, check for nulls" instruction was recast in past tense with no
  record it ever ran.
- **Stale pointers:** 11 shell headers still cite root `UNIFICATION.md`/`TODO.md`
  (the #60 link fix only covered markdown); `docs/UNIFICATION.md` sends readers to
  CLAUDE.md "for the current architecture" (now a 14-line shim — should be
  AGENTS.md); `docs/HANDOFF.md` says "Portainer is next per the TODO.md table"
  (rollout finished; table moved); `docs/TODO.md`'s Pi section says the config goes
  "under linux-server/", leaves shipped items unchecked, and sizes the sidecar debt
  at ~13 (actual: 22); `linux-server/post-install.md:177` has a `../../macOS/...`
  link resolving above the repo root.
- **Pi homepage `docker.yaml` gitignored but required** (4 independent finders):
  `services.yaml` references `server: my-docker`, homepage never auto-generates it,
  and no doc says to create it — the backups card's container status is dead on a
  fresh deploy.
- **`depends_on: homepage-pi-ts`** needlessly takes the LAN dashboard down when the
  inbound-only sidecar can't start (same pattern on the server).
- **Pi adguard widget round-trips the tailnet** to reach a service on its own host
  (`localhost:80` works; the server uses the localhost pattern everywhere).
- **No lint gate covers Python:** `rename_disks.py` (and pre-existing `proxy.py`) are
  the only executables no pre-commit hook or CI job even syntax-checks.
- **Style:** `glances/entrypoint.sh` is `#!/bin/sh`, no `set -e`, `[ ]` — against the
  repo's stated Bash rules, with no busybox-image justification comment;
  `ups-notify.sh` sets only `set -u`.
- **LEARNINGS.md is factually wrong (sweep):** restic's sftp backend shells out to
  system `ssh` (it does read ssh_config); the "embedded Go client, reads no config"
  claim will misdirect future debugging and hides host-key rotation risk.
- **UPS setup.sh:** `--dry-run` dies without `.env` (breaks the repo's dry-run
  convention; the NUT-missing check shows the right pattern one screen up);
  `deploy()`'s `cmp -s` short-circuit never reconciles ownership/mode drift on the
  password-bearing files; NTFY_* values are rendered unvalidated into a root-written,
  nut-sourced env file (robustness, not a privilege boundary — the .env author is
  already trusted).
- **Reuse/altitude:** the Tailscale sidecar block now exists in 22-23 hand-copies
  (TODO's own DRY plan says "~13", already stale) and divergence is realized
  (peanut-ts dns); `linux-pi/backup/backup.sh` is a ~174-line fork of the server's
  233-line script (shared notify/kuma/status machinery will drift); `linux-pi/` is a
  growing parallel universe the tracked fold-into-setup.sh must unwind (~20 near-twin
  files and counting).
- **Efficiency batch:** nightly `restic check` (no `--with-cache`) + nightly
  `--prune` on both repos where weekly would do; 3 restic invocations where
  `backup --json` gives snapshot-id and size; adguardhome-sync `CRON */10` (144
  full syncs/day for weekly-change config); 8 glances widgets polling at the 1s
  default with no `refreshInterval`; zero `logging:` limits on any Pi container +
  live querylog on SD (flash wear on the resilience box).

## Refuted

- **adguardhome-sync env-var names** (`FEATURES_DHCP_SERVER_CONFIG`, `RUN_ON_START`):
  current upstream README documents exactly these underscored forms for `:latest`;
  the concatenated variants belong to older releases. The `.env.example` is correct.
- PR #60's TODO trim dropped **no open items** (every `[ ]` survived); all 36
  benchmark findings did land in `docs/macos-benchmark-review.md`; PR #59's
  packages.json change is purely additive; the NUT name/user/password chain and
  peanut's port chain are internally consistent end-to-end; glances label names match
  the homepage widgets letter-perfect; all `.env.example` vars are consumed; the four
  platform shims and post-install's new UPS/DAS sections check out.
