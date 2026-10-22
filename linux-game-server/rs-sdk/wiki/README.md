# Server-authoritative wiki runtime

Run this installer **on the game server as the regular service user**. It manages
only two user timers; it never restarts a game or the portal, uses sudo, installs
packages, clones repositories, imports references, or fetches LFS objects.

## Prerequisites and ownership

- Native `bun` and `git-lfs` already installed, with an executable wiki checkout
  at `~/forgejo/2004Scape-Wiki` (or `--wiki-root PATH`).
- This Computer-Setup checkout must stay in place: units call its `runtime.py`
  and sibling `../portal/sync.py`. The latter must support `publish-wiki`.
- Working `systemctl --user` and `loginctl show-user "$USER" -p Linger --value`
  reporting `yes`. Installation fails otherwise, including with `--no-start`.
  Have the host administrator arrange linger if the account cannot enable it;
  the installer makes no privileged changes. Enabled user timers plus linger
  provide reboot persistence without an SSH session.
- Complete, hydrated curated inputs, readable by this user:
  - `RS_SDK_WIKI_DIR`: default `~/github/rs-sdk/wiki`; requires at least one
    nonempty Markdown page other than `README.md`.
  - `BOTTING_DIR`: default `~/forgejo/2004Scape-Botting`; requires nonempty
    `learnings/*.md` (recursive, excluding `README.md`) and the four observation
    tables: `observations/{items,locs,npcs,ground-items}.tsv`. `shops.tsv` is
    optional until the bots record shops. Header-only tables are allowed;
    missing/empty required files are not. LFS pointers are rejected.

Defaults deliberately fail closed if an input checkout is absent. Do not create
empty directories as a workaround or point references at an unrelated directory.
Use the input uploader/staging process to preserve the reference and bot inputs.
Validation detects absent inputs, not semantic equivalence or partial truncation;
retain the source manifest/backups when migrating.

## Private path configuration

Optional `WIKI_CHECKOUT/data/inputs.json` is the single private input configuration
for both these timers and the wiki's local `bin/wiki` dispatcher (including SSH
requests). `--wiki-root PATH` selects the checkout, not an alternate config file.
There is no `--env-file` or `runtime.env` interface. The JSON must be a regular,
non-symlink file owned by the current user, with exactly mode `600` (`chmod 600`).
Only the two keys below are accepted; either may be omitted to use its default.
Values must be existing directories expressed as absolute paths or `~/...`;
control characters, unknown keys, non-string values and relative paths fail closed.
No shell expansion other than the current user's `~/` is performed.

```json
{
  "RS_SDK_WIKI_DIR": "~/github/rs-sdk/wiki",
  "BOTTING_DIR": "~/forgejo/2004Scape-Botting"
}
```

Keep the logical bot alias in the config, **not** an immutable resolved generation.
Both entrypoints resolve input symlinks on each invocation. Missing configuration
uses the defaults above; missing input directories, malformed or insecure config
(including a dangling config symlink) fail closed. Runtime additionally checks
hydrated curated files every service run. Remote clients never read their local
`inputs.json`: only the selected server checkout's config applies.

Keep private paths in this gitignored file, not tracked templates. Ambient input
variables are overwritten; `WIKI_DB` is rejected by the runtime to keep canonical
wiki cache/store paths. Service PATH includes `~/.bun/bin`, `~/.local/bin`, and
standard `/usr/local`, `/usr`, and `/bin` paths; no interactive shell is needed.

## Install and review

From this directory:

```bash
bash install.sh --dry-run
bash install.sh --no-start
systemctl --user cat rs-sdk-wiki-drain.service rs-sdk-wiki-publish.service
bash install.sh
```

`--dry-run` validates read-only prerequisites and prints all unit contents and
planned commands without creating files or invoking systemctl. `--no-start`
writes units and reloads the user manager but **does not enable or start** timers;
it does not stop timers enabled by a previous installation. Stop those explicitly
before reviewing an update. Both flags may be combined. Paths can be selected
with `--wiki-root PATH` and `--target PATH`.

The installer renders `wiki.service.template` and `wiki.timer.template` into
`~/.config/systemd/user/rs-sdk-wiki-{drain,publish}.{service,timer}`. Keep this
checkout at its installed path, or rerun the installer after moving it.

- Drain, every two minutes: canonical `bin/wiki downloads --drain`. The next
  timer tick resumes after an empty queue, a failed run, or a reboot. A running
  oneshot is not overlapped by its timer; no timeout cuts off a long drain.
