# Code Review 1 — AGENTS.md & agentic-ai/ (PR #61, branch `docs/agents-md-master`)

Max-effort review: 10 finder angles → 6-verifier pass (1-vote, 3-state) → gap sweep.
Scope: `git diff origin/main...HEAD -- AGENTS.md CLAUDE.md agentic-ai/`.
Review artifact for PR #61.

## Findings (ranked, most severe first)

### 1. `install.sh` aborts mid-install if `~/.claude/docs` exists as a real directory — CONFIRMED
`agentic-ai/Claude/install.sh:43` — `rm -f "$CLAUDE_DIR/docs"` cannot remove a real
directory; under `set -euo pipefail` it exits 1 ("Is a directory") and kills the
script after `rules/` is linked but before railguard.yaml, hooks, and the railguard
binary install — a half-provisioned `~/.claude`. Verified by test. **`ln -sfn` alone is
NOT a fix**: on GNU coreutils it errors on a real dir; on uutils it exits 0 but nests
the link *inside* the directory. Needs an explicit guard, e.g.
`[[ -d "$CLAUDE_DIR/docs" && ! -L "$CLAUDE_DIR/docs" ]] && rm -rf …` or a fail-with-message.

### 2. `validate.sh` fails on every correctly-installed machine (settings.json copy-vs-symlink drift) — CONFIRMED
`agentic-ai/Claude/validate.sh:31` still runs
`check_symlink "$CLAUDE_DIR/settings.json" …`, but `install.sh` deliberately
**copies** settings.json (and removes any old symlink). Every fresh install guarantees
a `[FAIL]`. Pre-existing on main, but this PR extends the same hand-mirrored list
(the new docs line), and it's the proof that the install/validate manifest drifts.
Fix: change line 31 to a file-exists/`cmp` check (drift is already `settings-drift.sh`'s
job), and consider a shared (src,dest,kind) manifest both scripts read.

### 3. Always-loaded rules dropped the `~/.gnupg`/`~/.config/gh` readable exception — CONFIRMED
`agentic-ai/Claude/rules/common/railguard.md:6` no longer says gnupg/gh stay readable,
while the auto-managed block still says "Do NOT attempt to … Access `~/.gnupg`" —
**which contradicts `railguard.yaml`** (comment: gnupg/gh "intentionally absent" from
denied paths). A GPG-signed commit never triggers a block, so nothing ever routes the
agent to `docs/RAILGUARD.md` where the exception now lives: the agent self-censors on
signing/`gh` config based on an unqualified prohibition. Also dropped: `~/.config/gcloud`
(which IS denied in yaml). Fix: restore the one-line exception to the slim rule; fix the
managed-block list upstream in the fork's template.

