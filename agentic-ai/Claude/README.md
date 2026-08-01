# Claude Code Config

Version-controlled source of truth for `~/.claude/` settings, hooks, rules, and
on-demand docs, plus the hook scripts shared with Codex. Running `install.sh`
copies the Claude settings template and links the shared configuration.

## Activation

**Wire up the config:**
```bash
bash agentic-ai/Claude/install.sh
```

This will:
- Back up your existing `~/.claude/settings.json` when it differs from the template
- Copy this `settings.json` to `~/.claude/settings.json`
- Symlink `~/.claude/CLAUDE.md` → this `CLAUDE.md`
- Symlink `AGENTS.md` + `rules/` → `../AGENTS.md` and `../rules/` in
  `~/.claude/`, `~/.codex/`, and `~/` (the shared cross-agent set)
- Symlink `~/.claude/docs/` → this `docs/`
- Symlink this `railguard.yaml` → `~/.railguard.yaml`
- Symlink each `hooks/*.sh` script into both `~/.claude/hooks/` and
  `~/.codex/hooks/`
- Merge the custom hook registrations into `~/.codex/hooks.json` while
  preserving unrelated hooks
- Install or update the Railguard fork with
  `cargo install --git https://github.com/ulises-c/railguard` (requires
  Rust/cargo; an existing binary is kept with a warning when cargo is unavailable)
- Run `railguard install` to register it as a global PreToolUse hook

Restart both Claude Code and Codex after running so each reloads its hook
configuration.

> **Note:** `settings.json` sets `bypassPermissions` at the user level, so it applies to **all projects**, not just this repo.

## What this configures

The hook scripts below are deployed for both Claude Code and Codex. Claude hook
registration lives in `settings.json`; the installer idempotently merges the
custom registrations into `~/.codex/hooks.json` after Railguard registers its
own hooks, preserving unrelated entries.

### `bypassPermissions`
Claude auto-approves all tool calls without prompting. The hooks below act as the safety gate.

### Sandbox
`sandbox.enabled` is currently **disabled**. Claude Code's Linux sandbox uses seccomp BPF to block all `AF_UNIX` socket calls — this breaks `gpg-agent` (required for commit signing) and `ssh-agent` (required for SSH push to GitHub, Bitbucket, Forgejo, etc.). Upstream issue [#44180](https://github.com/anthropics/claude-code/issues/44180) tracks the fix. The `denyRead`/`allowWrite` filesystem config is preserved in `settings.json` for re-enablement once the issue is resolved.

The hooks below are the primary safety layer.

### PreToolUse: `railguard` (all tools)

Runtime policy enforcer installed globally from the Railguard fork by `install.sh`.
Policy lives in `railguard.yaml`; custom command blocklists are left empty because
`validate-bash.sh` owns those patterns.

- **Path fence**: applies the denied and allowed roots declared in `railguard.yaml`
- **Traces**: every tool call logged to `.railguard/traces/`
- **Snapshots**: pre-edit state captured for Write/Edit to `.railguard/snapshots/`
- **Memory integrity**: session-start warns on untracked memory files (`railguard memory verify`)

### PreToolUse: `validate-bash.sh` (Bash)
Blocks dangerous or escalation-prone shell commands:
- `rm -rf` on `/` or `~` / `$HOME`
- `dd` targeting a device node
- `mkfs` (filesystem format)
- Redirect to block device (`> /dev/sdX`)
- Piped shell execution (`curl ... | sh`)
- Force-push to `main`/`master`
- `sudo` (escalation must be explicit — run yourself)
- `git add -A`, `git add --all`, `git add .` (bulk staging can silently include secrets)

### PreToolUse: `validate-write.sh` (Write / Edit / MultiEdit / apply_patch)
Blocks writes to sensitive file paths:
- `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.config/gh`
- `/etc/`, `/usr/`, `/boot/`, `/sys/`, `/proc/`

### PostToolUse: `post-edit-shellcheck.sh` (Write / Edit / MultiEdit / apply_patch)
After any shell script edit, runs `shellcheck --severity=error`. Exits 2 if errors are found, forcing Claude to fix them before continuing.

Skips gracefully if `shellcheck` is not installed.

### PostToolUse: `post-test-runner.sh` (Write / Edit / MultiEdit / apply_patch)

After any source file edit, auto-detects and runs the project test suite. Detection order: `.claude/test-cmd` override → `Cargo.toml` → `go.mod` → `pyproject.toml`/`pytest.ini` → `package.json` → `Makefile`. Skips non-source extensions (md, json, yaml, etc.) and projects with no recognized test suite.

Exits 2 on test failure (Claude sees the output) or timeout (60 s). Exits 0 silently on pass, printing timing to stderr.

### Stop: `driftcheck.sh`
At session end, reports convention drift across all git-tracked `.sh` files:
- Execute permission set
- Shebang line present

