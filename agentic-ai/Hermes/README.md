# Hermes

Hermes Agent tooling that is not a skill: the `hermes-config` sync tool, the
installer and the TUI widgets.
The skills, the portable hand-written files (worker profiles, the default
`SOUL.md`, hooks) and a per-machine backup of Hermes state (cron jobs,
scripts, config, memory) live in **private** Forgejo repos, never here. This
repo is public, and those files contain work IP and identifying details.
Suggested repo names are `hermes-config-work` (work account) and
`hermes-config` (personal account).

## Layout

| Path | What |
|---|---|
| `bin/hermes-config` | Deterministic skill sync and machine-state backup (below). Linked to `~/.local/bin`. |
| `lib/provenance.py` | Read-only edit-history classifier used by `hermes-config`. |
| `lib/hermes-root.sh` | Finds the Hermes root and the portable dir, for `install.sh` and `validate.sh`. |
| `lib/never-copy.sh` | The one never-copy list, shared by the state backup and `install.sh`. |
| `tui-widgets/codeburn.mjs` | `/codeburn` ambient card: spend today/month + Claude/Codex quota. Linked to `$HERMES_HOME/tui-widgets/`. |
| `install.sh` / `validate.sh` | Idempotent links, including the portable files (below) / health check (runs `hermes-config verify` once `.env` exists). |
| `tests/hermes-config.test.sh` | E2E test: throwaway `HERMES_HOME`, local bare repos, fake Bitbucket API and session history, the real `hermes` CLI. |
| `tests/profiles-install.test.sh` | Profile install/validate test for default, named-profile, and custom Hermes roots. |
| `.env.example` | Repos, markers, provenance settings. Copy to `.env` (gitignored). |

## Portable files (install.sh)

Hand-written Hermes files live in a private config repo, the **portable
dir**, and `install.sh` links them into the Hermes root (`~/.hermes`). A
config repo looks like this:

```
skills/                                  skills (hermes-config, below)
profiles/<name>/config.yaml              linked to <root>/profiles/<name>/
profiles/<name>/profile.yaml             linked
profiles/<name>/SOUL.md                  linked
profiles/<name>/scripts/...              copied (Hermes cron runs only real files)
hooks/                                   linked as <root>/agent-hooks
default/SOUL.md                          linked as <root>/SOUL.md
machines/<host>/                         nightly state snapshot (State backup)
```

- **Which dir:** `$HERMES_PORTABLE_DIR`, else `HERMES_PORTABLE_DIR` in `.env`,
  else the work repo dir, else the personal repo dir (a repo counts only when
  its `REMOTE` is set). A relative path is taken from the current dir and
  made absolute, so the links work from anywhere. With none set, or before
  the repo is cloned, `install.sh` links only `hermes-config` and the widgets
  and says why.
- **`.env` is shell code.** `install.sh`, `validate.sh` and `hermes-config`
  all `source` it. Its variables stay in a subshell for the two scripts, but
  any command in it runs: treat it like any script you run.
- **The root is found the way Hermes finds it,** so running from a
  named-profile session (`HERMES_HOME=~/.hermes/profiles/coder`) still
  targets the sibling profiles. A missing profile is created with
  `hermes profile create`.
- **Refused before any change:** a portable dir that is the Hermes root, is
  inside it, or holds it (symlinks resolved); and, when `HERMES_HOME` is a
  named profile, that profile dir or its `scripts/` being a symlink (the
  widgets would be written through it). A portable file that is the live
  file under another name (symlink or hard link) is left alone and reported.
- **A live edit:** a regular file where a link belongs (after `sed -i`, say)
  is backed up to `<file>.bak-<stamp>` (a counter is added if that name
  exists) and replaced by the link. A directory there is refused.
- **Scripts are copied,** recursively, minus the never-copy names. A live
  script that differs is backed up first; a live symlink (to a file or a
  dir) is replaced by a real file, never written through, and a symlinked dir
  inside `scripts/` is refused. A live profile dir, or its `scripts/`, that
  is a symlink is refused before anything in that profile changes (exit 1);
  `validate.sh` fails on it too. Re-run `install.sh` after you change one;
  `validate.sh` checks every one.
- **Hooks:** a real `agent-hooks/` with the same content is moved aside to
  `agent-hooks.bak-<stamp>`; one that differs is left alone, with the
  differences listed.
