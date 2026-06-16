# Claude Code Config

Version-controlled source of truth for `~/.claude/` settings, hooks, and rules. Running `install.sh` wires everything up via symlinks so changes here take effect immediately.

## Activation

**Wire up the config:**
```bash
bash agentic-ai/Claude/install.sh
```

This will:
- Back up your existing `~/.claude/settings.json` (if not already a symlink)
- Symlink `~/.claude/settings.json` → this `settings.json`
- Symlink `~/.claude/CLAUDE.md` → this `CLAUDE.md`
- Symlink `~/.claude/rules/` → this `rules/`
- Symlink each `hooks/*.sh` script into `~/.claude/hooks/`
- Install `railguard` via `cargo install railguard` (requires Rust/cargo; skipped if already installed)
- Run `railguard install` to register it as a global PreToolUse hook

Restart Claude Code after running.

> **Note:** `settings.json` sets `bypassPermissions` at the user level, so it applies to **all projects**, not just this repo.

## What this configures

### `bypassPermissions`
Claude auto-approves all tool calls without prompting. The hooks below act as the safety gate.

### Sandbox
`sandbox.enabled` is currently **disabled**. Claude Code's Linux sandbox uses seccomp BPF to block all `AF_UNIX` socket calls — this breaks `gpg-agent` (required for commit signing) and `ssh-agent` (required for SSH push to GitHub, Bitbucket, Forgejo, etc.). Upstream issue [#44180](https://github.com/anthropics/claude-code/issues/44180) tracks the fix. The `denyRead`/`allowWrite` filesystem config is preserved in `settings.json` for re-enablement once the issue is resolved.

The hooks below are the primary safety layer.

### PreToolUse: `railguard` (all tools)

Runtime policy enforcer installed globally via `cargo install railguard`. Policy lives in `railguard.yaml`; custom blocklist/allowlist are left empty since `validate-bash.sh` owns those patterns.

- **Path fence**: denies access to `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `/etc`; explicitly allows `~/.claude` and `/tmp`
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

### PreToolUse: `validate-write.sh` (Write / Edit / MultiEdit)
Blocks writes to sensitive file paths:
- `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.config/gh`
- `/etc/`, `/usr/`, `/boot/`, `/sys/`, `/proc/`

### PostToolUse: `post-edit-shellcheck.sh` (Write / Edit / MultiEdit)
After any shell script edit, runs `shellcheck --severity=error`. Exits 2 if errors are found, forcing Claude to fix them before continuing.

Skips gracefully if `shellcheck` is not installed.

### PostToolUse: `post-test-runner.sh` (Write / Edit / MultiEdit)

After any source file edit, auto-detects and runs the project test suite. Detection order: `.claude/test-cmd` override → `Cargo.toml` → `go.mod` → `pyproject.toml`/`pytest.ini` → `package.json` → `Makefile`. Skips non-source extensions (md, json, yaml, etc.) and projects with no recognized test suite.

Exits 2 on test failure (Claude sees the output) or timeout (60 s). Exits 0 silently on pass, printing timing to stderr.

### Stop: `driftcheck.sh`
At session end, validates project conventions for all git-tracked `.sh` files:
- Execute permission set
- Shebang line present

Exits 2 if violations found, injecting the list back into Claude's context.

Hooks use **exit 2** to block — Claude receives the stderr message as the reason.

## Rules (Tip 6 hierarchical structure)

`CLAUDE.md` @-imports from `rules/` to keep principles modular:

```
rules/
  common/
    general.md   — language-agnostic coding principles
    agents.md    — when to self-invoke Plan / Explore / review / verify
    railguard.md — how to work under the Railguard guardrails (rules it enforces, path fence, rollback)
  bash/
    style.md     — bash scripting conventions
```

Add a new language by creating `rules/<lang>/style.md` and adding an `@` line to `CLAUDE.md`.

## Testing the hooks

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
echo '{"tool_input":{"file_path":"/Users/ulises/.ssh/authorized_keys"}}' | bash agentic-ai/Claude/hooks/validate-write.sh
echo $?

# Should exit 0 (allowed)
echo '{"tool_input":{"file_path":"/Users/ulises/github/project/main.py"}}' | bash agentic-ai/Claude/hooks/validate-write.sh
echo $?
```

## Security model

With the sandbox disabled, Claude runs with your user's full filesystem access — the same security surface as Cursor, Copilot, or any terminal session. The hooks are the primary guardrail layer.

**`validate-write.sh`** still blocks Claude's Write/Edit tools from touching `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, and system paths. Bash commands can read those paths, which is intentional — GPG signing and `gh api` both require it.

**`validate-bash.sh`** blocks catastrophic shell commands regardless of filesystem access.

The operative trust model: `bypassPermissions` + hooks is a guardrail against accidental damage, not a zero-trust vault. Per-device SSH/GPG keys are the credential strategy — key material stays on the machine, not in a vault.

## Adding settings

All user-level Claude Code settings live here going forward. Edit `settings.json` directly — the symlink means changes are live immediately (no re-run of `install.sh` needed).
