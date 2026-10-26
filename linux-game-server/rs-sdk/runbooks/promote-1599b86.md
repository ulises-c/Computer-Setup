# Promote upstream rs-sdk 1599b86 to world 1

Prepared 2026-10-26. The owner decides when to run it. The candidate is upstream `1599b86` plus this directory's patch scripts (patch set `3fba49a2bcc4`):

- tag `computer-setup/rs-sdk:candidate-1599b86fe93a-3fba49a2bcc4`;
- image id `c20ac2c829c4`;
- built 2026-10-26 13:45;
- runtime: the upstream Dockerfile's `oven/bun:debian`, bun 1.4.4. This is a real runtime update, not a fixes-only layer.

## What changes for players

- Bank: 576 slots (free accounts 120). Grand Exchange: 12 offer slots per account.
- Saves are written as version 10. This is one-way: an image older than 1599b86 refuses a v10 save, so a rollback must put the data copy back (see Rollback).
- Two database migrations run at the first start: `hiscore_playtime_ms` and `hiscore_normalized_rank`. Before migrating, the image's entrypoint backs up the hiscore tables and the saves under `data/backups/`.
- Hiscores still rank and show playtime in ticks, displayed at `NODE_TICKRATE` (600 ms). The new `playtime_ms` column converts legacy ticks at upstream's fixed 300 ms per tick. Legacy durations are therefore stored at half their wall time. Nothing shown on the pages uses that column.
- Players are never persisted mid-obstacle. `tools/server/relocate-player.ts` exists for stuck saves.

Isolated world 100 (`world.sh test up --isolated`, on a copy of world 1's data taken 2026-10-26 21:44Z) verified:

- all 86 saves load and round-trip as v10;
- both migrations ran;
- the hiscore pager and the prune of rows below level 15 work;
- the UTC hop timer works under `TZ=America/Los_Angeles`;
- in-game bank: 576-slot inventory, deposit and withdraw;
- Grand Exchange: an offer placed in slot 11, cancelled and collected;
- a trade between two bots;
- no engine errors.

## Before

1. Optional: keep today's rollback leftovers. Each `promote --now` replaces both of them:
   - `~/games/rs-sdk/data.pre-promote` is root-owned; it is removed and recopied:
     ```sh
     sudo mv ~/games/rs-sdk/data.pre-promote ~/games/rs-sdk/data.pre-promote-20261026
     ```
   - `computer-setup/rs-sdk:rollback` is re-pointed to world 1's current image:
     ```sh
     docker tag computer-setup/rs-sdk:rollback computer-setup/rs-sdk:rollback-b5cd117b
     ```
2. Check that nothing else is running:
   ```sh
   bash linux-game-server/2004scape/world.sh status
   ```
   World 1 should be healthy. World 100 may stay up: it is isolated and shares nothing with world 1.

## Promote

Run on the game server, in `~/github/Computer-Setup`.

```sh
bash linux-game-server/2004scape/world.sh promote computer-setup/rs-sdk:candidate-1599b86fe93a-3fba49a2bcc4 --now
#  or, at the weekly window (Mon 02:55 America/Los_Angeles; verified backup first):
bash linux-game-server/2004scape/world.sh promote computer-setup/rs-sdk:candidate-1599b86fe93a-3fba49a2bcc4 --next-window
```

What `--now` does:

1. It refuses unless world 1's XP curve fingerprint matches the candidate's. Both use `restore-xp.js`.
2. It tags world 1's current image `:rollback` and announces a 2-minute countdown in game. The fleet's maintenance hold starts on that broadcast.
3. It waits for world 1 to shut down.
4. With the whole container stopped, it runs `cp -a data data.pre-promote`. The container includes the login server, so the copy is consistent. It covers everything in the data dir: `db.sqlite`, `market.sqlite` (the Grand Exchange ledger), `players/` (the saves), `backups/` and the bug reports. The data dir is 17 MB.
5. It starts world 1 on the candidate. The candidate's entrypoint backs up, migrates and converts saves as players log in.
6. If world 1 is not healthy, it stops it, restores the data copy, restarts on `:rollback` and says so.

`--next-window` does the same inside the weekly maintenance, after its verified backup.

## Right after: the fleet's SDK

Switch every fleet host's SDK to the rebased branch `sdk/upstream-1599b86` (commit `6d88e67a6`). The procedure lives in the bot repo: `docs/sdk-update-1599b86.md` (every fleet host).

This switch is not urgent. The old SDK differs only in `sdk/ge-actions.ts` (slots 0-5 instead of 0-11) and the webclient clip fix. The lite client and the protocol code are unchanged.

## Verify

```sh
bash linux-game-server/2004scape/world.sh status                    # world 1 healthy, image = the candidate
docker logs rs-sdk-server 2>&1 | grep -iE 'migrat|backup|error' | tail -20
curl -s http://127.0.0.1:8080/engine-status                          # status running; uptime counts from the start
curl -s 'http://127.0.0.1:8080/hiscores?category=0&profile=main' | grep -o 'Ranks [^<]*'
ls ~/games/rs-sdk/data/backups/                                      # the pre-migration backup
```

Then, in game:

- log in;
- open a bank and check the slot count;
- open the Grand Exchange at the Varrock west bank table and check the 12 slots;
- watch a few bots relog: the fleet resumes 2 minutes after the restart, staggered over another 2 minutes.

## Rollback

Progress since the promotion is lost. These are the same steps `promote --now` takes when the new image is unhealthy. Run them on the game server, in `~/github/Computer-Setup/linux-game-server`:

```sh
docker update --restart=no rs-sdk-server
docker stop -t 120 rs-sdk-server              # the engine logs everyone out and saves (v10)
# The data first: the old image refuses v10 saves.
docker run --rm --network none --entrypoint sh -v "$HOME/games/rs-sdk":/parent computer-setup/rs-sdk:rollback \
  -c 'set -e; cd /parent; rm -rf data.failed; mv data data.failed; cp -a data.pre-promote data'
docker tag computer-setup/rs-sdk:rollback computer-setup/rs-sdk:local
# The pin, so the next maintenance keeps the old image:
docker image inspect -f '{{.Id}}' computer-setup/rs-sdk:rollback > ~/.local/state/computer-setup/2004scape-maintenance/rs-sdk.image
docker compose --project-directory rs-sdk -f rs-sdk/docker-compose.yml up -d --no-build --force-recreate rs-sdk
bash 2004scape/world.sh status                # world 1 healthy on the old image
```

- **Fleet:** switch the SDK back (bot repo `docs/sdk-update-1599b86.md`, "Rollback").
- **Failed state:** `data.failed` keeps the post-promotion state for inspection. It is root-owned.
- **Never** run `world.sh promote computer-setup/rs-sdk:rollback --now` as a rollback. It would copy the v10 data over `data.pre-promote` first.