Drift is a **nudge, not a block**: findings go out as hook JSON
(`{"systemMessage": …}`) with exit 0, so Claude is free to stop. A style check
shouldn't be able to trap the agent into "fixing" a false positive — repos whose
convention legitimately differs exempt paths via glob patterns in
`~/.claude/hooks/driftcheck-ignore` (global) or `<repo-root>/.driftcheckignore`.

Exit 1 means the check itself couldn't run (`git ls-files` failed, `HOME`
unset). That path is deliberately loud: a guard that reports "all clear" without
having looked is worse than one that errors.

The other hooks use **exit 2** to block — Claude receives the stderr message as
the reason.

## Rules (Tip 6 hierarchical structure)

`CLAUDE.md` imports `@AGENTS.md`, which imports from `rules/` — both live one
level up in `agentic-ai/`, shared with Codex and opencode:

```
agentic-ai/
  AGENTS.md        — shared cross-agent instruction set (imports the rules below)
  rules/
    common/
      general.md   — language-agnostic coding principles
      agents.md    — when to self-invoke Plan / Explore / review / verify
      railguard.md — slim always-loaded Railguard behavior and reference routing
    bash/
      style.md     — bash scripting conventions
  Claude/
    CLAUDE.md      — imports @AGENTS.md, then Claude-Code-only notes
    docs/
      RAILGUARD.md             — expected behavior and bug-reporting protocol
      per-project-allowlist.md — local path-allowlist configuration
```

Add a new language by creating `rules/<lang>/style.md` and adding an `@` line to
`AGENTS.md` (cross-agent) or `CLAUDE.md` (Claude-only).

### Why AGENTS.md and rules/ are symlinked into three places

Claude Code resolves `@` imports against the **deployed** directory of the
importing file, and does **not** follow `../`. Verified behavior:

| Import form | Resolves? |
|---|---|
| `@rules/common/general.md` (at or below the file's dir) | yes |
| `@../AGENTS.md` (parent) | **no** |
| through a symlinked file | relative to the **symlink's** dir, not its target |

So every location holding an instruction file needs `AGENTS.md` and `rules/`
beside it. This is why the pre-existing untracked `~/AGENTS.md` was inert: its
`@rules/common/*` lines pointed at a `~/rules/` that never existed.

## Testing the hooks

Run the repeatable Codex benchmark first. It exercises fixed Railguard and
custom-hook protocol cases in a disposable Git repository, emits TAP with
per-case timings, and exits nonzero on any regression. It does not execute the
dangerous commands in its fixtures or modify live Codex configuration.

```bash
# Benchmark the installed binary
bash agentic-ai/Claude/benchmark-codex-hooks.sh

# Run the identical cases against a development build
RAILGUARD_BIN=/path/to/railguard/target/debug/railguard \
  bash agentic-ai/Claude/benchmark-codex-hooks.sh

# Validate deployed hook links and registrations separately
bash agentic-ai/Claude/validate.sh
```

The commands below remain useful for quick, individual hook probes:

```bash
# Should exit 2 (blocked)
echo '{"tool_input":{"command":"rm -rf /"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
echo $?

# Should exit 2 (blocked — sudo)
echo '{"tool_input":{"command":"sudo apt install foo"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
echo $?

# Should exit 2 (blocked — bulk staging)
echo '{"tool_input":{"command":"git add -A"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
echo $?

# Should exit 2 (blocked — redirect to sensitive path)
echo '{"tool_input":{"command":"echo foo > ~/.ssh/config"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
echo $?

# Should exit 0 (allowed)
echo '{"tool_input":{"command":"ls -la"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
echo $?

# Should exit 2 (blocked)
echo '{"tool_input":{"file_path":"/Users/<username>/.ssh/authorized_keys"}}' | bash agentic-ai/Claude/hooks/validate-write.sh
echo $?

# Should exit 0 (allowed)
echo '{"tool_input":{"file_path":"/Users/<username>/github/project/main.py"}}' | bash agentic-ai/Claude/hooks/validate-write.sh
echo $?
```

## Security model

With the sandbox disabled, Claude runs with your user's full filesystem access — the same security surface as Cursor, Copilot, or any terminal session. The hooks are the primary guardrail layer.

**`validate-write.sh`** still blocks Claude's Write/Edit tools from touching `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, and system paths. Bash commands can read those paths, which is intentional — GPG signing and `gh api` both require it.

**`validate-bash.sh`** blocks catastrophic shell commands regardless of filesystem access.

The operative trust model: `bypassPermissions` + hooks is a guardrail against accidental damage, not a zero-trust vault. Per-device SSH/GPG keys are the credential strategy — key material stays on the machine, not in a vault.

## Adding settings

All user-level Claude Code settings originate here. Edit the template, then re-run
`install.sh` to copy it into place. Claude Code may rewrite the live copy with
machine-specific state; `settings-drift.sh` reports meaningful differences.
