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

## Hiscore patches

The same image layer patches the engine's hiscores (each script fails the build if upstream no longer matches, and a rerun is a no-op):

- `hiscore-pages.js` (`web/pages/hiscores.ts`): the ranked lists (Overall, each skill, Quest Points) get a stone-styled pager under the table: Top, Prev and Next move 21 ranks, the rank search's page size, and keep `category`, `profile` and a searched `player`; the ends are greyed out and the box shows "Ranks X–Y of N". A name search highlights the player and links its rank to the page that shows them. Equipment and Bank (fixed top 50) and Lava Maze Runite (three top 10s) are not paginated lists, so they get no pager.
- `hiscore-prune.js` (`server/login/LoginServer.ts`): the login server writes a skill row only at base level 15+ and never deleted one, so a row written at a higher level (e.g. under another XP curve) stayed on the board. At save, a skill below 15 now deletes its row; rows at 15+ are written exactly as upstream does.

`fix-hiscore-levels.py` is the one-off repair for rows already written under the wrong curve: it recomputes each skill row's level from its stored XP on the original curve (deleting rows under 15) and leaves Quest Points, playtime and `hiscore_large` alone (total level needs every skill; it heals at the account's next logout). It is a dry run by default; `--apply` refuses while `rs-sdk-server` runs on that database and backs it up first (`~/.local/state/computer-setup/hiscore-fix-<time>.sqlite`). Run it while the engine is stopped:

```sh
python3 linux-game-server/rs-sdk/fix-hiscore-levels.py --db ~/games/rs-sdk/data/db.sqlite          # dry run
python3 linux-game-server/rs-sdk/fix-hiscore-levels.py --db ~/games/rs-sdk/data/db.sqlite --apply  # engine stopped
```

## Access

The RS-SDK Homepage card opens the game-server-hosted
[companion portal](portal/README.md) at `/rs-sdk/`: Account Database, Benchmarks,
cached Wiki, Play, HiScores and Grand Exchange. The [wiki runtime](wiki/README.md)
keeps scraped data and its queue on the server; clients request pages over SSH.
The Mac separately publishes read-only, credential-free account/benchmark views.
Vanilla Lost City remains separate.

The [fleet service](fleet-service/README.md) (`rs-fleet-service`, tailnet port 9447) is the bot fleet's
shared gate, pins, accounts and datasets. It runs in its own container; bots never run on this host.

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
