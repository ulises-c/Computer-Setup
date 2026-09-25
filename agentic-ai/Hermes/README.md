# Hermes

Hermes Agent config that is not a skill: the `hermes-config` sync tool and TUI
widgets.
The skills themselves, plus a backup of cron jobs, live in **private** Forgejo
repos, never here. This repo is public, and the skills contain work IP and
identifying details. Suggested repo names are `hermes-config-work` (work
account) and `hermes-config` (personal account).

## Layout

| Path | What |
|---|---|
| `bin/hermes-config` | Deterministic skill sync and cron backup (below). Linked to `~/.local/bin`. |
| `lib/provenance.py` | Read-only edit-history classifier used by `hermes-config`. |
| `tui-widgets/codeburn.mjs` | `/codeburn` ambient card: spend today/month + Claude/Codex quota. Linked to `$HERMES_HOME/tui-widgets/`. |
| `install.sh` / `validate.sh` | Idempotent links / health check (runs `hermes-config verify` once `.env` exists). |
| `tests/hermes-config.test.sh` | E2E test: throwaway `HERMES_HOME`, local bare repos, fake Bitbucket API and session history, the real `hermes` CLI. |
| `.env.example` | Repos, markers, provenance settings. Copy to `.env` (gitignored). |

## Skill sync model

```
hermes-config-work  (work Forgejo account)      ─┐
hermes-config       (personal Forgejo account)  ─┴─► skills.external_dirs ─► Hermes
  └─ cron/<host>/<profile>/   cron jobs + scripts backup (personal)
~/.hermes/skills/                              Hermes-owned skills only
```

- **The repos are the source of truth.** Hermes reads them through
  `skills.external_dirs`, so the background curator treats them as read-only.
  A skill changes only through a commit you review. Hermes can still edit an
  external skill when you tell it to (`skill_manage patch`). That edit shows up
  as a normal git diff in the repo.
- **One tool, any setup.** A repo is enabled when its remote is set in `.env`.
  A work machine enables both. A personal-only setup enables just the personal
  repo; skills that name work stay local there.
- **Secrets are blocked everywhere.** The token and private-key patterns are
  checked by `adopt`, by a pre-commit hook installed into each clone, and again
  by `push`. A match is reported by file:line only; the value is never printed.
- **The guard checks what a push publishes.** `push`, `sync`, and a pre-push
  hook installed next to the pre-commit hook scan everything the push sends
  that origin does not have yet: every new file (binary files and symlink
  targets too, including files a later commit deleted), every path, every
  commit message, and the branch name. The tool then pushes exactly the
  commit it scanned. Commit author and email are not checked.
- **The scan fails closed.** A scanner error (for example a
  `HERMES_CONFIG_SYNC_WORK_MARKERS` that is not a valid ERE) or a missing terms
  file blocks the commit, push, or adopt; it never counts as clean. `\n`, `\r`
  and `\t` escapes (JSON, `printf` strings) count as word boundaries.
- **Only the configured remote.** `sync`, `pull`, and `push` refuse to run when
  origin's fetch URL or its push URL (after `insteadOf` rewrites) is not the
  `REMOTE` in `.env`; `verify` checks both.
- **Skills Hermes owns are never moved.** Bundled, hub-installed, shipped, and
  once-shipped skills (found in the Hermes source history) stay local and update
  through `hermes update`. Only skills you wrote are adopted into a repo.
- **Name collisions are checks.** Hermes will not load a name that is ambiguous.
  `verify` fails if the same name is local and in a repo, or in both repos.

## What counts as work

Checked in order; the first rule that applies decides.

1. **Hermes owns it** → stays local, never adopted.
2. **The content names something work-internal** → work. This is the only
   enforced rule: `adopt`, the personal repo's pre-commit and pre-push hooks,
   and `push` all refuse it, in file contents and in file and directory names. Markers are the generated repo-name terms, Jira issue refs
   (`KEY-123`, case-sensitive), and an optional hand-written regex.
3. **Most of its edits happened in work sessions** (more than half; a tie is
   personal) → suggest work. `lib/provenance.py` reads the curator ledger and each
   session's repo:
   - The repo commits as a non-work address → not work. This is definitive:
     work is only ever committed as the work identity.
   - Otherwise its origin matches `HERMES_CONFIG_SYNC_WORK_REMOTE_PATTERNS` → work.
     The work address alone proves nothing, because work-adjacent open-source
     contributions commit as it too.
   - No repo: a subagent takes its parent's class; otherwise the session is
     work if what you typed names a marker.
