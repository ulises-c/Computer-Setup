# 2004Scape self-hosted services

This directory hosts two independent game stacks on the game server:

- `lostcity/`: vanilla LostCityRS 2004Scape, revision 254 by default.
- `rs-sdk/`: the separate RS-SDK fork, with its own engine, web client, accounts, and bot gateway.

They do not share source trees or save data. The Lost City checkout is in `~/github/Server`; RS-SDK is in `~/github/rs-sdk`. Runtime state is stored outside the Git checkout under `~/games/`.

## Setup

1. Run `bash linux-game-server/2004scape/setup.sh`. It performs the one-time interactive Lost City Engine setup, builds the RS-SDK image from the cloned checkout, and leaves both game services stopped. The vanilla revision defaults to 254; edit `linux-game-server/lostcity/.env` before setup to choose another upstream-supported revision.
2. Review the setup output and ensure the world configuration exists under `~/games/lost-city/runtime/engine/`.
3. Run `bash linux-game-server/2004scape/activate.sh` as the normal (non-root) user. It refuses to proceed unless UFW is active with default-deny inbound and an SSH allow rule. It adds only LAN-subnet rules and tailnet-interface rules, then starts the Compose projects and applies the existing managed Tailscale Serve configuration. It does not enable UFW, change the default policy, touch SSH, or configure Funnel.

## Access scope

LAN traffic is allowed only from `LAN_CIDR` on `LAN_IFACE`, both set in this directory's gitignored `.env` (copied from `.env.example` by `setup.sh`; activation refuses to run while either is empty). Tailscale HTTPS frontends use ports 9444 (Lost City), 9445 (RS-SDK web), and 9446 (RS-SDK gateway), bound to `tailscale0`. The web apps use root-relative routes, so they get separate HTTPS ports rather than subpaths. Raw game/gateway ports are allowed on LAN and `tailscale0` only after the activation script confirms a listener is present. Internal ports are never opened: Lost City's login, logger, friend and management servers (43500, 43501, 45099, 8898), and RS-SDK's (43510, 43511, 45109, 8899), its telemetry (43512), its hiscores (8889) and its internal gateway (7780). Both engines use host networking, so RS-SDK's internal servers are moved off Lost City's defaults; otherwise RS-SDK would log in against Lost City's login server. `activate.sh` refuses to start while any of these ports is taken.

Compose uses host networking with no `ports:` mappings so UFW can enforce the source restrictions; Docker-published ports can bypass UFW. No router port forwarding is configured. Tailscale Serve (not Funnel) is tailnet-only.

## Data and operational gate

- Lost City: `~/games/lost-city/runtime` contains source checkouts, world/player data, and server configuration.
- RS-SDK: `~/games/rs-sdk/data` contains SQLite databases and player saves.

Both are stateful. The nightly game backup (`linux-game-server/backup/`) covers them: for Lost City, `server.json`, `engine/.env`, `engine/data/players`, `engine/data/config` and an online SQLite copy of `engine/db.sqlite` (staged as `lostcity/db.sqlite.sqlitebak`); for RS-SDK, the whole data directory, with its SQLite files staged the same way. The source checkouts and `node_modules` are not backed up; they come back from the bootstrap's revision clone. The paths are read from `lostcity/.env` and `rs-sdk/.env` when the backup is installed, so rerun `sudo bash linux-game-server/backup/setup.sh` after setup or after changing either file.

Player saves are rewritten in place while the game runs, so their raw copies can be torn. The backup also stages a checked copy of each (`saves/<stack>/` in the staging dir, with a `.sha256` that `restore-check` verifies): read while unchanged, with the save's `0x2004` magic and CRC32 trailer intact. Restore saves from those staged copies. A save that never validates is reported in the backup log and only its raw copy is kept. Players who are online lose up to their last 15-minute autosave in a live backup. The first backup that finds each stack's data writes a `<stack>-seen` marker under `/var/lib/computer-setup-backup/game-backup/` (backed up with it); from then on a missing data directory fails the backup instead of succeeding and pruning without it. Delete the marker if a stack is removed on purpose. Paths that resolve through a symlink are refused, because the containers can write these trees.

Before inviting players, run `sudo bash server-base/backup/restore-check.sh linux-game-server` and restore into a stopped stack once:

1. Rerun setup to get the checkouts. The bootstrap clones the current tip of the revision branch, which can be newer than the code that wrote the backup; note `git -C <checkout> rev-parse HEAD` for `engine`, `content` and `webclient` before each planned update.
2. Stop the service, then put the backed-up files back.
3. For every staged `*.sqlitebak`, delete the live database's `-wal`, `-shm` and `-journal` files (the restored raw copies of them included), then copy the staged file over the database with `.sqlitebak` stripped. A stale WAL left next to a clean copy is replayed onto it and can corrupt it. RS-SDK runs SQLite in WAL mode.
4. Start the service and log in with an existing account.

