# Working Under Railguard

Railguard's path fence scans Bash command **text** for fenced path strings (`/etc`, `~/.ssh`, `~/.aws`, ...). A command that merely *mentions* a fenced path in content — a heredoc, an issue body, install docs — gets blocked even though it never touches that path.

- Author file content with the `Write`/`Edit` tools, not `cat <<EOF >`, `echo >`, or `printf >` redirects. Tool-based writes are snapshotted by Railguard and their content is not scanned by the Bash path fence.
- Don't embed fenced path literals in Bash command text. If content must reference them, put it in a file via `Write` and pass it by path (`--body-file`, `--file`, stdin redirect).
- If a Bash command is fence-blocked because its *content* quoted a fenced path, switching to the `Write` tool is the **intended remediation** — do it without hesitation. It is not evasion.
- If a command is blocked because it actually *accesses* a fenced path, do not retry it in any form — find a different approach or ask the user.
