# OpenCode Config

Version-controlled source of truth for `~/.config/opencode/opencode.json`.
Running `install.sh` wires everything up via symlinks so changes here take
effect immediately.

## Activation

```bash
bash agentic-ai/OpenCode/install.sh
```

This will:
- Back up your existing `~/.config/opencode/opencode.json` (if not already a symlink)
- Symlink `~/.config/opencode/opencode.json` → this `opencode.json`
- Symlink `bin/opencode-local` → `~/.local/bin/opencode-local`

Restart OpenCode after running.

## Usage

### Launch with model picker

```bash
opencode-local
```

This scans `~/.models/` for MLX model directories, lets you pick one, starts
the server, waits for it to be ready, then launches OpenCode. The server
shuts down automatically when you exit OpenCode.

Pass through additional OpenCode flags:

```bash
opencode-local --model anthropic/claude-sonnet-4-6
```

### Launch manually

```bash
mlx_lm.server --model ~/.models/mlx-community--Qwen3.5-9B-4bit &
opencode
# kill %1 when done
```

### Model selection in OpenCode

Once connected to a server, select the model via:

```
/models
```

Pick `mlx/mlx-community/Qwen3.5-9B-4bit` (or whichever model the server has
loaded).

## Recommended models

| Machine | Model | Notes |
|---------|-------|-------|
| Mac Mini M4 | **Qwen 3.5 9B (4bit)** — `~/.models/mlx-community--Qwen3.5-9B-4bit` | MLX-optimized, already on this machine |
| CachyOS / AMD R9700 AI PRO | **Gemma 4** / **Qwen 3.6** (larger variants) | Powerful AMD GPU — test these on the desktop |

## Usage alongside Claude

OpenCode supplements Claude Code for:
- **Small, fast edits** that don't need Claude's full context
- **Exploratory work** on unfamiliar code
- **Offline-capable tasks** when you're not connected
- **Private/air-gapped work** where code shouldn't leave the machine

Claude Code handles complex multi-file refactors, architecture decisions,
and heavy debugging.

## What this configures

### MLX provider

Registers `mlx_lm.server` (OpenAI-compatible endpoint at
`http://127.0.0.1:8080/v1`) as a provider with pre-configured model entries.
Add or remove models by editing `opencode.json` directly — the symlink means
changes are live immediately after restarting OpenCode.

### `opencode-local` command

A wrapper script that scans `~/.models/` for MLX model directories, presents
a picker, starts the server, and launches OpenCode. On exit, the server is
cleaned up automatically.
