# Claude Code Config

Version-controlled source of truth for `~/.claude/` settings and hooks. Running `install.sh` wires everything up via symlinks so changes here take effect immediately.

## Activation

```bash
bash agentic-ai/Claude/install.sh
```

This will:
- Back up your existing `~/.claude/settings.json` (if not already a symlink)
- Symlink `~/.claude/settings.json` → this `settings.json`
- Symlink each `hooks/*.sh` script into `~/.claude/hooks/`

Restart Claude Code after running.

> **Note:** `settings.json` sets `bypassPermissions` at the user level, so it applies to **all projects**, not just this repo.

## What this configures

### `bypassPermissions`
Claude auto-approves all tool calls without prompting. The hooks below act as the safety gate.

### Hook: `validate-bash.sh` (Bash)
Blocks accidental destructive shell commands:
- `rm -rf` on `/` or `~` / `$HOME`
- `dd` targeting a device node
- `mkfs` (filesystem format)
- Redirect to block device (`> /dev/sdX`)
- Piped shell execution (`curl ... | sh`)
- Force-push to `main`/`master`

### Hook: `validate-write.sh` (Write / Edit / MultiEdit)
Blocks writes to sensitive file paths:
- `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `~/.config/gh`
- `/etc/`, `/usr/`, `/boot/`, `/sys/`, `/proc/`

Hooks use **exit 2** to block — Claude receives the stderr message as the reason.

## Testing the hooks

```bash
# Should exit 2 (blocked)
echo '{"tool_input":{"command":"rm -rf /"}}' | bash agentic-ai/Claude/hooks/validate-bash.sh
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

## Adding settings

All user-level Claude Code settings live here going forward. Edit `settings.json` directly — the symlink means changes are live immediately (no re-run of `install.sh` needed).
