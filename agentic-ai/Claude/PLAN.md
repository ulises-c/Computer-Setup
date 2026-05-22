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

### 2. Railguard evaluation — COMPLETE (paper evaluation, 2026-05-22)

[Railguard](https://github.com/railyard-dev/railguard) is a per-command policy engine that intercepts every Claude tool call. Source reviewed at v0.4.0. No live install performed — see integration conflicts below.

#### What railguard adds over our current hooks

| Capability | Our hooks | Railguard |
|---|---|---|
| Block destructive bash patterns | `validate-bash.sh` regex | Policy engine: allow/block/approve per named rule |
| Block writes to sensitive paths | `validate-write.sh` | Path fence: extracts paths from commands (handles pipes, subshells) |
| Encoding/obfuscation detection | Not covered | Tier 1: catches `base64 -d \| sh`, `eval`, `chr()`, inline exec patterns |
| Behavioral evasion detection | Not covered | Tier 3: detects re-attempt of previously blocked command with different syntax |
| Memory write classification | Not covered | Memory guard: blocks API keys in memory, requires approval for behavioral instruction injection |
| Per-edit rollback | Not covered | Snapshot every Write/Edit; `railguard rollback --steps N` |
| Audit trail | Not covered | `.railguard/traces/` structured log per session |
| Session termination | Not covered | Terminates session on repeated high-threat patterns; requires human approval to resume |
| Self-protection | Not covered | Blocks writes to `~/.claude/settings.json` and railguard binary |
| OS-level sandbox | Disabled (see #44180) | railguard-shell (see Linux conflict below) |

Railguard is strictly better at the hook layer. `validate-bash.sh` + `validate-write.sh` would be replaceable.

#### Linux OS sandbox conflict (same outcome as #44180)

railguard-shell is a separate binary Claude Code runs as its shell via `CLAUDE_CODE_SHELL`. On Linux ≥ 5.13 (this machine: kernel 6.17), `detect_sandbox()` returns `LinuxLandlock` and `exec_linux_sandbox` wraps every Bash command in bwrap with:

```
--tmpfs /tmp          # wipes SSH agent sockets (/tmp/ssh-*/agent.*)
--tmpfs ~/.gnupg      # wipes GPG keyring
# /run not mounted    # GPG agent socket (/run/user/$UID/gnupg/) unreachable
```

This breaks GPG commit signing and SSH push — same workflow impact as the disabled built-in sandbox (#44180), via filesystem namespacing instead of seccomp BPF. **railguard-shell is a non-starter on this machine** until the credential access problem is solved (GPG and SSH agent sockets need to be accessible inside the sandbox).

The hook-based detection layer (threat classifier, memory guard, policy engine) is independent of railguard-shell and works without it.

#### Installation conflicts with this repo's structure

`railguard install` writes directly to `~/.claude/settings.json`, which in this setup is a **symlink to the repo**. Three problems:

1. **Hook overwrite**: installs only railguard's three hooks (PreToolUse, PostToolUse, SessionStart), replacing `post-edit-shellcheck` and `driftcheck`. Those would need re-adding.
2. **`CLAUDE_CODE_SHELL` env**: writes the railguard-shell path into `settings.json` — activates the broken Linux sandbox automatically.
3. **CLAUDE.md injection**: appends `<!-- railguard:start --> ... <!-- railguard:end -->` to `~/.claude/CLAUDE.md`, which is also a symlink to the repo.

All three write through symlinks into tracked repo files. An install would need to be followed by selective reverting.

#### No pre-built binary for Linux

v0.4.0 release has no Linux asset. Installation requires `cargo install railguard`. Rust toolchain not currently present.

#### Recommendation

**Adopt the hook layer, skip railguard-shell.**

When ready to integrate:

1. `cargo install railguard` (or `rustup` + `cargo`)
2. Run `railguard install` in a throw-away config dir first: `CLAUDE_CONFIG_DIR=/tmp/rg-test railguard install`, inspect the output settings.json
3. Manually merge railguard's three hooks into `settings.json` alongside `post-edit-shellcheck` and `driftcheck` — do not let railguard overwrite them
4. Set `fence.enabled: false` in `railguard.yaml` to disable railguard-shell (prevents `CLAUDE_CODE_SHELL` from activating bwrap)
5. Update `railguard.yaml`'s `denied_paths` to remove `~/.gnupg` and `~/.config/gh` (we manage those at the hook layer)
6. Add `.railguard/` to `.gitignore` (traces and snapshots are per-session, not repo state)

Revisit railguard-shell when either: (a) upstream #44180 ships and AF_UNIX is unblocked, or (b) railguard adds a `--share-path /run/user/$UID` option to its bwrap invocation.

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
