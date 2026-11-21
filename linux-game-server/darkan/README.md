# Darkan server

[Darkan](https://darkan.org) is an open-source 2012 (client build 727)
RuneScape emulator. This stack runs our own lobby, one world and their
MongoDB on the game server. It follows the same pattern as
[`../rs-sdk`](../rs-sdk/README.md): a clean upstream checkout, pinned to one
commit, is built into a local image together with this directory's layer. State
lives outside the checkout. Nothing here publishes Docker ports.

| Repo | Role |
| --- | --- |
| [`darkanrs/server`](https://gitlab.com/darkanrs/server) | Upstream: core, lobby and world. Checked out at `DARKAN_SOURCE_DIR` and pinned by `DARKAN_SOURCE_REF`. |
| [`darkanrs/cache-unpacked`](https://gitlab.com/darkanrs/cache-unpacked) | The unpacked 727 cache (about 5 GB). The `cache-source` submodule, pinned by the server commit. |
| [`ulises-c/darkan-server`](https://gitlab.com/ulises-c/darkan-server) | Our fork (private), for changes to the server. Remote `origin` in a workstation clone, with `upstream` pointing at `darkanrs/server`. |
| [`darkanrs/client-loader`](https://gitlab.com/darkanrs/client-loader/-/releases) | The official launcher that players use. Not built here. |

## Install

```sh
bash linux-game-server/darkan/setup.sh      # .env, checkout, cache, image; starts nothing
bash linux-game-server/darkan/activate.sh   # UFW (tailnet only), port checks, compose up --wait
```

`setup.sh` is idempotent and deterministic:

- It creates `.env` from `.env.example` with mode 600. It fills in only the
  blank values: `DARKAN_UID`/`GID`, `DARKAN_LOBBY_OWNER` (the user that runs
  it), the four secrets from `openssl rand -hex 32`, and `DARKAN_PUBLIC_HOST`
  (this host's Tailscale DNS name, set only while the placeholder is still
  there).
- It clones `DARKAN_SOURCE_URL` if the checkout is missing. It refuses a
  checkout that has a different origin or local changes. It checks out
  `DARKAN_SOURCE_REF` detached; this must be a full commit id.
- It points the `cache-source` submodule at `DARKAN_CACHE_SOURCE_URL`, because
  the upstream URL is relative and would resolve against a fork. It then
  fetches the commit that the server pins, at depth 1.
- It creates `DARKAN_DATA_DIR/{mongo,lobby,lobby/cache,world}` with mode 700,
  checks the compose file, builds `computer-setup/darkan:local` and pulls the
  pinned Mongo image.

To update, change `DARKAN_SOURCE_REF` in `.env.example` and in `.env`, run
`setup.sh`, then run `docker compose ... up -d`. The world gives no countdown,
so stop it while nobody is online. Do not use `AUTO_UPDATE`: it pulls the
upstream CI jars and needs a GitLab token.

## Services

All three services use host networking, run as the host user, drop all
capabilities and load `server-base/timezone.env`. Watchtower is disabled for
all three.

| Service | Port | Exposure | Notes |
| --- | --- | --- | --- |
| `darkan-mongo` (`mongo:7.0.45`) | 27027 | `127.0.0.1` only, `--auth` | Databases `darkan-lobby` (accounts, clans) and `darkan-world-<id>` (players, hiscores, GE, logs) |
| `darkan-lobby` | 43620 game/JS5, 4040 API | game: tailnet; API: `127.0.0.1` only | Packs `cache-source` into `lobby/cache` on the first start (a few minutes), then serves it from memory |
| `darkan-world` | 43621 | tailnet | Reads the lobby's packed cache read-only. Joins the lobby over `ws://127.0.0.1:4040/social/ws` with the private gateway token |

- **The world.** It is world `DARKAN_WORLD_ID` (1), at 1× XP, with members on.
  `WORLD_BOTS_ALLOWED=true` sets the world-list flag that lets the Darkan
  client's built-in bot feature (KotlinScript,
  [`darkanrs/bot-scripts`](https://gitlab.com/darkanrs/bot-scripts)) run here.
  This is Darkan's equivalent of the RS-SDK bot gateway. Headless `" Bot"`
  logins from the IPs or CIDRs in `DARKAN_BOT_IP_WHITELIST` get the
  passwordless bot profile.
- **Owner account.** The in-game account that has the same name as
  `DARKAN_LOBBY_OWNER` is the only one that can run the owner-tier lobby
  commands (`::changepassother`).
- **The image.** The build copies only the Gradle inputs and
  `cache-source/gamevals` from the checkout; the multi-GB tree is never sent to
  the builder. At runtime the tree is bind-mounted read-only. The image's
  `data/world.json` is a symlink into the world's state directory.

## Private by default

Only devices on the tailnet can join. This is stricter than the RS-SDK and
Lost City stacks, which also open their web ports to the LAN.

- **Tailnet.** `activate.sh` adds UFW allow rules for 43620 and 43621 on
  `tailscale0` only. It refuses to start while any rule allows one of the
  four ports on another interface. The world list advertises the tailnet DNS
  name, so a LAN rule would not help a client anyway.
- **Tailscale and UFW.** Tailscale's own netfilter rules (`NetfilterMode`
  on) accept tailnet traffic before UFW sees it. Every port bound to a
  wildcard address on this host is therefore reachable from the whole
  tailnet, whatever UFW says. Restrict who can reach the host with the
  tailnet ACLs.
- **Lobby API.** The image binds the admin API to `127.0.0.1`. Upstream
  binds it to every interface, so the build patches `Lobby.kt`, and the build
  fails if upstream changes that line. Mongo binds to `127.0.0.1` and
  requires a password.
- **Not public.** Nothing is forwarded through Tailscale Serve, Funnel or the
  router. The world joins only this lobby: `SOCIAL_GATEWAY_URL` is local and
  the gateway token is a generated secret, so it never appears in darkan.org's
  dev lobby. `DEBUG=false` also makes this lobby refuse community worlds.
- **Accounts.** Anyone who can reach the lobby can create an account. The
  tailnet boundary is the only gate. There is no login allowlist like RS-SDK's
  test-world allowlist.

The Homepage card's **Access** row checks the API listener on every refresh.
It shows `API EXPOSED` if the listener is bound to anything other than
loopback.

## Homepage card

The **Darkan: 2012 server** card (`../homepage/services.local.yaml`) reads
`darkan-status.json`, which `../2004scape/game_status.py` writes every 15 s
(the existing `2004scape-status.timer`, served by the loopback nginx on 8097).
Its rows are:

- the world's state and the lobby and Mongo health;
- the pinned upstream commit and the image build time;
- the rules (XP, drops, bots);
- CPU and memory over 24 h, from the same sampler as the other cards;
- players online (the lobby's `/worldlist`);
- accounts and player saves (counted inside `darkan-mongo` with its own
  credentials, so no secret is read);
- data sizes;
- the access check.

## Play

1. Install the launcher from `darkanrs/client-loader` releases.
2. Under **Lobby**, pick **Custom lobby…**. Enter `DARKAN_PUBLIC_HOST` and port
   `43620`.
3. Create an account. Accounts exist only on this lobby. Then pick world 1.

The world list advertises `DARKAN_PUBLIC_HOST:43621`, so a client must be able
to reach that name. Tailscale Serve is not used, because both connections are
raw TCP.

## Operations

```sh
c=(docker compose --project-directory linux-game-server/darkan -f linux-game-server/darkan/docker-compose.yml)
"${c[@]}" ps
"${c[@]}" logs --tail=100 darkan-world
curl -s http://127.0.0.1:4040/health; curl -s http://127.0.0.1:4040/worldlist
```

The card shows `not in the backup set`: backups are not wired in yet. When they are, take a `mongodump` of both
databases plus `world/world.json`. `lobby/cache` can be rebuilt.
