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

`hop-timer-utc.js` (`server/login/LoginServer.ts`) fixes the hop timer between worlds: the login server stores `logout_time` as UTC text and read it back as local time, so with the container's Pacific `TZ` the 45-second timer lasted 7-8 hours and an account could not change worlds the same day (measured on the test world: refused with 419 minutes left). It reads the text as UTC; on world 1 since 2026-10-26 (a fixes-only promotion: world 1's upstream commit and image plus the five patch scripts).

`fix-hiscore-levels.py` is the one-off repair for rows already written under the wrong curve: it recomputes each skill row's level from its stored XP on the original curve (deleting rows under 15) and leaves Quest Points, playtime and `hiscore_large` alone (total level needs every skill; it heals at the account's next logout). It is a dry run by default; `--apply` refuses while `rs-sdk-server` runs on that database and backs it up first (`~/.local/state/computer-setup/hiscore-fix-<time>.sqlite`). Run it while the engine is stopped. The data dir belongs to root (the engine), so the simplest way is `world.sh promote IMAGE --now --fix-hiscores` (see "Updates"); by hand:

```sh
python3 linux-game-server/rs-sdk/fix-hiscore-levels.py --db ~/games/rs-sdk/data/db.sqlite          # dry run
python3 linux-game-server/rs-sdk/fix-hiscore-levels.py --db ~/games/rs-sdk/data/db.sqlite --apply  # engine stopped
```

## Worlds

Several engines can share one set of accounts. World 1 (`rs-sdk-server`, node 10) is the main stack and runs the login, friend and logger servers in-process (`EASY_STARTUP=true`). Every other world is a node that connects to those servers over loopback (host networking): same `profile` (`main`), so accounts, saves, banks, quests and hiscores are shared. The worlds are listed in [`worlds/worlds.conf`](worlds/worlds.conf) (id, node id, role, ports); adding a world is one row there, its two Tailscale routes in `../serve.conf`, then `world.sh up <id>`.

| World | Node | Role | Web (tailnet) | SDK gateway (tailnet) | Game TCP | Internal |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 10 | live | `:9445` → 8080 | `:9446` → 7781 | 43595 | gateway 7780, management 8899 |
| 100 | 100 | test | `:9448` → 8180 | `:9449` → 7791 | 43600 | gateway 7790, management 8199 |

