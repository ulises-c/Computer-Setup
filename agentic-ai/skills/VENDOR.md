# Vendored skills

Skills in this directory that originate from an external repository, and how to
refresh them. Everything here is a plain file copy — no submodules, no fetch at
install time. `install.sh` links what it finds on disk, so a fresh machine gets
the vendored version with no network access.

## simple-english

| | |
|---|---|
| Source | <https://github.com/ulises-c/SimpleEnglish> (fork of `AminBlg/SimpleEnglish`) |
| Pinned commit | `8e8a008a13e4b478f9ccc20ca16e79aef66c0739` (2026-08-21) |
| Skill version | 1.3.0 (ASD-STE100 Issue 9) |
| License | MIT |
| Vendored files | `skills/simple-english/`, `Claude/output-styles/simple-english.md` |

ASD-STE100 Simplified Technical English for docs, runbooks, error messages, and
release notes. The fork exists so an upstream change cannot alter local agent
behavior without a deliberate pull.

Two deployment surfaces, because they trigger differently:

- `skills/simple-english/` — loads on demand, when a writing task matches. Linked
  into every harness skill root by `Claude/install.sh`.
- `Claude/output-styles/simple-english.md` — always on, every reply. Claude Code
  only; opt in with `/config` → Output style → `simple-english`.

### Refresh from the fork

```bash
# 1. Sync the fork with upstream first (GitHub UI, or a local clone with an
#    'upstream' remote), then:
git clone https://github.com/ulises-c/SimpleEnglish.git /tmp/simple-english
cd /tmp/simple-english && git rev-parse HEAD    # record this as the new pin

# 2. Copy the two payloads over the vendored copies
AGENTIC=~/github/Computer-Setup/agentic-ai
cp -r /tmp/simple-english/skills/simple-english/SKILL.md \
      /tmp/simple-english/skills/simple-english/references \
      "$AGENTIC/skills/simple-english/"
cp /tmp/simple-english/output-styles/simple-english.md \
   "$AGENTIC/Claude/output-styles/simple-english.md"

# 3. Update the pin, commit, and re-link
#    (edit the Pinned commit row above, then:)
bash "$AGENTIC/Claude/install.sh"
bash "$AGENTIC/Claude/validate.sh"
```

Review the diff before committing: this content becomes standing instructions for
every agent on the machine.

### Why vendored and not a submodule

The upstream repo is ~290 files, and 264 of them are benchmark result JSONs that
no agent reads. The four files that matter total ~31 KB. A submodule would clone
all of it, add a `.gitmodules` to a repo that has none, and require
`--recurse-submodules` on every fresh clone — to deliver four markdown files.

## ponytail

| | |
|---|---|
| Source | <https://github.com/ulises-c/ponytail> (fork of `DietrichGebert/ponytail`) |
| Pinned commit | `16f29800fd2681bdf24f3eb4ccffe38be3baec6b` (2026-07-15) |
| Skill version | 4.8.4 |
| License | MIT (copy in `skills/ponytail/LICENSE`) |
| Vendored files | `skills/ponytail/`, `skills/ponytail-review/`, `skills/ponytail-audit/`, `skills/ponytail-debt/`, `skills/ponytail-gain/`, `skills/ponytail-help/` (`SKILL.md` only) |

Lazy-senior-dev mode: YAGNI, standard library before custom code, native
platform features before dependencies, no unrequested abstractions. The fork
exists for the same reason as the simple-english one.

Skills only, on purpose. The upstream repo also ships a native Hermes plugin
(`plugin.yaml` + `__init__.py`) and Claude Code hooks. Both inject the ruleset
before every LLM turn, coding or not. As plain skills, ponytail loads only when
a task matches. The `/ponytail` mode switch and the `ponytail-*` slash commands
are plugin features, so they are not available here. Ask for "ponytail",
"ponytail review", and so on instead. `ponytail-gain` cites `benchmarks/`, which
is not vendored. Its scoreboard figures are inline in the skill.

The Laza Claude Code marketplace carries a separate patched build
(`~/bitbucket/laza-claude-marketplace/plugins/ponytail/`, see its
`PROVENANCE.md`). It is independent of this copy.

### Refresh from the fork

```bash
# 1. Sync the fork with upstream first, then:
git clone https://github.com/ulises-c/ponytail.git /tmp/ponytail
cd /tmp/ponytail && git rev-parse HEAD    # record this as the new pin

# 2. Copy each SKILL.md over the vendored copy
AGENTIC=~/github/Computer-Setup/agentic-ai
for s in /tmp/ponytail/skills/*/; do
  n=$(basename "$s")
  mkdir -p "$AGENTIC/skills/$n"
  cp "$s/SKILL.md" "$AGENTIC/skills/$n/"
done
cp /tmp/ponytail/LICENSE "$AGENTIC/skills/ponytail/LICENSE"

# 3. Update the pin, commit, and re-link
bash "$AGENTIC/Claude/install.sh"
bash "$AGENTIC/Claude/validate.sh"
```

If upstream adds or removes a skill directory, update the "Vendored files" row
and delete stale directories by hand. The copy loop does not remove them.
