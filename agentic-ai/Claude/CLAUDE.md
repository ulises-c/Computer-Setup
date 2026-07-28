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
