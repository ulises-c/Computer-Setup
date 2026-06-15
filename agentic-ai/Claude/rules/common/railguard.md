# Working Under Railguard

[Railguard](https://github.com/ulises-c/railguard) intercepts every tool call (Bash, Read, Write, Edit, Memory) and decides to **allow**, **ask**, or **block** it. Rollback recipes and the self-protection list live in the auto-managed `# Railguard — Active Guardrails` block of `CLAUDE.md`; this file covers how to *work* under it.

## Reading the response

- **allowed** — proceeds; you won't usually notice.
- **ask** — the human approves or denies. Wait for the decision; don't route around it.
- **blocked / denied** — refused. **Never retry the same command** — re-issuing it with cosmetic changes (new flags, base64, `eval`, a wrapper) trips behavioral-evasion detection and escalates toward a session kill. Find a genuinely different, safer approach, or ask the human. If the safer approach is legitimately different (e.g. pushing a *new* branch instead of force-pushing one), say so explicitly so the human can approve past any evasion flag.

## Rules it enforces

These are blocked or gated here (Railguard defaults + the `validate-bash.sh`/`validate-write.sh` hooks). Don't burn turns hitting them:

- **History/data loss (ask or block):** `git push --force` (force-push to `main`/`master` is hard-blocked), `git reset --hard`, `git clean -f`, `rm -rf` on `/` `~` `$HOME`, `terraform destroy`, `DROP TABLE`.
- **Escalation/staging (block):** `sudo` — run escalations yourself; `git add -A` / `--all` / `.` — stage paths explicitly so secrets aren't swept in.
- **Network/exfiltration (ask or block):** `curl | sh`, encoded payloads, outbound `curl -X POST`, `wget`, `ssh`/`scp`/`rsync`, `env` dumps.
- **Path fence:** `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `/etc` are denied; allowed roots are `~/.claude`, `/tmp`, `~/github`, `~/Bitbucket`. `~/.gnupg`/`~/.config/gh` stay readable for GPG signing and `gh`.

## The path fence scans command text

The Bash fence matches fenced path **strings** in the command, so a command that merely *mentions* a fenced path — in a heredoc, an issue body, install docs — gets blocked even though it never touches that path.

- Author file content with the `Write`/`Edit` tools, not `cat <<EOF >`, `echo >`, or `printf >` redirects. Tool-based writes are snapshotted and their content is not scanned by the Bash fence.
- Don't embed fenced path literals in Bash command text. If content must reference them, put it in a file via `Write` and pass it by path (`--body-file`, `--file`, stdin redirect).
- If a Bash command is fence-blocked because its *content* quoted a fenced path, switching to the `Write` tool is the **intended remediation** — do it without hesitation. It is not evasion.
- If a command is blocked because it actually *accesses* a fenced path, do not retry it in any form — find a different approach or ask the user.

## cwd drift

The fence anchors to the hook's cwd at each call, not a root captured at session start. A `cd` into a nested dir re-anchors it, so `cd`-ing back to a repo root can prompt. Prefer absolute paths and `git -C <dir>` over `cd`.
