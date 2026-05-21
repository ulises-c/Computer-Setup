# Claude Code Config

Version-controlled source of truth for `~/.claude/` settings, hooks, and rules. Running `install.sh` wires everything up via symlinks so changes here take effect immediately.

## Activation

**Linux only — one-time OS setup (Ubuntu 24.04+ requires this):**
```bash
sudo apt-get install bubblewrap socat
bash agentic-ai/Claude/setup-linux-sandbox.sh
```
CachyOS/Arch: `yay -S bubblewrap socat` — no AppArmor step needed.

**Then wire up the config:**
```bash
bash agentic-ai/Claude/install.sh
```

This will:
- Back up your existing `~/.claude/settings.json` (if not already a symlink)
- Symlink `~/.claude/settings.json` → this `settings.json`
- Symlink `~/.claude/CLAUDE.md` → this `CLAUDE.md`
- Symlink `~/.claude/rules/` → this `rules/`
- Symlink each `hooks/*.sh` script into `~/.claude/hooks/`

Restart Claude Code after running.

> **Note:** `settings.json` sets `bypassPermissions` at the user level, so it applies to **all projects**, not just this repo.

## What this configures

### `bypassPermissions`
Claude auto-approves all tool calls without prompting. The sandbox and hooks below act as the safety gate.

### Sandbox (OS-level isolation)
Enforced by bubblewrap (Linux) / Seatbelt (macOS) at the kernel level — not bypassable from inside a process.

- **Filesystem**: write access limited to the current working directory by default; reads to `~/.ssh` and `~/.aws` are blocked. `~/.gnupg` and `~/.config/gh` are readable and writable — required for GPG commit signing and `gh api` (see [Security tradeoffs](#security-tradeoffs) below)
- **Network**: prompts before connecting to any new domain
- **`allowUnsandboxedCommands: false`**: disables the escape hatch so Claude cannot retry blocked commands outside the sandbox

The sandbox covers **Bash commands and all their child processes** (npm, terraform, kubectl, etc.). The Write/Edit/MultiEdit tools are not sandboxed — they go through the hooks below instead.

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

## Security tradeoffs

**`~/.gnupg` and `~/.config/gh` are intentionally readable inside the sandbox.**

GPG signing (`git commit -S`) requires reading the keyring at `~/.gnupg`. `gh api` requires reading the OAuth token at `~/.config/gh/hosts.yml`. Both require write access as well (temp files, token refresh). Putting either in `denyRead` would break those workflows.

The tradeoff: an autonomous agent with `gh api` access effectively has access to your GitHub token. The `validate-write.sh` hook blocks Claude from using Write/Edit tools to modify those paths directly, but Bash commands can still read them. This is the deliberate operating model — `bypassPermissions` + sandbox is a trust boundary, not a zero-trust vault.

**`~/.ssh` and `~/.aws` stay in `denyRead`** because there is no autonomous use case that requires reading SSH private keys or AWS credentials directly — those are user-controlled operations.

## Adding settings

All user-level Claude Code settings live here going forward. Edit `settings.json` directly — the symlink means changes are live immediately (no re-run of `install.sh` needed).
