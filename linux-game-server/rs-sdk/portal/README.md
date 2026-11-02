# 2004Scape / RS-SDK companion

The RS-SDK Homepage card opens `https://<game-host>.<tailnet>.ts.net/rs-sdk/`
on the **Linux game server**. This is separate from vanilla Lost City; its
card and game client stay unchanged. The portal offers:

- **Account Database**: searchable bot account status, purpose, login counts and
  timestamps, and recorded death counts. It is not the game login database.
- **Benchmarks**: full-run success rates, successful best/average total times,
  paginated history including resume runs, routine hashes and per-step timings.
- **2004Scape Wiki** (`/rs-sdk/wiki/2004scape`): a third, generated collection in
  `2004scape-wiki.sqlite`. It combines the rs-sdk reference wiki, bot observations
  (IDs, world coordinates and provenance), field guides and lazily cached OSRS
  excerpts selected by the canonical wiki's current deployment policy.
  Missing or expired automatic policies make wiki content unavailable, including
  previously generated rows with scraped facts. Pages have an infobox, contents,
  internal title links, references and a **Compact context** view (`?view=brief`) for agents.
  Reading one queues its missing OSRS article through the same wanted mechanism;
  it does not crawl linked pages.
- **RS-SDK Wiki** (`/rs-sdk/wiki/rs-sdk`): searches only server-specific RS-SDK
  knowledge, stored in its own `rs-sdk-wiki.sqlite` snapshot.
- **Scraped Wiki** (`/rs-sdk/wiki/scraped`): searches only canonical visible
  OSRS/RS3 context, stored in a separate `scraped-wiki.sqlite` snapshot.
  Articles show attribution and original links; raw modern documents never ship.
