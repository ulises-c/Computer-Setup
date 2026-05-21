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
- **Disabled bwrap sandbox** (`sandbox.enabled: false`): seccomp BPF unconditionally blocks all `AF_UNIX` socket calls on Linux (upstream issue [#44180](https://github.com/anthropics/claude-code/issues/44180), no fix timeline). This breaks GPG commit signing and SSH agent — both required for multi-VCS workflows with signed commits. Hooks remain the primary safety layer; `denyRead`/`allowWrite` config is preserved for re-enablement when #44180 is resolved.
- **Per-device SSH/GPG keys**: keys are generated per machine, not stored in a password manager. Passphrases (if any) may be stored in a vault, but key material stays on-device.
- **`denyWrite` entries added**: `/etc`, `/usr`, `/boot`, `/sys`, `/proc` in sandbox `filesystem.denyWrite`. Staged for when #44180 ships; has no effect while `sandbox.enabled: false`.
- **GH_TOKEN in `install.sh`**: `install.sh` now prompts for a GitHub PAT. When provided, `~/.claude/settings.json` is written as a generated file (not a symlink) with `env.GH_TOKEN` merged in, keeping the token out of the repo. When sandbox is re-enabled, also move `~/.config/gh` back into `denyRead`.

---

## Near-term

### 1. Re-enable sandbox when upstream fixes AF_UNIX blocking

The bwrap sandbox adds meaningful defense-in-depth: kernel-level filesystem isolation that hooks cannot replicate. Worth re-enabling when feasible.

**Blocker:** [#44180](https://github.com/anthropics/claude-code/issues/44180) — seccomp BPF unconditionally blocks AF_UNIX sockets on Linux. No config workaround. Blocks both `gpg-agent` (commit signing) and `ssh-agent` (SSH push), which are hard requirements.

**When #44180 ships:** flip `sandbox.enabled` to `true`. The `denyRead`/`allowWrite` filesystem config is already in place. Run `git commit --allow-empty -S` and `git push` to verify GPG signing and SSH agent both work before closing.

**Evaluated alternatives (both ruled out for personal dev workflows):**

- **Docker sandbox** ([docs](https://docs.docker.com/ai/sandboxes/agents/claude-code/)) — containerized Claude Code; credentials live entirely outside the container via OAuth proxy. Designed for untrusted-code execution. No SSH agent or GPG forwarding supported by design.
- **NVIDIA AI Workbench** ([docs](https://docs.nvidia.com/ai-workbench/user-guide/latest/quickstart/quickstart-claude-sandbox.html)) — bwrap + socat dual-layer isolation; `enableWeakerNestedSandbox: true` for running inside Docker (avoids nested namespace issues). Still blocks credential access. Relevant if Claude Code ever runs inside a container on this setup.

Both approaches trade credential access for stronger isolation — appropriate for CI/CD or multi-tenant setups, not personal dev machines requiring GPG signing over SSH remotes.

### 2. Railguard evaluation

[Railguard](https://github.com/railyard-dev/railguard) is a per-command policy engine that sits between Claude and tool execution (~2ms decision latency). Uses bwrap on Linux. Key capabilities beyond what we have:

- Pipe analysis + evasion detection (catches obfuscated commands our regex misses)
- Write/Edit content inspection for secrets in the payload itself
- Memory write classification: detects behavioral injection, tampering between sessions via content hashing
- Per-edit rollback, session replay

**Evaluation path:** `railguard install`, run a session, review its audit log, compare its catch rate against `validate-bash.sh` on a test command corpus. If it catches more than our hooks without adding friction, adopt and simplify the hook layer.

### 3. `enableWeakerNetworkIsolation` — explicit decision needed

Claude Code offers this flag to allow Go-based CLI tools (`gh`, etc.) to verify TLS certificates via `com.apple.trustd.agent` on macOS. On Linux, Go uses system CAs directly so this is a no-op for us. Leave unset.

Reference: [Fixing gh CLI in Claude Code's sandbox](https://zencoder.ai/blog/fixing-gh-cli-in-claude-codes-sandbox)

### 4. `enableWeakerNestedSandbox` for container deployments

If Claude Code ever runs inside a Docker container, bwrap cannot create user namespaces (nested namespaces are blocked). NVIDIA's config adds `enableWeakerNestedSandbox: true` to fall back to reduced-capability mode that maintains isolation without nested namespaces. Not needed today but document it for when container-based workflows come up.

Reference: [NVIDIA AI Workbench — Claude sandbox config](https://docs.nvidia.com/ai-workbench/user-guide/latest/quickstart/quickstart-claude-sandbox.html), [Docker Claude Code sandbox](https://docs.docker.com/ai/sandboxes/agents/claude-code/)

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

At some point this becomes a reimplementation of Railguard — see item 2 above.

### 8. PostToolUse: test runner hook

After edits to test-eligible files, run the relevant test suite. `{"decision": "block"}` on failure forces Claude to fix before continuing. Needs per-project configuration (test command varies by project type). Could use a `CLAUDE_TEST_CMD` env var or a `.claude/test-cmd` file per project.

---

## References

- [Stop Using Default Settings — 10 Claude Code Configs That Actually Work](https://dev.to/shimo4228/stop-using-default-settings-10-claude-code-configs-that-actually-work-243l)
- [Fixing gh CLI in Claude Code's Sandbox](https://zencoder.ai/blog/fixing-gh-cli-in-claude-codes-sandbox)
- [Making Claude Code Actually Work Autonomously with Sandbox](https://www.linkedin.com/pulse/making-claude-code-actually-work-autonomously-sandbox-daniel-dimitrov-2khnf)
- [Railguard — per-command policy engine for Claude Code](https://github.com/railyard-dev/railguard)
- [Docker Claude Code Sandbox](https://docs.docker.com/ai/sandboxes/agents/claude-code/)
- [NVIDIA AI Workbench — Claude Code Quickstart](https://docs.nvidia.com/ai-workbench/user-guide/latest/quickstart/quickstart-claude-sandbox.html)