### 4. `~/.claude/docs/RAILGUARD.md` pointer dangles on every other machine until `install.sh` is re-run — CONFIRMED
`agentic-ai/Claude/rules/common/railguard.md:8` — `~/.claude/rules` is a live dir
symlink into the repo, so `git pull` activates the new rule text instantly, but only
`install.sh` creates the `~/.claude/docs` symlink. On the Macs/CachyOS box, the
documented reporting protocol is unreachable between pull and reinstall. Fix options:
have the rule fall back ("or `agentic-ai/Claude/docs/RAILGUARD.md` in the Computer-Setup
repo"), or note the install.sh re-run in the PR/release step.

### 5. AGENTS.md: "a bare TTY run … prompts interactively" dropped the server-profile exception — CONFIRMED (sweep)
`AGENTS.md:19` states the interactive prompt unconditionally. `lib/core.sh`
(`core_maybe_prompt_selection`) returns early when `SERVER_PROFILE=true` *before* the
TTY check — a bare `--profile server` TTY run never prompts. The old CLAUDE.md stated
this exception explicitly ("skipped on the server profile and in non-interactive/CI
runs"); the AGENTS.md condensation lost it. Fix: restore the clause.

### 6. AGENTS.md: "Every field can be a scalar or a per-platform object" is false — CONFIRMED
`AGENTS.md:33` — per `docs/PACKAGES.md` only `priority`/`optional`/`environment`/
`install_command` take the per-platform-object form; `tags` must be a plain non-empty
array (validator: "tags must be an array"). An agent taking the sentence literally
writes `"tags": {"macos": […]}` and fails pre-commit/CI. Fix: "The four tier/gating
fields (`priority`, `optional`, `environment`, `install_command`) can be a scalar or a
per-platform object."

### 7. RAILGUARD.md reporting protocol writes through the symlink into an unmanaged working tree — CONFIRMED (sweep)
`agentic-ai/Claude/docs/RAILGUARD.md:81` — step 2 ("Log it below") has an agent in ANY
repo append to `~/.claude/docs/RAILGUARD.md`, i.e. write into the Computer-Setup
checkout on whatever branch is checked out, with no commit/sync step in the protocol.
Entries sit uncommitted, get discarded by checkout/stash, and diverge per machine.
Fix: add step 2b ("commit the log entry in Computer-Setup — or file the upstream issue
first and only link it").

### 8. Managed block's `docs/per-project-allowlist.md` pointer dangles (and now looks resolvable) — CONFIRMED
`agentic-ai/Claude/CLAUDE.md:57` — the file lives in the railguard repo's `docs/`, not
in `agentic-ai/Claude/docs/` (only RAILGUARD.md there); the new `~/.claude/docs`
symlink makes the bad path look intentional. Fix belongs in the fork's block template
(repo-qualify the link) or vendor the doc into `agentic-ai/Claude/docs/`.

### 9. RAILGUARD.md: "install.sh symlinks everything into ~/.claude" is materially wrong — CONFIRMED
`agentic-ai/Claude/docs/RAILGUARD.md:16` — settings.json is **copied** (by design, with
a re-copy after `railguard install`), and railguard.yaml links to `~/.railguard.yaml`,
outside `~/.claude`. An agent trusting this edits the live settings expecting repo
propagation. Fix: "symlinks the config (settings.json is copied — see install.sh)".

### 10. `agentic-ai/Claude/README.md` is stale on four counts — CONFIRMED
The "This will:" activation list omits the new `docs/` symlink AND the
`railguard.yaml → ~/.railguard.yaml` link; line 14 claims settings.json is symlinked
(it's copied); the cargo line says "skipped if already installed" (it now hard-fails
without cargo and installs from the fork); the rules-tree description still credits
`rules/common/railguard.md` with the full enforced-rules/rollback detail that moved to
`docs/RAILGUARD.md`, which the README never mentions.

### 11. "Writing files"/"Policy layers" sections may be wiped by the next `railguard install` — PLAUSIBLE
`agentic-ai/Claude/CLAUDE.md:18,52` — these sit inside the `railguard:start/end`
auto-managed block. Evidence conflicts: one verifier matched them to the fork's
`defaults/CLAUDE.md` template; the sweep grepped the *installed binary* and the
generator source and found neither section emitted. If the binary regenerates the block
without them, both sections silently vanish from the repo file (via the symlink) on the
next install.sh run. Confirm by diffing the fork's current template against the block;
if they're hand-edits, move them outside the block or upstream them into the template.

### 12. Slim rule mislabels force-push as plain "(ask)" — PLAUSIBLE
`agentic-ai/Claude/rules/common/railguard.md:6` — main/master force-push is
hard-blocked; the rule now affirmatively says "(ask)". An agent promised an ask that
gets a block may retry/reword (evasion escalation), though the always-loaded
never-retry rule mitigates. Fix: "(ask; hard-block on main/master)" — 5 words.

### 13. Slim rule dropped "blocked for real ACCESS → never retry in any form" — PLAUSIBLE
`agentic-ai/Claude/rules/common/railguard.md:7` — only the mention-vs-access remediation
survives always-loaded. An agent misdiagnosing a real fenced-path access block as the
known text-scan FP "remediates" via Read/Write against the fenced path. Partially
backstopped (Railguard intercepts those tools too). Fix: append "if the command truly
accesses the path, don't retry in any form".

### 14. Cross-agent verify/security trigger conditions stranded in the Claude-only overlay — CONFIRMED (altitude)
Root `CLAUDE.md:9-14` — *when* a four-platform dry-run or a security pass is required
(changes to setup.sh/lib/platforms/packages.json; .env handling, install_command shell
execution, path/network code) binds any agent, but lives only in the Claude overlay as
/skill triggers; AGENTS.md (whose own header says "keep cross-agent guidance here") has
no equivalent obligation. opencode/Codex commit those changes unchecked. Fix: state the
conditions in AGENTS.md Conventions; keep only the skill-name mapping in CLAUDE.md.

### 15. Gated-command inventory hand-maintained in three places, drift already realized — CONFIRMED (reuse)
Slim rule bullet 2, managed block "Do NOT attempt to", and RAILGUARD.md "Rules it
enforces" all restate what `railguard.yaml` + the validate hooks own. Realized drift:
the gnupg contradiction (#3), the gcloud omission, and none of the three mention the
yaml's `~/Github` allowed root. Fix: keep ONE prose copy (the on-demand doc), reduce
the always-loaded copy to categories + "policy: railguard.yaml".

## Below the cut (noted, not counted)

- **AGENTS.md Coding conventions ≈ global rules files** (~250 tokens duplicated per
  Claude prompt in this repo; no canonical owner — will drift like #15). Deliberate
  cross-agent tradeoff; consider a generation step or a "mirrors global rules" marker.
- **FP-log protocol has no pruning step** — when railguard#17/#18 are fixed, the log
  entries and promoted habit lines persist forever (permanent workaround tax).
- **`ollie-pi4` hostname in AGENTS.md** contradicts its own Privacy rule — but it's
  committed in 6 tracked files on main already; either carve out the rule or scrub
  repo-wide (decide once, not per-PR).
- **Tool-list mismatch** (doc says Bash/Read/Write/Edit/Memory; managed block says 4) —
  the doc side is *correct* (fork hooks all tools via empty matcher + has a memory
  subsystem); fix the upstream template.
- Minor: linux-pi described twice in AGENTS.md (~35 tokens); root CLAUDE.md stub
  restates AGENTS.md's self-description (~20 tokens); RAILGUARD.md states the
  Write-workaround ~5-7×; `check_symlink` compares uncanonicalized `readlink` (false
  fails only under mismatched path spellings).

## Refuted along the way

- "`ulises-c` username violates the privacy rule" — it's the public GitHub org handle,
  present in ~20 tracked URLs incl. install.sh's cargo source; the rule targets
  machine/personal identifiers.
- "install.sh comment narrates WHAT" — matches the file's established header-comment
  style (5 identical-pattern siblings).
- "RAILGUARD.md's `rules/common/railguard.md` reference doesn't resolve relatively" —
  prose filename, not a link; the doc supplies `~/.claude` context and the rule is
  always in-context anyway.
- "Slim rule dropped rm -rf/terraform/DROP TABLE/env-dump warnings" — acceptable
  reactive placement; the dangerous post-block encode case is still always-loaded.