- **Live map** (`/rs-sdk/live-map`): everyone online in the game world (fleet
  bots flagged when they are in the world with no SDK controller, other players
  by name only) and every bot account on the game's own world
  map, with HP, combat level, skills/XP, inventory, equipment and current activity,
  refreshed every game tick (600 ms; `?ticks=N` changes it). See [Live map](#live-map).
- **Bot controller** (`/rs-sdk/bot-controller/`): the only page that changes
  anything. The owner assigns a registry routine per bot (or Stop / Hold), and the
  workstation's no-LLM controller daemon applies it. See [Bot controller](#bot-controller).
- **Play**, **HiScores**, **Grand Exchange**, and a link back to Homepage.

`/rs-sdk/wiki` is a collection chooser, not a combined search. Each collection's
search, pagination, article links, back links and snapshot timestamp stay scoped
to its database. All three are linked directly from the companion and sidebar.

## Appearance

The companion, account registry and benchmarks use RS-SDK's Grand Exchange
palette: dark stone/foliage background, gold headings, parchment tables and
compact HiScores-style navigation. The installer fetches the existing game's
`/img/background2.jpg` once from its loopback web server into gitignored
`assets/`; the portal serves only that allowlisted image locally. No artwork
is committed, and browsers do not contact an external asset CDN.

The wiki uses an **OSRS/MediaWiki-inspired reader**, not a full MediaWiki
installation: light parchment article pages, a sidebar, section contents,
anchored headings, lists, tables and an initial infobox. It remains one small
Python service: no PHP runtime, extra database service, extensions, editor or
background worker.

### Clean publication and legacy original renderer

Canonical publication exposes only clean projected text. It always writes
`raw_html = NULL`, `styles = '[]'`, and empty assets/redirects tables. Original
HTML, CSS, cached rasters and raw redirects stay on the wiki source. Neither
original-document routes nor image/hash routes can bypass the empty manifest,
even if old blobs remain on disk. No `export_assets` call runs on this path.

The renderer below remains for compatibility tests and policy-stamped snapshots;
it is **not** part of canonical publication. Old snapshots without policy are
never served, even if their modification time is recent. Republish them through
`export-visible`; do not stamp unfiltered legacy content by hand.

- The original is **untrusted**. `original.py` sanitizes it with nh3, parses
  CSS with tinycss2 and serves it from `/wiki/scraped/document` inside a frame
  whose sandbox allows no scripts, no same-origin access and no forms, under its
  own CSP (`default-src 'none'`, `img-src 'self'`, no form actions). Portal
  pages gain only `frame-src 'self'`, and only on the article route.
- Scripts, forms, SVG, media, frames, event handlers, `@import`, `@font-face`,
  custom properties and every CSS property outside a small allowlist are
  dropped. Only `@media` rules survive. Every `src`, `srcset` and CSS `url()` /
  `image-set()` under the wiki's `/images/` becomes
  `/rs-sdk/wiki/scraped/images/<source>/<path>` (the latest cached version, or a
  placeholder); other cached rasters are served by content hash, anything else
  is a placeholder. Rendering makes no upstream request.
- **Every wiki link is routed by title**, cached or not, so links come alive as
  pages get scraped: `/w/Title#Section` (and `/w/index.php?title=…`) on either
  wiki becomes `/rs-sdk/wiki/scraped/w/<source>/Title#Section`. Links to
  uncached pages get MediaWiki's red-link class. `article?id=N`, other spellings
  and cached redirect titles redirect to the canonical title URL. A section
  fragment can't scroll inside the frame (that would need scripts). Links to
  other sites are plain external links that open nothing until clicked (the
  sandbox blocks new windows, so they need a copy-paste).
- **Missing pages and images are requested, not fetched.** Opening an uncached
  article shows a "not scraped yet" page with the upstream link and records the
  title in `wanted.sqlite`; a missing image records its path. Non-article
  namespaces (`File:`, `Category:`, `Special:`, talk pages, …) are routed but
  never requested. The source-side sync takes these requests (below).
- Cached assets are only PNG, JPEG, GIF and WebP images and CSS, up to 8 MiB
  per image and 2 MiB per stylesheet. Interactive parts the site builds with scripts
  (price charts, maps, calculators, infobox version switching) do not work.
- Fidelity is deliberately conservative: because of the CSS allowlist, pages
  look close to, not identical to, the live wiki.

Account state is explicitly lifecycle metadata, not live presence. Current
online state and world/server are tracked as a follow-up in `docs/TODO.md`.

## Server-authoritative wiki

The preferred deployment keeps the scraper, store, both wiki databases, shared
rate limit and download queue **on the game server**. Client `bin/wiki` commands
forward over authenticated SSH; the sanitized web portal remains separate from
the scraper and never proxies the original wiki viewer. See
[the wiki runtime](../wiki/README.md) for user timers and input prerequisites.

On the server, publish the local wiki collections:

```sh
python3 linux-game-server/rs-sdk/portal/sync.py publish-wiki \
  --wiki-root ~/forgejo/2004Scape-Wiki \
  --target ~/.local/share/rs-sdk-portal/data --curated
```

This invokes `bin/wiki export-visible` once and consumes its JSON object
`{policy, pages}`. The canonical command rebuilds generated context internally;
there is no redundant `curate` invocation. Python validates the projection's
shape, sources, fields, size and the complete version-1 policy/metadata contract,
but does not duplicate historical classification or parse a build's README.
Missing commands, command failures and malformed projections abort publication
without a raw SQLite fallback.

Only fresh projected wiki snapshots are published; account/benchmark snapshots
are unchanged. Source databases and caches are not copied, scrubbed or deleted
by the publisher (the canonical command owns its normal curated rebuild).
Replacements are individually atomic, not a multi-file transaction.
Successful publication creates `data/.wiki-authority` under the receiver lock,
blocking legacy full uploads and remote `take-wanted`. Do not remove that marker
except during a deliberate rollback. It protects against stale clients, not a
malicious account that already owns the directory.

To deliberately publish another cutoff, pass `--as-of YYYY-MM-DD` to
`publish-wiki` or legacy non-account `push`; the canonical command validates it.
Without that flag the current deployment policy is used. `--as-of` is rejected
with `--accounts-only`. Changing dates requires republishing: no later content
is retained in portal snapshots for a client-side date toggle.

### Request-time policy gate and bounded staleness

Every new wiki snapshot, including generated `2004scape` pages containing scraped
facts, stores its canonical policy in a singleton `wiki_policy (policy TEXT NOT
NULL)` table. The JSON policy and pages are committed in the **same SQLite
transaction** and replaced together in the same database file: no policy sidecar
can disagree with its pages. The receiver validates the optional table's exact
columns/type, singleton row, policy modes/dates, deployment metadata and lifetime
before installing any files. Legacy schema helpers and unmarked uploads remain
compatible, but an unmarked database is **never eligible to serve wiki content**.
Account-only uploads neither need nor modify wiki policy.

Each wiki read checks policy using the same read transaction as its content.
Automatic policies require a valid effective date matching deployment metadata,
no override, fresh status, a non-future observation and a strictly valid UTC
`expiresAt`. Expiry cannot exceed the observation plus **10 minutes**, and access
stops at the expiry instant, independently of file mtime or successful later
publication. Missing, malformed, unknown or expired policies fail closed across
search, articles, generated compact context, original documents, images and
hash-addressed assets. Wiki HTML and asset responses use `Cache-Control: no-store`
so new browser caches cannot extend access beyond the gate. The collection chooser,
accounts, benchmarks and the portal's decorative background remain available.

The producer normally observes the running build every **2 minutes** and the
publisher runs every **5 minutes**. This is bounded staleness, **not instant
running-game detection**: after a build change or metadata failure, a previous
automatic snapshot can remain visible only until its embedded expiry, at most
10 minutes after its last successful build observation. A successful publication
may replace it earlier. Failed metadata refresh/publication preserves the old
files without renewing their policy; once expired they stay unavailable until a
healthy policy-stamped publication arrives. Take wiki serving offline during a
build transition if even that residual interval is unacceptable. Already downloaded
content and browser caches created by older portal versions cannot be revoked.

An explicit `--as-of` publication must return a matching `override` policy and
valid calendar cutoff. Search and article views label it **Date-preview override**,
not the automatic deployment cutoff. This deliberate preview remains available
independently of missing/expired deployment metadata; it is not advertised as
fresh deployment knowledge. Changing or leaving preview mode requires republishing.

Wanted requests are passed to the server's `bin/wiki want` and deleted only after
that command succeeds; failed commands leave them queued. `--wanted PATH`
overrides the default `TARGET/../wanted/wanted.sqlite`.

The Mac still owns bot-account and benchmark data. Its separate job must use:

```sh
python3 linux-game-server/rs-sdk/portal/sync.py push --host <game-server-ssh-alias> --accounts-only
bash linux-game-server/rs-sdk/portal/install-sync.sh <game-server-ssh-alias> --accounts-only
```

Account-only uploads contain exactly two snapshots and cannot overwrite wiki
snapshots or assets. They never open Mac wiki databases, scrape, curate or take
wanted requests. Curated observation/guide inputs originate with the bots and
are uploaded separately; these are not scraped wiki copies. The account-only
LaunchAgent enables this allowlisted upload with `--bot-inputs`; manual pushes
can opt into it with the same flag.

## Legacy full-sync isolation and freshness

The web service runs in its own non-root, read-only container, published only on
`127.0.0.1:8098`; Tailscale Serve publishes `/rs-sdk` on the host's existing node.
There is no Funnel, additional tailnet node, or wildcard host listener. Anyone
permitted to reach that tailnet service can view its data; there is no separate
portal login. The viewer accepts no SQL and serves no raw database files or
scripts. Its only write is the request list: `/wanted/wanted.sqlite`, a separate
writable bind of `~/.local/share/rs-sdk-portal/wanted/` (700), holding at most
5,000 deduplicated `(source, page|image, title|path)` rows validated against the
same title and path rules as rendering; recording failures never break a page. Clean articles use escaped readable text; original articles
are sanitized and sandboxed as described above. It never fetches upstream pages
or assets, starts bots or restarts either game.

In legacy full-sync deployments, source data lives under
`~/forgejo/2004Scape-Botting/data/` and `~/forgejo/2004Scape-Wiki/` on the Mac.
The default source-side LaunchAgent runs every 120 seconds. No web service runs
on the Mac. Account/benchmark export uses read-only, short-lived SQLite read
transactions; normal WAL coordination may update `-shm` sidecars. Wiki data
comes exclusively from `bin/wiki export-visible`, never raw SQLite queries.

After publishing, sync runs `sync.py take-wanted` on the server, which removes
and returns up to 100 oldest requests. It validates them again and pipes them
as JSON lines to the wiki's own `bun src/cli.ts want` in `2004Scape-Wiki`, the
wiki queue command. The wiki puts requested images at the front
of its image queue and requested articles (at most 100 waiting) in a page queue
that its page worker fetches with their images and stylesheets, at the wiki's
shared rate limit, committing as usual. A requested page appears after the next
sync once fetched, typically a few minutes. Requests taken while the wiki can't
queue them are dropped; opening the page again re-requests it. Live databases are never opened with `immutable=1` or
copied without SQLite coordination, which would risk an inconsistent view.

`sync.py` creates **new projected databases**, copying only explicit allowlisted
columns. Account passwords, private notes, machine/server addresses, benchmark
error fields, and death context never enter the snapshot. Benchmark step JSON
is projected again to a text step label and numeric ms/ticks; nested error or
context fields are discarded before anything is written to the snapshot. Purpose, account
names, routine hashes, step labels and wiki text are intentionally visible;
do not put secrets in these displayed fields. Snapshots are streamed over SSH,
validated as a complete set, and individually atomically replaced under
`~/.local/share/rs-sdk-portal/data/` (directory 700, files 600). They are disposable
views, not backups, and do not need restic coverage. Separate databases need not
represent precisely the same instant, and a crash between file replacements can
leave a mixed set until the next sync. Existing readers finish on the old inode.

The legacy receiver still validates original-asset archives for compatibility,
including hashes, MIME, sizes, archive paths and symlink restrictions. New
`publish-wiki` and non-account `push` send **no original asset blobs**, and empty
assets/redirects manifests. The receiver's archive security checks are unchanged.

By default a full push publishes four files: `accounts.sqlite`,
`benchmarks.sqlite`, `rs-sdk-wiki.sqlite` and `scraped-wiki.sqlite`. Wiki snapshots
are physically separate canonical projections, not UI-only filters. The
receiver rejects mislabeled collections before replacing files.

`--curated` includes the optional fifth file, `2004scape-wiki.sqlite`, containing
only source `2004scape`. Its `text` is canonical `wikitext`, `brief` is canonical
`text`, and `categories` labels page kinds. This flag controls snapshot inclusion
only: canonical export always prepares generated context. Upgrade receivers
before enabling it. A successful wiki publication **removes any previously
published optional snapshot if omitted**, rather than leaving stale unfiltered
content accessible. Account-only pushes never remove or alter wiki files.

The raw combined wiki database and cached originals remain source-side for the
scraper. Canonical export owns its curated generation and policy; publication
never starts a bot or issues gameplay actions.

An old portal-side `wiki.sqlite` is no longer read or
published; retain it outside the active data directory as a rollback copy when
upgrading. Sync never deletes an arbitrary `wiki.sqlite` from its target.

Every data view shows its export time and warns after ten minutes without an
update. Account/benchmark views retain their last successful snapshots if the
source goes offline; automatic wiki snapshots instead become unavailable at their
embedded policy expiry. A LaunchAgent requires a logged-in source user. Sync has
a 90-second SSH timeout; failures never renew prior wiki policy. The view has no
auto-refresh; reload for new data.

## Live map

```
bot workstation                                   game server
live_publish.py --host <alias> ──ssh stdin──▶ live.py receive ─▶ ~/.local/share/rs-sdk-portal/live/live.json
  GET game web /playerpositions  (allowlist re-shape,                  │ (read-only mount /live)
  GET gateway /status
  GET gateway /state/<bot>        server-clock stamp,                  ▼
  ps (routines), fleet-state      atomic replace)        portal: /rs-sdk/api/live, /rs-sdk/live-map
  bot_journal/activity/*.json
```

- **Data source.** The gateway already holds every connected bot's latest
  `BotWorldState`, but `/state/<bot>` needs that bot's SDK password, and those
  exist only on the bot workstation (`<rs-sdk>/bots/<bot>/bot.env`). So the
  publisher runs there: per period it reads the unauthenticated `/status` once,
  then `GET /state/<bot>` (Bearer header) only for connected bots — at most one
  request per bot per 3 s, plain HTTP reads, no WebSocket session, observer,
  controller or action, so it can't pre-empt or block a fleet run. Credentials
  are used only in request headers; snapshots never contain them.
- **Presence.** The gateway only knows bots with a connected SDK client, but a
  bot can stay in the world after its client dies. So each period the publisher
  also reads the game web server's unauthenticated `GET /playerpositions`
  (`https://` + `SERVER` from `bot.env`, or `--world URL`; one request, the list
  of every player in the world) and matches names to accounts (`bot_moondrop` ↔
  `Bot Moondrop`: case, spaces and underscores ignored; the state's display name
  is preferred). Each account gets `presence`:
  - `controlled` — SDK client connected and in game;
  - `ghost` — **in the world with no controller** (gateway dead/absent). The page
    shows a red banner with the count and names, an amber pulsing marker and an
    amber badge. Its position is live (from the world list); skills, HP,
    inventory and equipment are the last controlled snapshot's, marked
    last-known with their age (kept in
    `~/Library/Caches/computer-setup/rs-sdk-portal-live.json`, allowlisted, so
    they survive publisher restarts);
  - `offline` — not in the world;
  - `unknown` — no client, and the world list was unreachable: the page says
    ghosts can't be detected right now instead of calling them offline.
  Other players in the world (humans) are shown as neutral markers and cards,
  name, position and nearest town only. The status line reads `Online in world: N` (the length
  of `/playerpositions`, i.e. `/playercount`). Accounts in `accounts.sqlite` that
  the publisher has no credentials for but that are in the world are shown as
  ghosts too.
- **What is published** (allowlist in `live.shape_bot`, applied by the publisher's
  reduction, again by the receiver and again by the portal): position/plane, HP,
  combat level, run energy, animation, combat target name, skills (level, base,
  XP), inventory and equipment (id, name, count), the last few *system* game
  messages (never other players' chat), XP gained per skill in the last minute
  and XP/hour over the last five minutes, the local routine name and plain
  arguments (`eval` snippets are dropped), the routine's own status, the fleet
  supervisor's lock/focus latch and per-bot lifecycle phase, recent animation and
  movement, and whether a level-up dialog is open (skill name only).
- **Activity** combines three sources into `activity.label` plus structured
  fields the page shows under each bot:
  1. *Routine status* — routines publish `bot_journal/activity/<bot>.json` through
     `routines/lib/activity-status.ts` in 2004Scape-Botting (routine, phase such
     as `walking to bank` / `mining tin` / `banking`, detail, counts like trips
     and ores banked, start and phase times, last random event, stop reason); the
     supervisor adds `<bot>.fleet.json`. A `running` status whose process is gone
     is shown as `ended`.
  2. *Animation* — `player_anims.py` maps the player's animation id to a named
     action (Mining, Woodcutting, Fishing, Cooking, Smithing, Firemaking,
     Attacking, Casting a spell, Eating…), from the game's `seq.pack`
     (`gen_player_anims.py` regenerates it). The SDK only reports the primary
     animation, so walking/running come from movement between frames, and the
     last animation is remembered for 15 s.
  3. *XP flow* — per-skill XP/hour over up to five minutes (shown once a skill
     gained XP in the last minute).
  Order: offline/dead, fleet focus, level-up/dialog, routine phase (or the bare
  routine process, or the supervisor phase), what the frames show (combat,
  animation action, walking/running/teleported) unless the phase already says
  it, XP rate, else idle.
- **Filter and cards.** A segmented `All / Bots / Players` control (with counts)
  filters both the cards and the map markers; the ghost banner always shows. The
  choice is kept in `localStorage` and in the URL (`?show=all|bots|players`);
  the URL wins, so filtered links work. Cards are collapsed by default to a
  uniform summary (name, presence, combat level, HP, activity, nearest town and
  position); each bot card has a *Details* button (`aria-expanded`) for the
  routine detail, skills, inventory, equipment and messages, plus *Expand all /
  Collapse all*. The expanded set lives in `sessionStorage`, and cards are
  updated in place on every refresh so expansion, focus and scroll survive it.
- **Freshness.** The receiver stamps snapshots with the server clock; the API
  marks data stale after 3 publish periods, but never sooner than 12 s (so an
  SSH hiccup at the per-tick rate is not flagged), and the page says so.
  Offline accounts from `accounts.sqlite` (not retired) are listed too.
- **Refresh rate.** The page polls `/rs-sdk/api/live?ticks=N` every N × 600 ms
  (default 1 = every game tick, `?ticks=N` on `/rs-sdk/live-map`, 1–1000; the
  next poll starts only after the previous one finished). The publisher's own
  period is `install-live-publisher.sh <alias> [TICKS]` (default and minimum 1);
  polling faster than the publisher only re-reads the same snapshot. To fit a
  tick, the publisher reads the connected bots' `GET /state` concurrently on a
  bounded pool (12 workers, per-request timeout 0.8 × period, at least 0.5 s),
  reads `/status` and `/playerpositions` once per period and the fleet
  service's activity cards at most every 5 s. Snapshots run on tick
  boundaries, one at a time; one that overruns starts the next at once. The
  gateway still sees one read per bot per period, now every 600 ms. Movement (still/walking/
  running/teleported) is judged over the frames' last 3 game ticks by their
  own tick counter, and XP history keeps one sample per 3 s, so both are
  independent of the period. The bot controller page keeps its own 3 s poll.
- **Map.** `install.sh` renders `assets/worldmap.png` (2 px/tile) and
  `assets/worldmap.json` (labels) from the game server's own `/worldmap.jag` with
  `worldmap.py`, a port of the web client's MapView ground layer on the same
  unified canvas (dungeon bands folded in); delete both files to re-render.
- **CSP.** `/rs-sdk/live-map` is the only page allowed `script-src 'self';
  connect-src 'self'`; its script is the static `/rs-sdk/live-map.js`.

Install the publisher on the bot workstation (copies `live_publish.py` to
`~/Library/Application Support/computer-setup/rs-sdk-portal/` and loads a
KeepAlive LaunchAgent; logs in `~/Library/Logs/computer-setup/rs-sdk-portal-live.log`):

```sh
bash linux-game-server/rs-sdk/portal/install-live-publisher.sh <game-server-ssh-alias> [TICKS]
python3 linux-game-server/rs-sdk/portal/live_publish.py --once   # one snapshot to stdout
```

Cards from the other bot hosts need the fleet service URL
(`https://<game-server>.<tailnet>.ts.net:9447`) in `~/.config/rs-fleet/url` and the
`portal:ro` token in `~/.config/rs-fleet/portal-token` (both mode 600); without
either, the map shows this workstation's bots only.

## Bot controller

`/rs-sdk/bot-controller/` lists every fleet bot and the owner's regular accounts (the
`player.sh` profiles the daemon reports, by in-game name only), filtered All / Bots /
Regular (`?show=bots|regular`, remembered), each with:

- presence and activity, from the live snapshot;
- the controller daemon's per-bot state and message, its job, last result, gates
  (fleet pause / per-bot latch / local stop: read-only here) and any other controller
  driving the bot;
- the owner's current request;
- the live, sanitized tail of the job log (headless runs);
- the **game view** (browser-view runs): the real game client from
  `https://$PORTAL_GAME_DOMAIN:9445/bot?bot=NAME[&password=…]` in an iframe. It is the
  account's only client; the session lives only while the page stays open.

Per account, or in bulk (headless only) for the selected accounts, the owner can:

- **Start** a routine from the registry, with dropdowns for enum args and bounded
  numbers for ints, headless or in the browser view (session routines, one account);
  regular accounts get only the registry's `allowPlayers` routines;
- **Stop** it (headless: a real in-game logout, verified on `/playerpositions`;
  browser view: the routine stops, the game view keeps the session);
- **Hold** it (hands off);
- **Clear** the request.

Cards collapse/expand like the live map and keep their form values across refreshes.

Data flow: the portal writes only desired state. The daemon on the bot
workstation (`2004Scape-Botting/tools/bot-controller.ts`, launchd
`net.computer-setup.rs-sdk-bot-controller`; docs in that repo's
`docs/bot-controller.md`) does the work. Every ~5 s it runs
`ssh <game-server> python3 …/portal/controller.py exchange`. That call:

- stores the daemon's status, allowlisted, as `$PORTAL_LIVE_DIR/controller-status.json`
  (read-only in the container);
- writes the fleet and regular account browser-view login bundles (`frames`, each containing revision,
  username and password from the daemon) to `$PORTAL_LIVE_DIR/controller-frames.json` (mode 600,
  read-only in the container), never into the status. The endpoint uses the username and password
  from the same validated bundle, matches its revision to the current request, and rejects older
  entries without a username; mixed protocol versions cannot auto-login;
- prints `$PORTAL_CONTROLLER_DIR/desired.json` back to the daemon.

The daemon's report includes the routine registry. The portal validates requests
against it, and the daemon validates them again against its own copy. The daemon also
applies every safety gate itself. The heartbeat on the page goes red after 30 s
without a report.

Writes (`POST /rs-sdk/api/controller/desired`) require all of these:

- the owner's Tailscale identity. `tailscale serve` sets `Tailscale-User-Login` and
  overrides a client-supplied value; tagged devices get none. The allowed login is
  `PORTAL_OWNER_LOGIN` in `.env`: `install.sh` keeps it, or pass
  `PORTAL_OWNER_LOGIN=… install.sh` once; empty means read-only;
- an `Origin` of `https://$PORTAL_GAME_DOMAIN`;
- a JSON body;
- an HMAC CSRF token, issued only to the owner's GET.

The game-view URL (`POST /rs-sdk/api/controller/frame`, `{account}` -> `{url}`) needs the
same five checks. Fleet bots get their login filled in (owner decision) only while a
browser-view run is requested; regular accounts get the client's login screen. It is
refused while the daemon reports a headless client for the account, never logged (the
audit records `frame` + account), and the public JSON never carries a password.

Requests are validated against the registry and the known accounts, rate-limited to
30 changes per minute, and audited in `$PORTAL_CONTROLLER_DIR/audit.jsonl`.
`bot_tester` is never launchable. There are no free-form commands. Residual risk:
local access to the game server (loopback port, or the controller directory), and
any process on the owner's own untagged devices.

The page has the same CSP exception as the live map
(`script-src 'self'; connect-src 'self'`) plus `frame-src https://$PORTAL_GAME_DOMAIN:9445`
(the game client only); every other route is unchanged. Tests:
`test_controller.py` covers registry and run validation, status shaping, auth/CSRF,
the store, the HTTP routes and the JS logic.

## Central bank

`/rs-sdk/central-bank/` shows what the fleet's central bank account holds and lets the owner
decide per item: **Sell**, **Keep** (default) or **Alch**. Producers hand their surplus finished
items (today the smith's products) to that account; it passes the items marked Sell to the trader
bots, who sell each kind at the shop that pays best (the general store or a specialty shop that
stocks it). **Alch is a placeholder:** no bot alchs yet and nature runes are not buyable by the
fleet, so the bots treat Alch exactly like Keep until an alcher exists. Design and roles: the bot
repo's `docs/central-bank.md`; shop prices: its `docs/economy.md`.

The page shows:

- the bank account's state (receiving at its hub or not, heartbeat age, when its bank was last
  counted, coins) and a warning when the workstation's data is older than 60 s;
- the item table, black text on a light sheet, one row per item: icon and name (a link to the
  item's page on this portal's 2004Scape wiki, new tab), count, value each and in total, the buy
  price (what a shop charges at its normal stock = the value), **best sell now** (the best shop on
  the merchant's route and its offer for one unit at that shop's current stock; the tooltip names
  a better shop off the route, e.g. Taverley's two-handed sword shop), low and high alch (gross,
  plus the value net of the runes per cast at shop prices), kind, and a Sell / Keep / Alch toggle
  with when the decision was made; column headers sort (default: value, high first) and carry
  tooltips; a change shows as *pending* until the workstation has applied it, and a rejected change
  (someone else changed the item since the page loaded) is reported at the top; All / Sell / Keep /
  Alch filters with counts and a total value line;
- the traders (state, stock to sell, coins), their recent sales (item, price, shop) with per-item
  totals, and the bank's recent handovers in and out.

**Icons** are the wiki's own inventory pictures: the exchange (below) copies each listed item's
`<Name>.png` from the game server's wiki image cache (`~/forgejo/2004Scape-Wiki/images/osrs`,
`--wiki-images`; a PNG under 64 KiB, checked) into `$PORTAL_LIVE_DIR/item-icons/`, and the portal
serves them at `/rs-sdk/central-bank/icons/<Name>.png` (same origin, so the page CSP stays
`img-src 'self'`). An icon the cache lacks is recorded as a wanted wiki image, the same lazy queue
the scraped wiki uses; the row shows the item's initial until it arrives.

