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
anchored headings, lists, tables and an initial infobox. It remains one small
Python service: no PHP runtime, extra database service, extensions, editor or
background worker.

### Original and clean views (Scraped Wiki only)

When the cache holds a page's original article HTML, Scraped Wiki articles open
in an **original view**: the site's own article markup, its cached stylesheets
and its cached images, with a **Clean view** link to the readable-text reader.
Pages cached before the source stored original HTML, and the RS-SDK Wiki, show
only the clean view.

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

## Isolation and freshness

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

The authoritative bot account/benchmark and wiki databases remain on the source
Mac under `~/forgejo/2004Scape-Botting/data/` and
`~/forgejo/2004Scape-Wiki/data/`. A **source-side sync only** runs every 120 seconds
as a login-user LaunchAgent. No web service runs on the Mac. SQLite connections
are read-only, use short-lived consistent read transactions, and do not run
schema migrations, checkpoint WAL, or commit Git.
Normal SQLite WAL coordination may create/update a source `-shm` sidecar; this
is not a promise of zero filesystem writes. Exporting does not alter database
rows or repository source files.

After publishing, sync runs `sync.py take-wanted` on the server, which removes
and returns up to 100 oldest requests. It validates them again and pipes them
as JSON lines to the wiki's own `bun src/cli.ts want` in `2004Scape-Wiki`, the
one repository command it invokes. The wiki puts requested images at the front
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

Original HTML and stylesheet references travel in `scraped-wiki.sqlite`
(`pages.raw_html`, `pages.styles`) with an `assets` manifest (source, URL,
SHA-256, MIME, size) and the wiki's `redirects` (source, from and to title), so
links to a redirect title open the cached target. A receiver accepts snapshots
without `redirects` from an older sender. The blobs themselves live in `assets/<sha256>` beside the
snapshots. The sender asks the receiver which hashes it holds and sends only
missing blobs, so the growing image cache is not recopied every two minutes. The
sender reads the wiki cache's files without following symlinks, accepts only
structurally valid rasters and CSS within size limits and skips files that are
incomplete or still downloading; the receiver re-verifies every hash, MIME and
size, holds a lock for the whole receive, and installs blobs before snapshots.

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

After upgrading, rerun `install.sh` on the game server (it adds the `wanted/`
mount and `PORTAL_WANTED_DIR`); the source Mac needs `bun` on the LaunchAgent's
`PATH` for requests to reach the wiki.

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
