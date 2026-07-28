@AGENTS.md

# Claude Code

The section above is imported from the shared global `AGENTS.md` — the
instruction set for every agent (Claude Code, Codex, opencode). Everything there
applies. Keep cross-agent guidance in `AGENTS.md`, not here; this file is only
for things that apply to Claude Code and nothing else.

`@AGENTS.md` is a sibling import on purpose: Claude Code resolves `@` paths
relative to the *deployed* location of the importing file and will not follow
`../`, so `install.sh` symlinks both `AGENTS.md` and `rules/` into `~/.claude/`
next to this file.

<!-- railguard:start -->
# Railguard - Active Guardrails

Railguard monitors every tool call in this session: allow, ask, or block. If a command is blocked, do NOT re-issue it with cosmetic changes (new flags, encoding, wrappers) - take a genuinely different approach. On ask, wait for the human. File writes are snapshotted and can be rolled back.

Full agent guide (rollback commands, policy customization, path-fence quirks, self-protection): run `railguard guide`.

<!-- railguard:end -->
