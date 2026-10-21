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

## Updates

`update.sh` updates a running stack when its upstream checkout has moved on (Lost City: `engine`, `content` and `webclient` on the revision branch; RS-SDK: its checked-out branch). `install-update-timer.sh` runs it nightly at 04:30, after the 03:00 game backup:

```sh
sudo bash linux-game-server/2004scape/install-update-timer.sh   # --dry-run prints the plan
bash linux-game-server/2004scape/update.sh --check              # what would update, changes nothing
```

When there is an update:

1. **Countdown.** Players get the client's "System update in m:ss" timer and chat broadcasts ("the server goes down for a backup and update in 10 minutes", then at 5 and 2 minutes, 1 minute, 30 and 10 seconds). `countdown.js` sends these through the engine's friend-server relay on loopback; it is the same reboot timer as the in-game `::reboot` command. RS-SDK's engine ticks at 400 ms while the client counts 600 ms ticks, so its timer is resent every 2 s to stay accurate.
2. **Graceful shutdown.** At zero the engine saves and logs everyone out, then exits. Docker's restart policy is off for the countdown so the container stays down. A stack that does not stop cleanly (exit 0 and `Server shutdown complete`) is restarted on its current code and not updated.
3. **Backup.** A fresh `game-backup.service` run, allowed for this user by a polkit rule. The update refuses to start (before any countdown) if the installed backup does not cover the stack's data path, and it does not update when the backup fails.
4. **Update.** Lost City: fast-forward the checkouts, then `bun install`, `sqlite:migrate` and `build` (repack the cache). RS-SDK: fast-forward and rebuild the image (its entrypoint migrates on start). The checkouts must be clean fast-forwards of the expected branch, or the stack is skipped.
5. **Health and rollback.** The stack must report healthy within 15 minutes. Otherwise it is rolled back to its previous commits, image (`computer-setup/rs-sdk:rollback`) and database (a copy taken after the shutdown, kept next to the data directory as `<dir>.pre-update`), and that target is not retried until upstream moves again or `~/.local/state/computer-setup/2004scape-update/<stack>.failed` is removed.

Stopped stacks are left alone. The countdown runs even when nobody is online. Settings, in this directory's `.env`: `UPDATE_COUNTDOWN_MINUTES` (default 10), `AUTO_UPDATE=false` to only be notified, and optional `NTFY_URL`/`NTFY_TOPIC`/`NTFY_TOKEN` for results. Logs: `journalctl -u 2004scape-update.service`. Update through this script, not by hand: a manual `git pull` skips the backup, the migrations and the rebuild.

See `lostcity/README.md` and `rs-sdk/README.md` for per-stack details.