- **Edits go to the config repo.** Hermes writes `config.yaml` through the
  link, so a `hermes -p <name> config set` shows up as a git diff there, and
  the nightly `sync` commits it. Review it: a runtime write can add machine
  state. Keep the dashboard login (`dashboard.basic_auth`) out of a linked
  config; set it per machine with `hermes dashboard`.
- **Not portable:** `.env`, auth, sessions, memories, logs, caches and cron
  jobs. Memory and cron jobs are copied nightly instead (State backup).

```bash
bash install.sh                      # link everything; the portable copy wins
bash install.sh --take-live          # the live copy wins: copy it over the portable one
bash install.sh --adopt [--dry-run]  # first copy what the portable dir lacks from the live install
bash validate.sh                     # check links, copies, kanban assignees, hermes-config verify
```

- **`--take-live`** keeps the old portable content as `<file>.bak-<stamp>`
  beside it, says so, and adds `*.bak-*` to the repo's local
  `.git/info/exclude` so `sync` never commits it (see Known limits if that
  write fails). The new content goes to a temp file that is then renamed
  into place.
- **`--adopt`** copies profiles that have a `profile.yaml` (`config.yaml`,
  `profile.yaml`, `SOUL.md`, every file under `scripts/`), the default
  `SOUL.md` and `agent-hooks/` into the portable dir. It never overwrites a
  portable file, skips the never-copy names, and stages nothing.

`tests/profiles-install.test.sh` runs both scripts for a default root, a
named-profile `HERMES_HOME` and a custom root, in a throwaway `HOME`.

## Skill sync model

```
hermes-config-work  (work Forgejo account)      ─┐
hermes-config       (personal Forgejo account)  ─┴─► skills.external_dirs ─► Hermes
  └─ machines/<host>/         per-machine state backup (personal)
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
  The scanner knows token shapes only (prefixes such as `ghp_`, `AKIA`,
  `sk-`, key headers). A password or other secret written as free text
  cannot be detected.
- **The guard checks what a push publishes.** `push`, `sync`, and a pre-push
  hook installed next to the pre-commit hook scan everything the push sends
  that origin does not have yet: every new file (binary files and symlink
  targets too, including files a later commit deleted), every path, every
  commit message, and the branch name. The tool then pushes exactly the
  commit it scanned. Commit author and email are not checked.
- **The scan fails closed.** A scanner error (for example a
  `HERMES_CONFIG_SYNC_WORK_MARKERS` that is not a valid ERE) or a missing terms
  file blocks the commit, push, or adopt; it never counts as clean. Written-out
  tabs, CRs and newlines (`\n`, `\t`, `\u000a`, `\x0d`, as in JSON or `printf`
  strings) count as word boundaries.
- **Only the configured remote.** `sync`, `pull`, and `push` refuse to run when
  origin's fetch URL or its push URL (after `insteadOf` rewrites) is not the
  `REMOTE` in `.env`, and check again right before each push; `verify` checks
  both. The pre-push hook refuses any other destination, including
  `git push <other remote or URL>`.
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
hermes-config sync               # unattended pull --ff-only + state backup + commit + push (nightly cron)
hermes-config backup-state       # snapshot this machine's state into machines/<host>/, no commit
                                 # (backup-cron is an alias)
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
2. In the backup repo, rebuild `machines/<host>/` (see State backup).
3. `git add -A`. If anything is staged, commit as
   `chore: sync skills (<names>)` (or `state backup` when `machines/`
   changed) with the changed files listed in the body.
   The commit is signed, and the pre-commit guard runs as for any commit.
4. Push if ahead, after scanning the outgoing commits.

| Outcome | Message |
|---|---|
| Nothing changed | none (empty stdout is silent) |
| Committed / pushed | one line per repo |
| Diverged history, guard hit, fetch or push failure | exit 1 with the reason, sent as a cron failure alert |

It never force-pushes, rebases, or discards work. A blocked commit is
unstaged and left in the working tree for you to fix. A `flock` stops
overlapping runs. Unattended runs need the Forgejo SSH key and the GPG
signing key to work without a prompt, or the key cached in an agent the
gateway can reach. If the ssh agent holds a passphrase-protected copy of the
key (gpg-agent does this), it refuses to sign without a prompt and ssh does
not fall back to the key file: set `HERMES_CONFIG_SYNC_SSH_COMMAND` in `.env`
to use the key file and skip the agent.

## State backup

`sync` also snapshots this machine's Hermes state into the personal repo
before it commits (`hermes-config backup-state` does the same without
committing, and prints what it left out and `git status` of the backup):

```
machines/<host>/
  <home>/                     default (the root ~/.hermes) or the profile name
    jobs.json                 cron jobs, configuration fields only
    scripts/                  every file under the home's scripts/
    config.yaml  SOUL.md  profile.yaml  shell-hooks-allowlist.json
    memories/MEMORY.md  memories/USER.md
    agent-hooks/              default only
  systemd/                    Hermes systemd user units
  stock-skill-edits/<skill>/  copies of locally edited stock skills
  env-names.txt               variable names in the root .env, no values
