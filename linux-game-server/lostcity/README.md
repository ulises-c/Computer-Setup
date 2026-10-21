# Lost City 2004Scape server

This is the vanilla LostCityRS server, separate from the RS-SDK fork. The upstream `Server` repository is an interactive launcher that clones Engine-TS, Content, and Client-TS into its working directory. This deployment keeps that runtime and all save/config data under `~/games/lost-city/runtime` (`LOSTCITY_RUNTIME_DIR`), outside Git, and starts Engine directly under Compose so it can run unattended.

## Setup and access

Run the combined setup from the Computer-Setup checkout:

```sh
bash linux-game-server/2004scape/setup.sh
```

The initial engine setup is interactive. It defaults to revision 254 (September 7, 2004), but the revision can be changed in this directory's gitignored `.env` before setup. The bootstrap only clones dependencies and runs the Engine setup wizard; it exits without starting the game. Leave the server stopped until the firewall/Tailscale activation step is applied.

After activation:

- LAN web client: `http://<server-ip>:8888/rs2.cgi`
- Tailscale web client: `https://<game-host>.<tailnet>.ts.net:9444/rs2.cgi`
- Default game TCP port, if enabled by the selected Engine config: 43594

The UI is on its own HTTPS port because the web client serves root-relative routes and is not configured for a URL base path. Tailscale Serve is tailnet-only; no Funnel or router port forwarding is configured. LAN and direct game ports are limited by UFW to the local subnet (and `tailscale0` for tailnet clients).

## Operations

```sh
docker compose --project-directory linux-game-server/lostcity -f linux-game-server/lostcity/docker-compose.yml ps
docker compose --project-directory linux-game-server/lostcity -f linux-game-server/lostcity/docker-compose.yml logs --tail=100 lostcity
```

Updates go through `2004scape/maintenance.sh` (weekly on Monday once `install-maintenance-timer.sh` is installed): it fast-forwards the revision branches cloned during bootstrap, migrates and repacks with players warned and the world stopped. Do not run the upstream interactive `start.js` update menu on the live server; it only pulls, skipping the backup, migrations and repack. The runtime directory contains the world, player data, and configuration; the nightly game backup covers its state files (not the checkouts), as described in `2004scape/README.md`. Validate a restore before relying on it.