Data flow (the bot controller's pattern): the portal writes only the owner's pending edits,
`$PORTAL_CONTROLLER_DIR/central-bank-wanted.json` (+ `central-bank-audit.jsonl`). The bridge on the
bot workstation (`2004Scape-Botting/tools/central-bank.ts bridge`, launchd
`net.computer-setup.rs-central-bank-bridge`) runs every ~10 s
`ssh <game-server> python3 …/portal/central_bank.py exchange`, which:

- stores the bridge's status, allowlisted, as `$PORTAL_LIVE_DIR/central-bank-status.json`
  (read-only in the container): holdings, values, prices, marks, traders, sales, edit results,
  and copies the item icons;
- prints the pending edits back. The bridge applies them to the fleet service's designations doc
  (compare-and-swap on the doc version, plus a per-item check against the mark the page showed) and
  reports the applied revision in its next status, which retires the edits here.

Writes (`POST /rs-sdk/api/central-bank/designation`, `{item, policy, expectAt}`) need the same
owner identity, origin, JSON body and CSRF token as the controller, only for items in the bank's
list, rate-limited to 60 per minute and audited. The page has the live map's CSP exception
(`script-src 'self'; connect-src 'self'`) and no frames. Tests: `test_central_bank.py` (status
shaping, the store, the exchange and icon copy, the HTTP routes and the JS logic).

## Install

Copy this directory to the game server's Computer-Setup checkout (or deploy the
branch), then, as the Docker-authorized login user on the **game server**:

