@rules/common/general.md
@rules/common/agents.md
@rules/common/railguard.md
@rules/bash/style.md

# Agents

Shared global instruction set for every coding agent (Claude Code, Codex,
opencode). `install.sh` symlinks this file and `rules/` into `~/.claude/`,
`~/.codex/`, and `~/` — imports resolve against the deployed directory, so both
must sit beside each instruction file.

Railguard's auto-injected guardrail block is deliberately not kept here (no
railguard start/end HTML comment markers in this file — an unpaired one would
confuse its injector). `railguard install` writes and maintains that block
per-tool, currently in `Claude/CLAUDE.md`. Duplicating it here would both
double-load for Claude, which imports this file, and go stale: the copy that
used to live here was the old long-form block, while railguard now writes a much
slimmer one. Cross-agent railguard guidance lives in
`rules/common/railguard.md`.
