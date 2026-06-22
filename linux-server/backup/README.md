# Server backups

Nightly [restic](https://restic.net) backup of the server's persistent state to
the dedicated 1TB drive (`/mnt/wd1tb`), with an optional second copy to the 14TB
drive. Encrypted, deduplicated, pruned, and reported to ntfy + a homepage card.

## What gets backed up

- **Forgejo** `data/` — git repositories, LFS, and its SQLite DB (one consistent tree)
- **SQLite app state** — uptime-kuma, speedtest-tracker, nginx-proxy-manager (+ TLS
  certs), ntfy, filebrowser, adguard config/stats
- **Syncthing** config + device keys, **qBittorrent** config (not downloads),
  **Portainer** BoltDB volume, **atvloadly** (`/etc/atvloadly`)
- Every service's gitignored **`.env`** (secrets needed to restore)

Excluded as disposable/regenerable: qBittorrent downloads, all `ts-state/`
(Tailscale node keys — re-auth with `TS_AUTHKEY` regenerates them), caches.

SQLite DBs are snapshotted with sqlite3's online `.backup` (consistent, **no
downtime**); the staged copies carry a `.sqlitebak` suffix. Portainer's BoltDB
gets a ~1s `docker stop`/`start` around a volume copy — the one brief exception.

## Setup

1. Install tools:
   ```sh
   sudo apt install restic sqlite3 jq
   ```
2. Format/mount the backup drive persistently (fstab) at `/mnt/wd1tb`, and drop a
   sentinel so the script knows it's the right disk (guards against writing to an
   unmounted path and filling the root FS):
   ```sh
   sudo touch /mnt/wd1tb/.backup-target-ok
   sudo touch /mnt/wd14tb/.backup-target-ok   # if using the second copy
   ```
3. Configure:
   ```sh
   cd linux-server/backup
   cp .env.example .env
   # set RESTIC_PASSWORD (and SAVE IT IN BITWARDEN), NTFY_URL/topic
   ```
4. Initialize the repo (the script also does this on first run):
   ```sh
   set -a; source .env; set +a
   restic init
   ```
5. Status card server:
   ```sh
   docker compose up -d
   ```
6. Install + enable the timer (system units; adjust the path in the unit files if
   the repo isn't at `/home/ulises/github/Computer-Setup`):
   ```sh
   sudo cp backup.service backup.timer backup-failure.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now backup.timer
   ```
7. Dry run + verify:
   ```sh
   sudo systemctl start backup.service
   journalctl -u backup.service -f
   restic snapshots          # confirm a snapshot landed
   ```

## Restore

```sh
set -a; source .env; set +a
restic snapshots                                  # find the snapshot id
restic restore latest --target /tmp/restore       # or --include <path>
```

Then put state back per service:

- **Plain files** (forgejo git repos, certs, configs): stop the stack, copy the
  restored tree into place, `docker compose up -d`.
- **A SQLite DB**: it's under `/tmp/restore/<staging>/sqlite/<service>/.../<db>.sqlitebak`
  — copy it to the live path with the `.sqlitebak` suffix stripped, while the
  service is stopped.
- **Portainer**: restore `/tmp/restore/<staging>/portainer/` into the
  `portainer_data` volume with the container stopped.

## Warnings

- **Losing `RESTIC_PASSWORD` = unrecoverable backups.** Keep it in Bitwarden.
- **Never** point a service's data path (e.g. `FORGEJO_DATA_PATH`,
  `QBITTORRENT_DOWNLOADS_PATH`) at the backup drive — the script refuses to run if
  a source resolves under `/mnt/wd1tb`, but don't rely on that as policy.
- The script skips missing source paths, so it's safe to enable before every
  service is deployed; coverage grows automatically as data dirs appear.
