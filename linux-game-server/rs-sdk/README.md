# RS-SDK server

This is the independent RS-SDK fork, which includes its own game engine, web client, and bot gateway. It is not layered on top of the vanilla Lost City instance. Compose builds the upstream `server/Dockerfile` from the clean checkout at `~/github/rs-sdk` (`RS_SDK_SOURCE_DIR`), then applies this directory's original-XP image layer. State is stored in `~/games/rs-sdk/data` (`RS_SDK_DATA_DIR`). Building requires Docker Buildx and Compose 2.17 or newer for service build contexts. `rs-sdk-upstream` is an image-build helper, not another game: if Compose starts it, its entrypoint immediately exits, with no network or persistent data mounts.

## Original gameplay settings

- `NODE_XPRATE=1`: original XP awards instead of the fork's 25× multiplier.
- `restore-xp.js`: restores the original level/7 XP curve instead of the fork's level/10 curve in the engine, browser client, lite client, lite actions and SDK save generator. The image rebuilds the browser bundles. An unrecognized upstream formula fails the build before any source files are changed; the upstream checkout stays untouched.
- `NODE_INFINITE_RUN=false`: ordinary energy drain and regeneration.
- `NODE_RANDOM_EVENTS=true`: enables the content's existing random-event checks and login timer.
- `NODE_TICKRATE=600`: original tick duration instead of the fork's 400 ms speed.
- `restore-client.js`: restores the browser's original 20 ms logic cycle (the fork uses 14 ms) and the movement packet's Ctrl-run bit instead of forcing every click to run. The normal run toggle and explicit SDK run requests still work; no SDK functionality is removed.

These settings retain SDK connectivity and do not reset earned XP or player saves. An existing character's levels can change when the original XP thresholds are restored. Other fork differences, including its content revision, Grand Exchange and bot tooling, are unchanged; this is not a claim of full vanilla parity.

## Access

The RS-SDK Homepage card opens the game-server-hosted
[companion portal](portal/README.md) at `/rs-sdk/`: Account Database, Benchmarks,
cached Wiki, Play, HiScores and Grand Exchange. Its source-side sync exports
read-only, credential-free views without changing the bot/wiki repositories.
Vanilla Lost City remains separate.

- LAN web client: `http://<server-ip>:8080/`
- Tailscale web client: `https://<game-host>.<tailnet>.ts.net:9445/`
- LAN game TCP: `<server-ip>:43595`
- LAN SDK gateway: `ws://<server-ip>:7781`
- Tailscale SDK gateway: `wss://<game-host>.<tailnet>.ts.net:9446`

The web UI uses root-relative routes, so it gets a dedicated Tailscale HTTPS port rather than a subpath. The browser game's `/gateway` WebSocket is proxied through the web server. The direct gateway and game TCP listeners are allowed only from the LAN and Tailscale interfaces. Internal ports are not opened: gateway 7780, management 8899, telemetry 43512, hiscores 8889, and the login, logger and friend servers on 43510, 43511 and 45109 (moved off the Lost City defaults, which that stack uses on the same host network). Tailscale Serve is tailnet-only; no Funnel or router port forwarding is configured.

The Compose service intentionally does not publish Docker ports: it uses host networking so the host UFW policy can restrict inbound sources. Do not add a Docker `ports:` mapping; Docker-published ports can bypass UFW.

## Operations

Build/initialize both projects with `bash linux-game-server/2004scape/setup.sh`, then activate with `bash linux-game-server/2004scape/activate.sh` after the one-time Lost City wizard completes.

```sh
docker compose --project-directory linux-game-server/rs-sdk -f linux-game-server/rs-sdk/docker-compose.yml ps
docker compose --project-directory linux-game-server/rs-sdk -f linux-game-server/rs-sdk/docker-compose.yml logs --tail=100 rs-sdk
```

Accounts are created automatically on first login: enter a new username and a unique password in the fields below the game canvas, then click **Login**. `WEBSITE_REGISTRATION=false` enables this behavior; `true` requires a separately registered account, and no registration site is deployed here. Accounts and saves are separate from vanilla Lost City. Keep the access boundary intact. The RS-SDK data directory contains SQLite databases and player saves; the nightly game backup covers it (see `2004scape/README.md`). Verify an actual restore before relying on it. Updates go through `2004scape/maintenance.sh` (weekly on Monday once `install-maintenance-timer.sh` is installed), which pulls the checkout and rebuilds the image with players warned, a fresh backup and a rollback image; do not pull and rebuild by hand.
