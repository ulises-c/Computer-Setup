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

LAN traffic is allowed only from `LAN_CIDR` on `LAN_IFACE`, both set in this directory's gitignored `.env` (copied from `.env.example` by `setup.sh`; activation refuses to run while either is empty). Tailscale HTTPS frontends use ports 9444 (Lost City), 9445 (RS-SDK web), and 9446 (RS-SDK gateway), bound to `tailscale0`. The web apps use root-relative routes, so they get separate HTTPS ports rather than subpaths. Raw game/gateway ports are allowed on LAN and `tailscale0` only after the activation script confirms a listener is present. Internal RS-SDK gateway port 7780 and management port 8898 are not opened.

Compose uses host networking with no `ports:` mappings so UFW can enforce the source restrictions; Docker-published ports can bypass UFW. No router port forwarding is configured. Tailscale Serve (not Funnel) is tailnet-only.

## Data and operational gate

- Lost City: `~/games/lost-city/runtime` contains source checkouts, world/player data, and server configuration.
- RS-SDK: `~/games/rs-sdk/data` contains SQLite databases and player saves.

Both are stateful. The nightly game backup (`linux-game-server/backup/`) covers them: for Lost City, `server.json`, `engine/.env`, `engine/data/players`, `engine/data/config` and an online SQLite copy of `engine/db.sqlite` (staged as `lostcity/db.sqlite.sqlitebak`); for RS-SDK, the whole data directory, with its SQLite files staged the same way. The source checkouts and `node_modules` are not backed up; they come back from the bootstrap's revision clone. The paths are read from `lostcity/.env` and `rs-sdk/.env` when the backup is installed, so rerun `sudo bash linux-game-server/backup/setup.sh` after setup or after changing either file.

Player saves are copied live; a save written during the backup can be torn, so prefer the previous night's snapshot if one fails to load. The first backup that finds each stack's data writes a `<stack>-seen` marker under `/var/lib/computer-setup-backup/game-backup/` (backed up with it); from then on a missing data directory fails the backup instead of succeeding and pruning without it. Delete the marker if a stack is removed on purpose. Paths that resolve through a symlink are refused, because the containers can write these trees.

Before inviting players, run `sudo bash server-base/backup/restore-check.sh linux-game-server` and restore into a stopped stack once:

1. Rerun setup to get the checkouts. The bootstrap clones the current tip of the revision branch, which can be newer than the code that wrote the backup; note `git -C <checkout> rev-parse HEAD` for `engine`, `content` and `webclient` before each planned update.
2. Stop the service, then put the backed-up files back.
3. For every staged `*.sqlitebak`, delete the live database's `-wal`, `-shm` and `-journal` files (the restored raw copies of them included), then copy the staged file over the database with `.sqlitebak` stripped. A stale WAL left next to a clean copy is replayed onto it and can corrupt it. RS-SDK runs SQLite in WAL mode.
4. Start the service and log in with an existing account.

The Dragonwilds `restore-drill.sh` does not cover these stacks. The activation script does not claim an application-consistent backup or a successful client join. For upgrades, stop the relevant service, preserve the data, update the source intentionally, rebuild, and verify the existing world/account data before reopening access.

See `lostcity/README.md` and `rs-sdk/README.md` for per-stack details.