```sh
bash linux-game-server/rs-sdk/portal/install.sh
```

This creates only the portal's private `.env` and snapshot directory, recreates its
separate Compose project, checks its loopback page and adds only the `/rs-sdk`
Serve route. It requires Docker/Compose, Python 3, and Tailscale operator access.
It builds a small local image with the portal's two pinned dependencies (nh3,
tinycss2) and recreates only the portal container, without touching either game
or the full server installer. The game web server must be reachable for the first artwork fetch. The existing
host timezone file is reused, generating it only when absent. Watchtower is
disabled for this container. To update Python, recreate this portal deliberately.
The Serve route is also recorded in `linux-game-server/serve.conf` for subsequent
host route provisioning; the optional portal has its own installer, not an
unconditional entry in the fleet's Compose startup list.

On the **source Mac**, from this checkout, using an existing game-server SSH
alias and non-interactive key authentication:

```sh
python3 linux-game-server/rs-sdk/portal/sync.py push --host <game-server-ssh-alias>
bash linux-game-server/rs-sdk/portal/install-sync.sh <game-server-ssh-alias>
```

The receiver defaults to the remote path
`github/Computer-Setup/linux-game-server/rs-sdk/portal/sync.py` relative to the
remote login home. A manual sync accepts `--receiver` for a different checkout.
The installed default LaunchAgent uses the standard checkout and source paths.
No credentials are stored in the plist. Logs are in
`~/Library/Logs/computer-setup/rs-sdk-portal-sync.log`.

