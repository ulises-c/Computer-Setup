# Hermes

Hermes Agent config that is not a skill: the skill-sync tool and TUI widgets.
The skills themselves live in **private** Forgejo repos, never here — this
repo is public, and the skills contain work IP and identifying details.

## Layout

| Path | What |
|---|---|
| `bin/hermes-skills` | Deterministic skill sync (below). Linked to `~/.local/bin`. |
| `lib/provenance.py` | Read-only edit-history classifier used by `hermes-skills`. |
| `tui-widgets/codeburn.mjs` | `/codeburn` ambient card: spend today/month + Claude/Codex quota. Linked to `$HERMES_HOME/tui-widgets/`. |
| `install.sh` / `validate.sh` | Idempotent links / health check (runs `hermes-skills verify` once `.env` exists). |
| `tests/hermes-skills.test.sh` | E2E test: throwaway `HERMES_HOME`, local bare repos, fake Bitbucket API and session history, the real `hermes` CLI. |
| `.env.example` | Repos, markers, provenance settings. Copy to `.env` (gitignored). |

## Skill sync model

```
work repo      (work Forgejo account)      ─┐
personal repo  (personal Forgejo account)  ─┴─► skills.external_dirs ─► Hermes
~/.hermes/skills/                         Hermes-owned skills only
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
- **Skills Hermes owns are never moved.** Bundled, hub-installed, shipped, and
  once-shipped skills (found in the Hermes source history) stay local and update
  through `hermes update`. Only skills you wrote are adopted into a repo.
- **Name collisions are checks.** Hermes will not load a name that is ambiguous.
  `verify` fails if the same name is local and in a repo, or in both repos.

## What counts as work

Checked in order; the first rule that applies decides.

1. **Hermes owns it** → stays local, never adopted.
2. **The content names something work-internal** → work. This is the only
   enforced rule: `adopt`, the personal repo's pre-commit hook, and `push` all
   refuse it. Markers are the generated repo-name terms, Jira issue refs
   (`KEY-123`, case-sensitive), and an optional hand-written regex.
3. **Most of its edits happened in work sessions** (a tie counts as work) →
   suggest work. `lib/provenance.py` reads the curator ledger and each
   session's repo:
   - The repo commits as a non-work address → not work. This is definitive:
     work is only ever committed as the work identity.
   - Otherwise its origin matches `HERMES_SKILLS_WORK_REMOTE_PATTERNS` → work.
     The work address alone proves nothing, because work-adjacent open-source
     contributions commit as it too.
   - No repo: a subagent takes its parent's class; otherwise the session is
     work if what you typed names a marker.
4. **Otherwise** → suggest personal.

Rules 3 and 4 are suggestions. `hermes-skills classify <skill>` shows the
evidence behind one, and `adopt <skill> <work|personal>` overrides it. When it
is unclear, pick work: a personal skill in the work repo can be moved later on
purpose, but a work skill in the personal repo is IP that has left.

## Commands

```bash
hermes-skills install            # clone repos, install guards, refresh terms, set external_dirs
hermes-skills status             # repo state, unadopted skills + suggested target, collisions
hermes-skills migrate            # dry-run plan; --apply moves and stages (no commit)
hermes-skills adopt <name> <work|personal>
hermes-skills classify <name>... # why a skill got its suggestion
hermes-skills refresh-markers    # regenerate .work-terms from the Bitbucket workspace
hermes-skills scan | verify | pull | push
```

A new agent-created skill lands in `~/.hermes/skills/`. `status` lists it as
unadopted, and `adopt` moves it into a repo.

## First-time setup

1. Create the empty repos in the Forgejo UI (one per account).
2. `cp .env.example .env` and fill in the values.
3. `bash install.sh && hermes-skills install`
4. `hermes-skills migrate`, review the plan, then `hermes-skills migrate --apply`
5. In each clone: `git diff --cached`, commit, then `hermes-skills push`
6. `bash validate.sh`
