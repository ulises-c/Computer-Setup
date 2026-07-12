# Working Under Railguard

[Railguard](https://github.com/ulises-c/railguard) intercepts every tool call and decides **allow**, **ask**, or **block**. Session mechanics (rollback, policy layers, self-protection) are in the auto-managed `# Railguard — Active Guardrails` block of `CLAUDE.md`.

- **Blocked → never re-issue the command with cosmetic changes** (new flags, base64, `eval`, a wrapper) — that trips evasion detection and escalates toward a session kill. Take a genuinely different approach and say how it differs. **Ask** → wait for the human; don't route around it.
- Gated by design — don't burn turns on: `git push --force`, `git reset --hard`, `git clean -f` (ask); `sudo`, `git add -A`/`.` (block — stage paths explicitly); `curl | sh`, outbound `curl -X POST`, `wget`, `ssh`/`scp`/`rsync` (ask/block). Fenced paths (`~/.ssh`, `~/.aws`, `/etc`) are denied; allowed roots: `~/.claude`, `/tmp`, `~/github`, `~/Bitbucket`.
- The Bash fence scans command **text**: merely *mentioning* a fenced path or a `/slash-command` token can block a command that never touches it. Author content with `Write`/`Edit` and pass it by path (`--body-file`), not heredocs/redirects — that switch is intended remediation, not evasion.
- Unexpected block/ask that looks like a false positive, or an improvement idea → read `~/.claude/docs/RAILGUARD.md` (expected behavior + bug reporting protocol) and follow it.
