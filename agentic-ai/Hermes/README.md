# Hermes

Hermes Agent config that is not a skill: the skill-sync tool and TUI widgets.
The skills themselves live in two **private** Forgejo repos, never here — this
repo is public, and the skills contain work IP and identifying details.

## Layout

| Path | What |
|---|---|
| `bin/hermes-skills` | Deterministic skill sync (below). Linked to `~/.local/bin`. |
| `tui-widgets/codeburn.mjs` | `/codeburn` ambient card: spend today/month + Claude/Codex quota. Linked to `$HERMES_HOME/tui-widgets/`. |
| `install.sh` / `validate.sh` | Idempotent links / health check (runs `hermes-skills verify` once `.env` exists). |
| `tests/hermes-skills.test.sh` | E2E test: throwaway `HERMES_HOME`, local bare repos, the real `hermes` CLI. |
| `.env.example` | Repo URLs, clone paths, work-marker regex. Copy to `.env` (gitignored). |

## Skill sync model

```
work repo      (work Forgejo account)      ─┐
personal repo  (personal Forgejo account)  ─┴─► skills.external_dirs ─► Hermes
~/.hermes/skills/                         bundled + hub skills only (Hermes-owned)
```

- **The repos are the source of truth.** Hermes reads them through
  `skills.external_dirs`, so the background curator treats them as read-only.
  A skill changes only through a commit you review. Hermes can still edit an
  external skill when you tell it to (`skill_manage patch`). That edit shows up
  as a normal git diff in the repo.
- **Work and personal skills are split.** Any file that matches
  `HERMES_SKILLS_WORK_MARKERS` is blocked from the personal repo.
- **Secrets are blocked everywhere.** The token and private-key patterns are
  checked by `adopt`, by a pre-commit hook installed into each clone, and again
  by `push`. A match is reported by file:line only; the value is never printed.
- **Skills Hermes owns are never moved.** Bundled, hub-installed, and shipped
  skills stay local and update through `hermes update`. Only skills you wrote
  are adopted into a repo.
- **Name collisions are checks.** Hermes will not load a name that is ambiguous.
  `verify` fails if the same name is local and in a repo, or in both repos.

## Commands

```bash
hermes-skills install            # clone repos, install guards, set external_dirs (keeps other entries)
hermes-skills status             # repo state, unadopted skills + suggested target, collisions
hermes-skills migrate            # dry-run plan; --apply moves and stages (no commit)
hermes-skills adopt <name> <work|personal>
hermes-skills scan | verify | pull | push
```

A new agent-created skill lands in `~/.hermes/skills/`. `status` lists it as
unadopted, and `adopt` moves it into a repo.

## First-time setup

1. Create two empty repos in the Forgejo UI (one per account).
2. `cp .env.example .env` and fill in the values.
3. `bash install.sh && hermes-skills install`
4. `hermes-skills migrate`, review the plan, then `hermes-skills migrate --apply`
5. In each clone: `git diff --cached`, commit, then `hermes-skills push`
6. `bash validate.sh`
