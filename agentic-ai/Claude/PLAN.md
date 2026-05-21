# Claude Code Config — Roadmap

Tracks future improvements to `agentic-ai/Claude/`. Current state: `bypassPermissions` + OS sandbox + PreToolUse/PostToolUse/Stop hooks.

---

## Done (in this branch)

- `bypassPermissions` + `validate-bash.sh` / `validate-write.sh` PreToolUse hooks
- `post-edit-shellcheck.sh` PostToolUse hook
- `driftcheck.sh` Stop hook
- Hierarchical rules (`rules/common/`, `rules/bash/`)
- OS-level sandbox via bubblewrap (`setup-linux-sandbox.sh`)
- GPG signing + `gh api` enabled: `~/.gnupg` and `~/.config/gh` in `allowWrite`, not in `denyRead`
- Hook fixes: `set -euo pipefail` + `trap 'exit 2' ERR` on all hook scripts
- Fix `cat | jq` anti-pattern in `validate-bash.sh`
- Fix `read` on empty files in `driftcheck.sh`
- README corrected: accurate `denyRead` docs, security tradeoffs section added

---

## Near-term

### 1. Verify GPG agent socket access inside sandbox

GPG signing depends on communicating with `gpg-agent` via a Unix socket at `/run/user/$UID/gnupg/S.gpg-agent`. Bubblewrap may or may not expose this path depending on how Claude Code constructs the bwrap invocation.

**To verify:** run `git commit --allow-empty -S -m "gpg test"` inside a Claude session and confirm it succeeds without prompts. If it fails, determine whether `/run/user/$UID/gnupg/` needs to be explicitly bind-mounted by patching the Claude Code sandbox config or using `SSH_AUTH_SOCK`-style forwarding.

### 2. Credential pre-resolution via 1Password (optional hardening)

Instead of giving the sandbox read access to `~/.config/gh/hosts.yml`, resolve `GH_TOKEN` at shell startup and inject it as an env var. This removes the OAuth token from the sandbox's readable filesystem.

```bash
# ~/.zshrc — only outside Claude sessions
if [[ -z "${CLAUDE_SESSION:-}" ]]; then
  export GH_TOKEN=$(op read op://Personal/github-cli/credential 2>/dev/null || true)
fi
```

Then `gh` uses the env var and `~/.config/gh` can go back into `denyRead`. Requires 1Password CLI (`op`).

Reference: [Making Claude Code Actually Work Autonomously](https://www.linkedin.com/pulse/making-claude-code-actually-work-autonomously-sandbox-daniel-dimitrov-2khnf)

### 3. Railguard evaluation

[Railguard](https://github.com/railyard-dev/railguard) is a per-command policy engine that sits between Claude and tool execution (~2ms decision latency). Uses bwrap on Linux. Key capabilities beyond what we have:

- Pipe analysis + evasion detection (catches obfuscated commands our regex misses)
- Write/Edit content inspection for secrets in the payload itself
- Memory write classification: detects behavioral injection, tampering between sessions via content hashing
- Per-edit rollback, session replay

**Evaluation path:** `railguard install`, run a session, review its audit log, compare its catch rate against `validate-bash.sh` on a test command corpus. If it catches more than our hooks without adding friction, adopt and simplify the hook layer.

### 4. `enableWeakerNetworkIsolation` — explicit decision needed

Claude Code offers this flag to allow Go-based CLI tools (`gh`, etc.) to verify TLS certificates via `com.apple.trustd.agent` on macOS. On Linux, Go uses system CAs directly so this is a no-op for us. Leave unset.

Reference: [Fixing gh CLI in Claude Code's sandbox](https://zencoder.ai/blog/fixing-gh-cli-in-claude-codes-sandbox)

---

## Longer-term

### 5. Network allowlist

Currently, the sandbox prompts for any new outbound domain. A future improvement: maintain an explicit allowlist of trusted domains in `settings.json` (`api.github.com`, `registry.npmjs.org`, etc.) and block unknown domains outright rather than prompting. Reduces interruptions without opening the network broadly.

### 6. Per-project sandbox overrides

Some projects need broader write access (e.g., a Docker-based project writing to `/var/lib/...` via `docker`). Mechanism: project-level `.claude/settings.json` with additive `allowWrite` entries that merge with the user-level config.

### 7. `validate-bash.sh` regex hardening

Current patterns are line-oriented and can be bypassed with multi-statement commands. Potential improvements:

- Parse compound commands (`;`, `&&`, `||`, `$()` subshells) rather than matching the raw string
- Flag `base64 -d | sh` and similar encoding-based execution patterns
- Flag `python -c`, `node -e`, `perl -e` with inline exec patterns

At some point this becomes a reimplementation of Railguard — see item 3 above.

### 8. PostToolUse: test runner hook

Pattern from [Claude Code settings article](https://dev.to/shimo4228/stop-using-default-settings-10-claude-code-configs-that-actually-work-243l): after edits to test-eligible files, run the relevant test suite. `{"decision": "block"}` on failure forces Claude to fix before continuing.

Needs per-project configuration (test command varies by project type). Could use a `CLAUDE_TEST_CMD` env var or a `.claude/test-cmd` file per project.