4. **Otherwise** → suggest personal.

Rules 3 and 4 are suggestions. `hermes-config classify <skill>` shows the
evidence behind one, and `adopt <skill> <work|personal>` overrides it. Content
that names work can never be overridden into the personal repo.

## Commands

```bash
hermes-config install            # clone repos, install guards, refresh terms, set external_dirs
hermes-config status             # repo state, unadopted skills + suggested target, collisions
hermes-config migrate            # dry-run plan; --apply moves and stages (no commit)
hermes-config adopt <name> <work|personal>
hermes-config classify <name>... # why a skill got its suggestion
hermes-config refresh-markers    # regenerate .work-terms from the Bitbucket workspace
hermes-config scan | verify | pull | push
hermes-config sync               # unattended pull --ff-only + cron backup + commit + push (nightly cron)
hermes-config backup-cron        # snapshot cron jobs + scripts into the backup repo, no commit
```

A new agent-created skill lands in `~/.hermes/skills/`. `status` lists it as
unadopted, and `adopt` moves it into a repo.

## Nightly commit + push

Edits to adopted skills land in the clones as uncommitted changes: a
`skill_manage patch`, or your own edit. `hermes-config sync` commits and pushes
them, and a Hermes cron job runs it nightly:

```bash
hermes cron create "0 2 * * *" --name "hermes-config nightly sync" \
  --script hermes-config-sync.sh --no-agent --deliver slack:<home-channel>
```

`install` writes `$HERMES_HOME/scripts/hermes-config-sync.sh`, a two-line
wrapper. Hermes cron only runs scripts inside that dir and rejects symlinks
that escape it. The job has no LLM step (`--no-agent`), so it costs nothing,
and it only messages you when something happened. For each enabled repo:

1. `fetch` + `merge --ff-only` from origin (another machine's pushes).
2. `git add -A`. If anything is staged, commit as
   `chore: sync skills (<names>)` with the changed files listed in the body.
   The commit is signed, and the pre-commit guard runs as for any commit.
3. Push if ahead, after scanning the outgoing commits.

| Outcome | Message |
|---|---|
| Nothing changed | none (empty stdout is silent) |
| Committed / pushed | one line per repo |
| Diverged history, guard hit, fetch or push failure | exit 1 with the reason, sent as a cron failure alert |

It never force-pushes, rebases, or discards work. A blocked commit is
unstaged and left in the working tree for you to fix. A `flock` stops
overlapping runs. Unattended runs need the Forgejo SSH key and the GPG
signing key to work without a prompt, or the key cached in an agent the
gateway can reach.

## Cron backup

`sync` also snapshots every profile's cron jobs and `scripts/` into the
personal repo, under `cron/<host>/<profile>/{jobs.json,scripts/}`, before it
commits (`hermes-config backup-cron` does the same without committing).

- **Default target:** the personal repo when it is enabled, otherwise off.
  Override it with `HERMES_CONFIG_SYNC_CRON_BACKUP=personal|work|off`.
- **Keyed by host:** one personal repo is shared by several machines, so each
  host rebuilds only its own directory.
- **No-op runs stay silent:** runtime fields (`next_run_at`, `last_*`,
  `fire_claim`, `repeat.completed`, ...) are dropped, so a run by itself never
  makes a diff.
- **Redaction:** outside the work repo, chat IDs in `deliver` /
  `failure_deliver` become `platform:<redacted>` and `origin` is dropped, so a
  work Slack DM ID never reaches the personal repo. When restoring, re-pick
  the delivery target.
- **Left out:** a job or script with a possible secret, or (personal repo)
  one that names work, is not backed up. `sync` reports what it left out only
  when that set changes. It is not an error: one work job must not block
  every other commit. Hidden files under `scripts/` are skipped.

Restoring uses the normal CLI (`hermes cron create ...` from the saved
fields). The snapshot is a record, not a file to copy over `jobs.json`.

## First-time setup

1. Create the empty repos in the Forgejo UI (one per account).
2. `cp .env.example .env` and fill in the values.
3. `bash install.sh && hermes-config install`
4. `hermes-config migrate`, review the plan, then `hermes-config migrate --apply`
5. In each clone: `git diff --cached`, commit, then `hermes-config push`
6. `bash validate.sh`
7. Schedule the nightly sync (command above).
