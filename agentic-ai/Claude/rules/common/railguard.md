# Working Under Railguard

[Railguard](https://github.com/ulises-c/railguard) intercepts every tool call and decides **allow**, **ask**, or **block**. Session mechanics (rollback, policy layers, self-protection) are in the auto-managed `# Railguard — Active Guardrails` block of `CLAUDE.md`.

- **Blocked → never re-issue the command with cosmetic changes** (new flags, base64, `eval`, a wrapper) — that trips evasion detection and escalates toward a session kill. If the command truly accessed a protected path or operation, do not retry it in any form. Take a genuinely different approach and say how it differs. **Ask** → wait for the human; don't route around it.
- Destructive history changes, bulk staging, escalation, network/exfiltration, and protected paths are gated by design. Force-pushes to `main`/`master` are hard-blocked, not approval-gated. The exact policy lives in `railguard.yaml` and the validation hooks; `~/.gnupg` and `~/.config/gh` intentionally stay readable for signing and `gh`.
- The Bash fence scans command **text**: merely *mentioning* a fenced path or a `/slash-command` token can block a command that never touches it. Author content with `Write`/`Edit` and pass it by path (`--body-file`), not heredocs/redirects — that switch is intended remediation, not evasion.
- Unexpected block/ask that looks like a false positive, or an improvement idea → read `~/.claude/docs/RAILGUARD.md`, or `agentic-ai/Claude/docs/RAILGUARD.md` in the Computer-Setup repo before reinstalling, and follow its reporting protocol.