Generate Homepage's config with `python3 server-base/homepage/generate.py` and
hit Homepage's `/api/revalidate` after deploying its source and generated YAML.
Only the RS-SDK card's link changes; all metrics and the Lost City card remain.

## Verify and stop

```sh
python3 -m unittest discover -s linux-game-server/rs-sdk/portal -v
shellcheck linux-game-server/rs-sdk/portal/install.sh linux-game-server/rs-sdk/portal/install-sync.sh
```

After upgrading, rebuild/recreate the **portal only** with `install.sh` so its
image includes `snapshot_policy.py`, and upgrade the receiver before publishing
the new table. This is a required code/image update, not just a snapshot copy.
Publish fresh stamped snapshots before expecting wiki routes to return content;
unmarked legacy files intentionally return unavailable. Account-only sync is
unchanged. The installer also maintains the `wanted/` mount and
`PORTAL_WANTED_DIR`; the legacy source Mac needs `bun` on the LaunchAgent's `PATH`
for requests to reach the wiki.

On the game server, inspect `docker logs rs-sdk-portal`, check the snapshots'
mtime and permissions, and fetch `/rs-sdk/accounts`, `/rs-sdk/benchmarks`,
`/rs-sdk/wiki/rs-sdk` and `/rs-sdk/wiki/scraped` through the tailnet URL. Verify
each snapshot's distinct `pages.source` values match its collection. Check the main game's container ID and
start time remain unchanged. Use `docker compose --project-name rs-sdk-portal
-f linux-game-server/rs-sdk/portal/docker-compose.yml down` to stop just this
portal; remove its route with `tailscale serve --https=443 --set-path=/rs-sdk off`.
On the source Mac, stop its sync with
`launchctl bootout gui/$(id -u)/net.computer-setup.rs-sdk-portal-sync` and remove
that label's plist from `~/Library/LaunchAgents/` to prevent future login loading.
