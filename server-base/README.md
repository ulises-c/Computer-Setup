# server-base — the layer every server shares

Every server in this repo (the main NAS server in `linux-server/`, the Raspberry
Pi in `linux-pi/`, the game server in `linux-game-server/`) runs the same base
before its own services. This directory owns that base once; host directories
consume it and add only what is genuinely theirs.

## What counts as base

| Layer | What | Where it lives |
| --- | --- | --- |
| Tools | zsh + antidote, tmux, fastfetch, eza, fzf, ripgrep, bat, fd, zoxide, micro, htop, ncdu, smartmontools, jq, curl, wget, git, gh, gnupg | `packages.json` entries tagged `server-base` |
| Agents | claude-code, opencode | `packages.json` (`server-base`), installed by `claude_code_step` / `opencode_step` |
| Dotfiles | `~/.zshrc`, `~/.tmux.conf`, antidote plugins, p10k | `dotfiles/`, deployed by `deploy_dotfiles` |
| Network | Tailscale, one tailnet node per host ([#86](https://github.com/ulises-c/Computer-Setup/issues/86)) | `serve.sh` + each host's `serve.conf` |
| Containers | Docker, Glances, Portainer, Watchtower, Homepage | `glances/`, `portainer/`, `watchtower/`, `homepage/compose.yml` |
| Admin | Cockpit (host package, served under `/cockpit`) | `serve.sh` writes its `UrlRoot`/origin config |
| Backups | restic nightly + status card + ntfy / Uptime Kuma alerts | `backup/` |
| Dashboard | cross-linked Homepage (Servers group, Shared services, design system) | `fleet.json`, `homepage/` |

Not base (single-instance, network-wide, or host-specific): Uptime Kuma, ntfy,
Forgejo, AdGuard (primary on the main server, replica on the Pi), Immich,
Syncthing, NUT, the NAS storage stack, CUPS/MotionEye, Dragonwilds. Uptime Kuma
in particular stays on the main server: a monitor on the host it watches cannot
report that host down.

## How a host consumes it

- **Compose stacks** — `<host>/<svc>/docker-compose.yml` `extends` the service in
  `server-base/<svc>/compose.yml` and adds its own mounts, ports or network
  namespace. Relative paths in an extended file resolve against `server-base/`,
  so host-relative mounts (`./config`, `./assets`) and `env_file` belong in the
  host file. Check a change with `docker compose -f <host>/<svc>/docker-compose.yml config`.
- **Scripts** — `<host>/backup/backup.sh` and `setup.sh` are symlinks into
  `server-base/backup/`, so installed systemd units keep their paths; the host
  keeps `sources.sh`, its unit templates and its `.env`.
- **Serve** — `<host>/serve.sh` execs `server-base/serve.sh`, which reads
  `<host>/serve.conf` (compose dirs, routes, retired ports).
- **Packages** — a host bootstrap selects the `server-base` tag
  (`TAG_FILTER_ACTIVE=true`, `SELECTED_TAGS=["server-base"]`); the main server's
  full `setup.sh --profile server` is a superset.

| Host | Bootstrap | Tailnet layout today |
| --- | --- | --- |
| main server | `setup.sh --profile server` | one sidecar node per service (moves to one node under #86) |
| Pi | `linux-pi/setup.sh` | base services on the Pi's node; its other services keep sidecars until #86 |
| game server | `linux-game-server/setup.sh` | one node, `/<service>` paths |

## Time zone

The host's time zone (`timedatectl`) is the single source. systemd timers
already follow it; containers get it as `TZ` from `server-base/timezone.env`,
which every service in every compose file loads with a required `env_file`
(base stacks as `../timezone.env`, host stacks as
`../../server-base/timezone.env`); a new service needs that entry too, and CI
(`scripts/check-compose-timezone.py`) fails any service that resolves without it.
`timezone.sh` generates that file (gitignored), and the host bootstraps run it
before any compose step. Containers need the zone *name*: Node and PHP images
ignore a bind-mounted `/etc/localtime`.

On a fresh checkout run `bash server-base/timezone.sh` before any
`docker compose up`; compose refuses to start without the file. To change zone:

```sh
sudo timedatectl set-timezone <Zone>
bash server-base/timezone.sh --apply   # rewrites timezone.env, recreates stale compose services
```

`--apply` recreates (`up -d --no-deps`) only running compose services whose
`TZ` differs from the host's or is unset, and needs Docker access (the `docker` group, or
`sudo`). `--dry-run` prints the compose commands instead.

## Homepage

`fleet.json` lists every server (name, icon, description, the `HOMEPAGE_VAR_*`
holding its dashboard domain, its Glances URL, and an optional status JSON) and
the main server's shared services. `homepage/generate.py` renders each host's
`homepage/config/{services,settings}.yaml` from it plus the host's own
`homepage/services.local.yaml` and `settings.local.yaml`, and copies the shared
`custom.css` / `custom.js`. Edit the sources, never the generated files:

```sh
python3 server-base/homepage/generate.py          # rewrite every host
python3 server-base/homepage/generate.py --check  # CI: fail if stale
```

Every dashboard starts with the same **Servers** group: one card per server in
the same order, the current host's card unlinked and marked "(this server)",
the others linked and `siteMonitor`-pinged. Cards show only fixed facts read
from each host's Glances (OS, kernel, hostname, CPU, threads, RAM). Live data
is in the top bar (`widgets.yaml`, also generated): CPU/load, memory, each
disk in the host's `topbar.disks`, CPU temperature and uptime, for that host
only. Glances reports just the filesystems and sensors chosen by
`GLANCES_{FS,SENSORS}_{SHOW,ALIAS}` in the host's glances compose file.
Service status (game worlds etc.) belongs in the host's own groups. Hosts
other than the main server end with a
**Shared services** group linking the main server's single-instance services.

Homepage caches `settings.yaml` in its static page. After changing it, use the
refresh button (bottom right) or `curl http://127.0.0.1:<port>/api/revalidate`.

### Design system

- Icons: colour [selfh.st](https://selfh.st/icons/) logos (`sh-<name>.svg`); the
  `-light` variant only where the brand mark is dark on dark (Portainer,
  Cockpit, Apple TV, Tailscale). Generic glyphs are colour-tinted MDI icons.
- Group accents (`fleet.json` → `hosts.<dir>.accents`, applied by `custom.js`):

  | Accent | RGB | Used for |
  | --- | --- | --- |
  | indigo | 129 140 248 | Servers |
  | blue | 96 165 250 | Management / per-host admin |
  | teal | 45 212 191 | Network |
  | emerald | 52 211 153 | Pi services |
  | amber | 251 191 36 | Storage |
  | orange | 251 146 60 | NAS drives |
  | rose | 251 113 133 | Games |
  | cyan | 34 211 238 | Shared services |

  A group's accent colours its heading bar, the card rule and wash, and its
  Glances charts. Health is always also text (container state, latency in ms),
  never colour alone.
- Dragonwilds artwork (icon, logo, key art) is Jagex's and is not committed:
  `homepage/fetch-assets.sh <host-dir>` downloads it from Steam's CDN into the
  host's gitignored `homepage/assets/`, mounted at `/icons` and `/images`.
  Restart Homepage after the first fetch.

## Backups

`backup/backup.sh` snapshots the paths a host's `sources.sh` lists, plus
consistent SQLite copies, a Portainer volume copy and every service `.env`, then
prunes, optionally copies to a second repository, writes
`/var/lib/computer-setup-backup/<unit>/backup-status.json` for the Homepage card
and alerts through ntfy / Uptime Kuma. The status directory is root-owned; the
status container mounts it read-only. A local-drive repository (`BACKUP_MOUNT`) must be
mounted and carry a `.backup-target-ok` sentinel; a second repository is only
auto-initialized behind such a verified `SECOND_BACKUP_MOUNT`, never over SFTP.
SFTP clients get a chrooted account from `sftp-target.sh` (run on the main
server) and their key, host pin, alias and repositories from `sftp-client.sh`.
`sources.sh` does nothing but assign at source time (paths are resolved in
`resolve_sources` after the guards), so a broken host path still alerts. Failure alerts come only from
the `*-failure.service` `OnFailure` unit, which reads the notifier keys from the
host's `.env` without sourcing it.

| Host | Repository | Unit |
| --- | --- | --- |
| main server | local drive (`/mnt/wd1tb`, copy on `/mnt/wd14tb`) | `backup.service` |
| Pi | main server over SFTP | `pi-backup.service` |
| game server | main server over SFTP | `game-backup.service` |

Install or re-render a host's units with `sudo bash <host>/backup/setup.sh`
(`--dry-run` to preview). Setup captures the Dragonwilds install path into the
root-owned unit; changing `dragonwilds/.env` requires rerunning both setup
scripts. `bash server-base/backup/test-backup.sh` runs the engine against every
host's `sources.sh` with stubbed restic.

Restore checks never touch live data:
`sudo bash server-base/backup/restore-check.sh <host-dir> [--second] [--keep]`
runs `restic check`, restores the host's latest snapshot into a root-only scratch
dir, and verifies the file count, staged SQLite snapshots (`integrity_check`) and
staged copies with a `.sha256` sidecar. The game server also has
`linux-game-server/backup/restore-drill.sh`, which loads a restored world in the
game (see its README). Rerun them after any change to the backup engine or a
host's `sources.sh`.