```

- **Default target:** the personal repo when it is enabled, otherwise off.
  Override it with `HERMES_CONFIG_SYNC_STATE_BACKUP=personal|work|off`. When
  that is unset, the older `HERMES_CONFIG_SYNC_CRON_BACKUP` still decides.
  `off` skips the backup on purpose. Any other value, or a repo that is not
  enabled, makes `sync` and `backup-state` exit 1 before they fetch or commit
  anything (`verify` reports it too).
- **Keyed by host:** one personal repo is shared by several machines, so each
  host rebuilds only its own `machines/<host>/`. The label is
  `HERMES_CONFIG_SYNC_STATE_HOST`, else `HERMES_CONFIG_SYNC_CRON_HOST`, else
  `hostname -s`. A profile named `default`, `systemd`, `stock-skill-edits`
  or `env-names.txt` would collide with these names: it is left out and
  reported.
- **Moved from `cron/`:** the backup used to live in `cron/<host>/<profile>/`.
  After a good snapshot, this host's `cron/<host>/` is removed (other hosts'
  dirs stay until they upgrade), and `cron/` goes once it is empty.
- **Copied only when it is a regular file:** a symlink (for example a
  `SOUL.md` or `agent-hooks/` that `install.sh` links from a config repo) is
  tracked where it points and skipped. A symlink inside `scripts/` or a stock
  skill is never followed and is reported as left out. Hidden files are
  skipped.
- **systemd units:** files in `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`
  whose names match `HERMES_CONFIG_SYNC_SYSTEMD_UNITS` (space-separated globs,
  default `hermes-*.service hermes-*.timer`; set but empty means none).
- **Stock skill edits:** each skill named in `HERMES_CONFIG_SYNC_STOCK_SKILLS`
  (space-separated) is found by name under `~/.hermes/skills/` and copied, so
  a local edit that `hermes update` would overwrite is on record. A name that
  is not found is reported, not an error.
- **`config.yaml` is redacted by word,** whole line, not by a YAML parser.
  In the copy, any line that contains `password`, `passwd`, `secret`,
  `token`, `api_key`, `apikey`, `bearer` or `credential` (any case, anywhere
  in the line) becomes `key: <redacted>` (or `# <redacted line>` when it has
  no plain `key:` to keep), and the blank or further-indented lines below it
  go with it: its nested block, its list (also one at the key's own indent),
  a block scalar, the rest of a value that runs over lines. Only a plain
  `key: value` or `- key: value` line whose value is a `${NAME}` reference,
  `null`, `~`, `true`/`false`, a number or empty quotes is kept as it is, so
  `max_tokens` and the other `*_tokens` limits stay. It over-redacts on
  purpose: `token_counter: tiktoken` becomes `token_counter: <redacted>`, and
  a flow map such as `limits: {max_tokens: 4096}` loses its whole value.
  Comment lines are copied as they are. The copy may not be valid YAML. A
  credential's value is missed when it sits on a line without the word and
  not indented under it (a quoted value continued at the key's own indent,
  or a `? key` / `: value` pair), and a secret under any other key name or
  in free text is not detected: the scan only knows token shapes. Linked
  profile configs in the config repo keep their values as they are.
- **`.env`:** only the names (`NAME=value`, `NAME = value` or
  `export NAME=value` lines) go into `env-names.txt`, sorted. No value is
  ever written. If a quoted value runs over more than one line, or any line
  ends in a backslash (a continued line), no `env-names.txt` is written and
  the left-out report says why: the inner lines could look like names.
- **Never copied** (`lib/never-copy.sh`, the same list `install.sh` uses):
  `__pycache__`, `mcp-tokens`, `*.pyc`, `*.lock`, `*.bak*`, `.env*`,
  `auth.json`, `*.db*`, on any part of the path, so a dir with such a name
  is skipped with all it holds. Also everything not listed above (sessions,
  logs, state.db, caches, other memory files). A file whose name has a
  newline is left out and reported, with the newline shown as `\n`. The
  list applies to copied files; see Known limits for `jobs.json`.
- **No-op runs stay silent:** only cron configuration fields are kept (a
  whitelist: `id`, `name`, `prompt`, `skills`, `schedule`, `repeat.times`,
  `enabled`, `deliver`, ...). Scheduler runtime (`state`, `next_run_at`,
  `last_*`, claims, `pending_slot`, `repeat.completed`, and any field Hermes
  adds later) is dropped, so a run by itself never makes a diff.
- **Redaction:** outside the work repo, chat IDs in `deliver` /
  `failure_deliver` become `platform:<redacted>` and `origin` becomes
  `<redacted>` (the field stays), so a work Slack DM ID never reaches the
  personal repo. When restoring, re-pick the delivery target.
- **Left out:** every copied file (and each job) goes through the same scan as
  a commit. One with a possible secret, or (personal repo) one that names
  work, is not backed up. `sync` reports what it left out only when that set
  changes. It is not an error: one work file must not block every other
  commit.
- **Fails safe:** an unreadable file, an unparsable `jobs.json`, a scanner
  error, a missing Hermes root, a bad state backup target, or any copy/write
  error makes `sync` and `backup-state` exit 1 and leaves the repo as it
  was, so a bad read never commits the deletion of the last good backup
  (one exception: see Known limits). The snapshot is built under
  the clone's `.git/`; the old `machines/<host>/` is moved aside, the new one
  moved in, and only then is the old one deleted. If the new one cannot move
  in, the old one is put back, and the error says which state the repo is in.
  A symlinked `machines/`, `machines/<host>` or `cron/` is refused.
- **Changing the target or the host label** leaves the old snapshot in the
  previous repo (or under the old label); nothing deletes it for you. To drop
  it, in that repo:

  ```bash
  git rm -r --ignore-unmatch machines/<old-host> cron/<old-host>
  git commit -m "chore: drop the state backup of <old-host>" && hermes-config push
  ```

Restoring is by hand: `hermes cron create ...` from the saved job fields,
copy files back, re-create `.env` from `env-names.txt`. The snapshot is a
record, not a tree to copy over `~/.hermes`.

## Known limits

- A directory that cannot be listed is treated as empty.
- The generated `jobs.json` path is not checked against the work terms or
  the never-copy list.
- If `install.sh --take-live` cannot write the git exclude, its `.bak-` copy
  is not ignored: keep `*.bak*` in the config repo's `.gitignore`.
- A refused cron job is reported by its id and name, so never put a secret
  in a job name.
- `install.sh` refuses a named-profile `HERMES_HOME` whose `scripts/` is a
  symlink, even on a run that would not write there (no portable dir, or
  `--adopt --dry-run`).
- The `config.yaml` snapshot keeps a credential whose value is only a number
  (a numeric password, say): numbers are treated as safe so `max_tokens` and
  the other limits stay.

## First-time setup

On a new machine, in this order:

1. Install Hermes.
2. Clone Computer-Setup.
3. `cp .env.example .env` and fill in the values.
4. `bash install.sh`: links `hermes-config` and the widgets. The portable
   files are skipped, because the config repos are not cloned yet.
5. `hermes-config install`: clones the config repos, installs the guards,
   sets `skills.external_dirs`.
6. `bash install.sh` again: now it links the portable files.
7. `bash validate.sh`
8. Schedule the nightly sync (command above).

The first time ever (empty repos), create them in the Forgejo UI first (one
per account). After step 5, run `bash install.sh --adopt --dry-run`, then
`--adopt`, to seed the portable files from the live install, and
`hermes-config migrate`, review the plan, then `hermes-config migrate --apply`
for the skills. In each clone: `git diff --cached` / `git status`, commit,
then `hermes-config push`.