- **Roles.** `live`: world 1's own image, open to everyone, a hop target for bots. `test`: a candidate image, an allowlist (default on, kept in the state dir, never committed), never a hop target. `world.sh role <id> live|test` switches; a running world is restarted with a countdown on that world only. Today there is one live world; the test world 100 is up only while a test needs it (`world.sh test up [IMAGE]`, `world.sh test down`).
- **What an extra world shares** (`worlds/world-compose.yml`): world 1's data directory, read-write only for SQLite's lock files: `db.sqlite` for its hiscore pages and the login guard, and `market.sqlite`, the Grand Exchange ledger. That ledger holds a save checkpoint for every account and the engine loads it in preference to the login server's `.sav`, so a world that did not share it would roll back every account it hosted on its next world-1 login. Saves themselves are written only by world 1's login server. Grand Exchange trading is off on extra worlds (`GE_ENABLED=false`, one matching engine). An extra world never migrates the database (`worlds/world-entrypoint.sh`); `world.sh` refuses an image whose migrations differ.
- **Guards** (`worlds/world-node.js`, applied inside the extra world's container at each start, never to world 1's image; a patch that no longer matches upstream stops the start):
  - `world.sh up` fingerprints both images (`worlds/world-compat.js`: the XP table the engine computes, the save version and the save reader/writer, the migrations, the server packs) and refuses a different curve, save format or migrations; changed content packs need `--allow-content-change`, because a save that names an object world 1 does not have may stop loading there.
  - Exclusive login: an account the login table shows on another world is refused ("already logged in") instead of taken over.
  - Every login is preceded by a copy of the save and ledger checkpoint it loads, under the world's state dir (`save-backups/<account>/`); a failed copy refuses the login.
  - Takeover watch: world 1's login server still lets a world-1 login take over an account that is on the extra world. The extra world sees the login table change (two polls, about 4 s) and drops the player without saving, so the two sessions never overwrite each other. The cost is the extra-world progress since its last checkpoint (login, 15-minute autosave or logout).
  - The browser client's `/gateway` relay dials the world's own gateway port (upstream hard-codes world 1's 7780).
- **Broadcasts and restarts are per world.** The friend server relays shutdown timers and broadcasts to one node id (`socketByWorld[nodeId]`), and `countdown.js` sends the node id of the container it runs in, so a test-world countdown never reaches world 1's players or the fleet. `world.sh down` counts down only when someone is on that world, waits for the engine's own logout, removes the container, and checks that the login table shows no account on its node (it sends `world_startup` for the node if one is left).
- **Choosing a world.** A world is a pair of URLs: the web URL for the game client (`SERVER` in a bot's `bot.env`) and its own gateway for the SDK (`GATEWAY_URL`). The gateway takes no world parameter: it relays between the client and the SDK by account and authenticates through the shared login server, so a bot moves world by changing both. The world list is published every 15 seconds by the status timer at `https://<game-host>.<tailnet>.ts.net/rs-sdk-worlds.json` (id, node, role, online, players, countdown, image, `hoppable`, the URLs and `bot_env`); bots hop only to `hoppable` worlds. After a logout, the login server holds a 45-second hop timer before another world accepts the account (a login on the world the account left is never held). World 1's login server runs the timer; before `hop-timer-utc.js` reached it (2026-10-26) the timer lasted 7-8 hours for ordinary accounts. Staff accounts (staffmodlevel 2+) skip it.
- **Isolated test world** (`world.sh test up --isolated [IMAGE] [--reuse-copy]`, `worlds/isolated-compose.yml`). This is for a candidate that cannot share world 1's data: a newer save format, new migrations or other content. World 100 then runs its own login, friend and logger servers (43610, 45110, 43611) on its own data dir, `<state>/100.isolated/data`.
  - **The copy.** `worlds/isolated-copy.sh` makes it as root, in a network-less throwaway container of the image, with world 1's data mounted read-only:
    - SQLite online backups of `db.sqlite` and `market.sqlite`, consistent while world 1 runs;
    - the saves;
    - an `ISOLATED-COPY` marker;
    - nobody logged in.
  - **Start.** The image's own entrypoint then backs up, migrates and converts the copy.
  - **World 1's data is never mounted.** Three layers make sure of it: the compose file has no `RS_SDK_DATA_DIR`, `world.sh` compares real paths, and the entrypoint requires the marker.
  - **Progress is thrown away.** Each `--isolated` start makes a fresh copy unless `--reuse-copy` is given. `test down` keeps the copy; `test down --wipe` deletes it.
  - **Not a hop target.** The world list shows `mode: isolated`, and the world is never hoppable.
  - **The exchange** runs on the copy's own ledger.
- **Cost.** An idle world needs about what world 1 does without players; world 1 measured 700 MiB and 17% of one core with 61 players (Oct 2026) on a 30 GiB, 12-core host.

```sh
bash linux-game-server/2004scape/world.sh status            # every world, the pin, candidates, allowlist
bash linux-game-server/2004scape/world.sh allow 100 add NAME    # then restart the test world
bash linux-game-server/2004scape/world.sh test up [IMAGE]       # default: the latest candidate
bash linux-game-server/2004scape/world.sh test up --isolated [IMAGE] [--reuse-copy]   # own servers + a copy of world 1's data
bash linux-game-server/2004scape/world.sh test down [--wipe]    # --wipe deletes the isolated copy
bash linux-game-server/2004scape/world.sh compat IMAGE          # would IMAGE share saves safely?
```

## Updates: candidate, test world, promotion

World 1 is never updated in place by default (`RS_SDK_UPDATES=candidate` in `2004scape/.env`). When upstream moves, the daily maintenance run builds a candidate (`world.sh candidate build`): upstream at the new commit (a temporary worktree, the live checkout is not touched) plus this directory's patch scripts, built through `worlds/candidate-compose.yml` (the same two stages as world 1's compose file, under candidate tags, so world 1's `:local` and `:upstream` tags never move), tagged `computer-setup/rs-sdk:candidate-<upstream>-<patch set>` and labelled with both. A patch script that no longer matches upstream fails the build: ntfy says so and neither world changes. A good build is checked against world 1 and announced on ntfy ("candidate ready"); nothing starts by itself. The owner then runs `world.sh test up`, tests on world 100, and promotes:

- `world.sh promote [IMAGE] --next-window`: the next weekly maintenance counts down, backs up and verifies, then starts world 1 on the image (rollback to the previous image and data if it is not healthy). This is the safe default.
- `world.sh promote [IMAGE] --now`: a 2-minute countdown on world 1, a copy of the data dir (`data.pre-promote`), then world 1 on the image; not healthy = data and image put back. It refuses while maintenance runs.
  - `--pre-start CMD` runs CMD (bash, `RS_SDK_DATA_DIR` set) once while the engine is stopped, after the data copy and before the new image starts; a failing CMD restores the data copy and the previous image. `--fix-hiscores` is the built-in hook: a dry run of `fix-hiscore-levels.py` before the countdown, then `--apply` as root in a network-less `python:3.14-alpine` container (`HISCORE_FIX_IMAGE`; it must be on the host, or the promotion stops before the countdown), backups in `~/.local/state/computer-setup/hiscore-fix/`.
- `world.sh candidate build --source-ref COMMIT` builds a given upstream commit instead of the newest one (no fetch; a temporary worktree, so the checkout never moves). With world 1's own commit this is a fixes-only candidate: the same game plus the current patch scripts. A fresh build still takes the newest `oven/bun:debian` base and Debian packages (the upstream Dockerfile's floating tag), so for a fixes-only build add `--base-image <world 1's image>`: the patch layer is applied on that image instead (the restore scripts are idempotent), and runtime and OS stay byte-identical. The tag ends in `-on-<base id>`.

### Post-update acceptance

`world.sh promote` refuses an image unless the newest acceptance report recorded for that exact image id passed, covered the whole suite and finished after the image was built. The suite lives in the bot repo (`2004Scape-Botting`, `docs/acceptance.md`): test bots (`bot_tester` + one allowlisted account) on world 100 isolated check login/logout, a walk, exact bank counts, a trade with exact counts on both sides, the XP curve, the hiscores pager, the Strange-box calibration and every random event this server has, spawned on `bot_tester` and solved by the fleet's production solvers, with an isolated fleet gate.

- **The documented way, from the bot host:** `scripts/acceptance.sh --manage IMAGE` = `test up --isolated IMAGE`, the suite, `world.sh acceptance record IMAGE -` here (ntfy summary), `test down --wipe`.
- Here: `world.sh acceptance IMAGE` does the same only when `ACCEPTANCE_RUNNER` in `2004scape/.env` names a command that runs the suite on a bot host and prints the report JSON (this host has no way into the bot hosts by default). Unset (the normal setup), it starts nothing, prints the `--manage` command for that image id and exits 2.
- `world.sh acceptance list [IMAGE]`; reports in `~/.local/state/computer-setup/rs-sdk-worlds/acceptance/<image12>/`, index `acceptance.tsv` (next to `candidates.tsv`).
- `promote ... --skip-acceptance REASON` overrides: logged in `acceptance/skips.log` and notified at high priority.
- An isolated world 100 stops without the in-game countdown when its own friend server is not running (the countdown relays through it); a shared world 100 still refuses.

Runbook for the 1599b86 update (save v10, two migrations, bank 576 / GE 12 slots): [runbooks/promote-1599b86.md](runbooks/promote-1599b86.md).

Both refuse an image with another XP curve, record the image so maintenance keeps it (`rs-sdk.image`), and remind you to take the test world down. `RS_SDK_UPDATES=direct` restores the old in-place update; `notify` only reports.

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