- Publish, every five minutes: `python3 ../portal/sync.py publish-wiki --wiki-root
  PATH --target PATH --curated`. The default target is
  `~/.local/share/rs-sdk-portal/data`, with wanted input at the publisher's default
  sibling `wanted/wanted.sqlite`. Timers use persistent calendar schedules and
  small jitter, not a constantly restarting download worker.

Managed runs disable detached worker autostart (`WIKI_AUTO_IMAGES=0`); the drain
service owns background downloads. This prevents a worker spawned by publication
from being terminated when the publishing oneshot's systemd cgroup exits.

The server's canonical wiki database, downloads queue, cache, and LFS store are
**separate from the portal snapshot**. Back up the authoritative wiki checkout
and its untracked state; do not replace it with the published portal database.
Publication consumes wanted requests and cached content, not a broad crawl.
Existing wiki queue concurrency, retry/backoff, and rate limits remain intact;
this installer changes none of them and never runs force imports or scrapers.
Only authenticated SSH/session tooling should mutate server wiki/input state;
the web portal remains a snapshot reader/request producer, not a wiki writer.
Retire the old source-side wiki publisher before enabling the server publisher;
never let two machines compete to publish the same wiki snapshot.

## Operations

### Bot input uploads

Scraped data stays on the server. The Mac still produces observations and field
guides while bots play; upload only those curation inputs:

```bash
python3 linux-game-server/rs-sdk/wiki/inputs.py push --host <game-server-ssh-alias>
```

The helper allowlists `observations/{items,locs,npcs,ground-items,shops}.tsv`
when present and recursive `learnings/*.md`. It excludes account databases,
credentials and other bot files, rejects symlinks/special files, and publishes
an atomic private generation at `~/.local/share/rs-sdk-wiki/inputs/current`.
Point `~/forgejo/2004Scape-Botting` at that symlink, or configure `BOTTING_DIR`.
Readers pin the resolved generation for each invocation. Unchanged content
reuses its generation; old generations are retained for in-flight readers and
rollback, so include them in disk-usage monitoring rather than deleting them
while a reader may still hold one.

`portal/install-sync.sh <game-server-ssh-alias> --accounts-only` schedules both
account/benchmark projections and this allowlisted input upload every two
minutes. Manual account-only pushes omit inputs unless `--bot-inputs` is added.
Neither mode reads the Mac wiki cache. If the Mac sleeps, scraping and portal
publication continue on the server; only new bot-origin inputs and account
statistics wait for the Mac.

```bash
systemctl --user list-timers 'rs-sdk-wiki-*'
systemctl --user status rs-sdk-wiki-drain.service rs-sdk-wiki-publish.service
journalctl --user -u rs-sdk-wiki-drain.service -u rs-sdk-wiki-publish.service
systemctl --user start rs-sdk-wiki-publish.service
systemctl --user disable --now rs-sdk-wiki-drain.timer rs-sdk-wiki-publish.timer
```

Disabling timers does not interrupt an in-progress service; stop the specific
wiki service explicitly if necessary. Removing this runtime requires only these
four user units and a user-manager daemon reload, not changes to game/portal
services. A failure remains visible in the journal and is retried next tick.

## Cutover and rollback

Fence requesting clients before copying state: unload the legacy full-sync job,
configure their private `data/remote.json`, and stop/verify all original wiki
writers, including detached workers. A commit lock alone is not a freeze.
Retain a consistent backup of both databases plus the frozen store, Git history,
LFS objects and `data/pulls.tsv`; do not transfer source Git configuration/hooks
or credentials. Verify archive/member hashes and database table counts before
exposing the server checkout. Clear only copied process-identity claims and
waiters on the destination, preserving durable queues and rate-limit/backoff.

The deployed migration retains private archives under
`~/.local/share/rs-sdk-wiki/rollback/` on both hosts, with a private
`last-migration.json` pointer. The original Mac cache remains a stopped rollback
copy. Archives live outside expiring scratch/cache staging, but are not a
replacement for nightly off-host backups (tracked in `docs/TODO.md`).

Do not remove client remote configuration merely because SSH fails. To roll
back, first stop the server timers **and** running services, establish that no
server writer remains, and preserve any post-cutover fetches. Only then restore
one authoritative source and deliberately change client dispatch/publication
mode. Never enable both independent scrapers or remove `.wiki-authority` during
normal operation. A source can remain safely fenced after a failed migration;
use the private phase journal rather than guessing which writer started.

## Tests

```bash
python3 -B -m unittest discover -s linux-game-server/rs-sdk/wiki -v
shellcheck --severity=warning linux-game-server/rs-sdk/wiki/install.sh
```

Run from the repository root. Tests use temporary fake homes, executable command
stubs, and a fake publisher; they do not contact a wiki or deploy user services.
A real Linux user-manager/unit verification is still required before deployment.
