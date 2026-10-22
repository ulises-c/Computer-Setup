# 2004Scape / RS-SDK companion

The RS-SDK Homepage card opens `https://<game-host>.<tailnet>.ts.net/rs-sdk/`
on the **Linux game server**. This is separate from vanilla Lost City; its
card and game client stay unchanged. The portal offers:

- **Account Database**: searchable bot account status, purpose, login counts and
  timestamps, and recorded death counts. It is not the game login database.
- **Benchmarks**: full-run success rates, successful best/average total times,
  paginated history including resume runs, routine hashes and per-step timings.
- **RS-SDK Wiki** (`/rs-sdk/wiki/rs-sdk`): searches only server-specific RS-SDK
  knowledge, stored in its own `rs-sdk-wiki.sqlite` snapshot.
- **Scraped Wiki** (`/rs-sdk/wiki/scraped`): searches only cached OSRS/RS3 pages,
  stored in a separate `scraped-wiki.sqlite` snapshot. Articles show attribution
  and original links, and warn that later game versions may differ.
- **Play**, **HiScores**, **Grand Exchange**, and a link back to Homepage.

`/rs-sdk/wiki` is a collection chooser, not a combined search. Each collection's
search, pagination, article links, back links and snapshot timestamp stay scoped
to its database. Both are linked directly from the companion and sidebar.

## Appearance

The companion, account registry and benchmarks use RS-SDK's Grand Exchange
palette: dark stone/foliage background, gold headings, parchment tables and
compact HiScores-style navigation. The installer fetches the existing game's
`/img/background2.jpg` once from its loopback web server into gitignored
`assets/`; the portal serves only that allowlisted image locally. No artwork
is committed, and browsers do not contact an external asset CDN.

The wiki uses an **OSRS/MediaWiki-inspired reader**, not a full MediaWiki
installation: light parchment article pages, a sidebar, section contents,
anchored headings, lists, tables and an initial infobox where the cached text
has one. It remains the same small Python service: no PHP runtime, extra
database service, extensions, editor or background worker. Only the cache's
escaped readable text is formatted; upstream HTML and scripts never run.
Images, templates, original hyperlink targets and other structure not preserved
in the cache's readable text are not reconstructed.

Account state is explicitly lifecycle metadata, not live presence. Current
online state and world/server are tracked as a follow-up in `docs/TODO.md`.

## Isolation and freshness

The web service runs in its own non-root, read-only container, published only on
`127.0.0.1:8098`; Tailscale Serve publishes `/rs-sdk` on the host's existing node.
There is no Funnel, additional tailnet node, or wildcard host listener. Anyone
permitted to reach that tailnet service can view its data; there is no separate
portal login. The viewer accepts no writes or SQL and serves no raw database
files, scripts or upstream wiki HTML. Wiki articles use escaped readable text.
It never fetches upstream pages, starts bots or restarts either game.

The authoritative bot account/benchmark and wiki databases remain on the source
Mac under `~/forgejo/2004Scape-Botting/data/` and
`~/forgejo/2004Scape-Wiki/data/`. A **source-side sync only** runs every 120 seconds
as a login-user LaunchAgent. No web service runs on the Mac. SQLite connections
are read-only, use short-lived consistent read transactions, and do not run
schema migrations, checkpoint WAL, invoke repository scripts, or commit Git.
Normal SQLite WAL coordination may create/update a source `-shm` sidecar; this
is not a promise of zero filesystem writes. It does not alter database rows or
repository source files. Live databases are never opened with `immutable=1` or
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
represent precisely the same instant. Existing readers finish on the old inode.

Sync publishes four files: `accounts.sqlite`, `benchmarks.sqlite`,
`rs-sdk-wiki.sqlite` and `scraped-wiki.sqlite`. The two wiki files are physically
separate database projections, not just views or UI filters. Export selects
`source = 'rs-sdk'` for the first and `source IN ('osrs','rs3')` for the second;
the receiver rejects a mislabeled collection before publishing any files. The
original combined `2004Scape-Wiki/data/wiki.sqlite` remains unchanged for the
active scraper/bots. An old portal-side `wiki.sqlite` is no longer read or
published; retain it outside the active data directory as a rollback copy when
upgrading. Sync never deletes an arbitrary `wiki.sqlite` from its target.

Every data view shows its export time and warns after ten minutes without an
update. If the Mac sleeps, logs out or loses SSH access, the portal stays on the
game server and shows the last successful snapshots. A LaunchAgent requires a
logged-in source user. Sync has a 90-second SSH timeout; failures leave prior
server snapshots available. The view has no auto-refresh; reload for new data.

## Install

Copy this directory to the game server's Computer-Setup checkout (or deploy the
branch), then, as the Docker-authorized login user on the **game server**:

```sh
bash linux-game-server/rs-sdk/portal/install.sh
```

This creates only the portal's private `.env` and snapshot directory, recreates its
separate Compose project, checks its loopback page and adds only the `/rs-sdk`
Serve route. It requires Docker/Compose, Python 3, and Tailscale operator access.
It reloads portal code/styles without touching either game or the full server
installer. The game web server must be reachable for the first artwork fetch. The existing
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