The Dragonwilds `restore-drill.sh` does not cover these stacks. The activation script does not claim an application-consistent backup or a successful client join.

## Weekly maintenance

`maintenance.sh` restarts running stacks every Monday by default and applies pending updates only in that weekly window. The nightly 03:00 backup remains live on other nights, including CRC-staged player saves; a pending update never causes an extra nightly restart. Lost City updates only `engine` and `content` on the revision branch: the deployed client is `engine/public/client`, not the separate webclient checkout. RS-SDK updates its checked-out branch.

```sh
sudo bash linux-game-server/backup/setup.sh                    # install backup and root restore-check unit
sudo bash linux-game-server/2004scape/install-maintenance-timer.sh  # --dry-run prints the plan
bash linux-game-server/2004scape/maintenance.sh --check         # report pending updates
bash linux-game-server/2004scape/maintenance.sh --now           # explicitly maintain outside the weekly window
bash linux-game-server/2004scape/maintenance.sh --resume        # recover an interrupted update only
```

The installer disables the former `2004scape-update.timer`, without stopping an active update or backup. If an old update is running, wait for it to finish and rerun the installer. Install the backup again after changing either stack's data paths. The maintenance service is unprivileged; its polkit rule grants only starting `game-backup.service` and `game-backup-restore-check.service`.

The maintenance timer checks daily at 01:45, but proceeds only when the **actual next run of `game-backup.timer`** falls on `MAINTENANCE_DAY`. It does not hardcode the backup time or catch up a missed window. With the normal 03:00 backup and ten-minute countdown:

1. **Warn at about 02:48.** Players see the client's “System update in m:ss” timer and chat broadcasts. `countdown.js` uses the engine's loopback friend-server relay. Both stacks use 600 ms ticks by default; the helper also supports faster RS-SDK ticks by resending its timer every two seconds to keep it aligned with the client's 600 ms countdown.
2. **Self-shutdown at about 02:58.** The engine saves and logs everyone out, then exits with Docker's restart policy temporarily disabled. Maintenance requires exit 0 and `Server shutdown complete`. An undelivered countdown or a server that does not self-shutdown is never force-stopped; it stays on its current code.
3. **Let the 03:00 backup run.** Maintenance waits for the existing timer and reuses its run if it began after shutdown. A run that started too early does not count: maintenance waits for it, then requests another. In-progress backups are never stopped. Backup failure prevents updates.
4. **Verify stopped data.** Root's `game-backup-restore-check.service` restores the latest backup, checks staged SQLite integrity and save checksums, requires exact snapshot coverage of expected game state, and compares it against the stopped files. Lost City configuration can use `.env`, `world.json`, or both; every present configuration path is compared. Its staged database (`lostcity/db.sqlite.sqlitebak`) is compared logically with a private copy of the live database and any WAL, so verification does not create SQLite sidecars in live data. Preflight requires those comparison arguments in the installed root unit. Failure restarts unchanged stacks without updating.
5. **Update, then restart.** Stacks without updates start first. Lost City fast-forwards, installs dependencies, migrates SQLite and rebuilds. RS-SDK fast-forwards and rebuilds its image. Dirty, diverged or unexpected branches are skipped. Each updated stack must become healthy within 15 minutes.
6. **Rollback if necessary.** Failed updates restore previous commits, SQLite and player saves. RS-SDK also restores its entire data directory and the image ID the container actually ran, tagged `computer-setup/rs-sdk:rollback`. Pre-change snapshots remain beside the data as `<dir>.pre-update`. If snapshot creation fails before code changes, the untouched stack simply restarts. A failed target is not retried until upstream moves or its `~/.local/state/computer-setup/2004scape-maintenance/<stack>.failed` marker is removed.

An interrupted update leaves `<stack>.inprogress` in that state directory. The next run, or `--resume`, rolls it back before any new work. Signals retain their failure exit status and notifications identify interrupted updates needing recovery. Do not delete recovery markers or pre-update snapshots before recovery. If recovery is deferred because a backup remains active, let the backup finish before running `--resume` and manually starting any unchanged stacks that remain stopped.

Stopped stacks are left alone. The countdown runs even with nobody online. Settings in this directory's `.env`: `MAINTENANCE_DAY=Mon` (Mon–Sun), `COUNTDOWN_MINUTES=10` (1–60), `AUTO_UPDATE=false` to retain the weekly restart but only notify about updates, and optional `NTFY_URL`/`NTFY_TOPIC`/`NTFY_TOKEN`. Logs: `journalctl -u 2004scape-maintenance.service`. Use this script instead of a manual `git pull`, which skips the backup, verification, migrations and rebuild.

See `lostcity/README.md` and `rs-sdk/README.md` for per-stack details.
