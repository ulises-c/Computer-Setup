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

Both are stateful. Before inviting players, add these paths to the encrypted game-server backup and verify a restore. The activation script does not claim an application-consistent backup or a successful client join. For upgrades, stop the relevant service, preserve the data, update the source intentionally, rebuild, and verify the existing world/account data before reopening access.

See `lostcity/README.md` and `rs-sdk/README.md` for per-stack details.
