# Sandbox — State, Blockers, and Path Forward

Claude Code's Linux sandbox (`bubblewrap` + seccomp BPF) is **currently disabled** (`sandbox.enabled: false`). This document records why, what was evaluated, and exactly what needs to happen before it can be re-enabled.

---

## What the sandbox provides

When enabled, the sandbox adds kernel-level isolation that hooks alone cannot replicate:

- **`denyRead`** — prevents reading `~/.ssh`, `~/.aws`, and any other sensitive paths even if a hook is bypassed
- **`denyWrite`** — can block Bash-level writes to `/etc`, `/usr`, `/boot`, `/sys`, `/proc` (hooks only cover Write/Edit/MultiEdit tools, not raw shell redirects)
- **Network prompting** — prompts before the agent connects to any new outbound domain
- **Process isolation** — the bwrap mount namespace limits what child processes (npm, terraform, kubectl, etc.) can see and write

Hooks catch dangerous commands; the sandbox catches everything that slips through at the OS level. Disabling it is a meaningful reduction in defense-in-depth, not just a papercut.

---

## The blocker

**Claude Code v2.1.92 bundled the `apply-seccomp` binary**, restoring a seccomp BPF filter that unconditionally blocks all `socket(AF_UNIX, ...)` syscalls inside sandboxed processes.

This kills two hard requirements for personal dev workflows:

| What breaks | Why AF_UNIX | Why it's required |
|---|---|---|
| `gpg-agent` | GPG 2.1+ always communicates with the agent via Unix socket; `--no-use-agent` is a deprecated no-op | Work requires signed commits |
| `ssh-agent` | `SSH_AUTH_SOCK` is a Unix socket; SSH falls back to key file, but `~/.ssh` is in `denyRead` | SSH is the only push method for GitHub, Bitbucket, Forgejo |

There is no per-command seccomp exception. `excludedCommands` bypasses filesystem restrictions only ([#10524](https://github.com/anthropics/claude-code/issues/10524)). `settings.json` seccomp configuration is silently ignored ([#24238](https://github.com/anthropics/claude-code/issues/24238)).

**Upstream tracking:** [#44180 — Linux (bwrap): Add allowUnixSockets / allowAllUnixSockets equivalent for seccomp BPF](https://github.com/anthropics/claude-code/issues/44180). Open, no timeline.

---

## Everything evaluated as a workaround

### `excludedCommands`
Bypasses sandbox **filesystem restrictions** only. The seccomp filter still applies. `git commit -S` and `git push` over SSH still fail. Not a solution.

### `allowUnsandboxedCommands: true`
Equivalent to disabling the sandbox entirely — not a targeted workaround. Also does not bypass seccomp for specific commands.

### `settings.json` seccomp config
Fields like `"seccomp": {}` are silently ignored ([#24238](https://github.com/anthropics/claude-code/issues/24238)). No-op.

### SSH signing format (`gpg.format ssh`) instead of GPG
`git config gpg.format ssh` + `user.signingkey /path/to/key` makes git call `ssh-keygen -Y sign -f <keyfile>` directly — a file read, no socket. This would bypass the seccomp block **for signing** but:
- GPG signatures are required (non-GitHub VCS: Bitbucket, Forgejo, and others do not support SSH-format signatures)
- The SSH login key lives in `~/.ssh` (in `denyRead`), and using a separate signing-only key at a different path would expose private key material to the agent

Not viable given the full set of requirements.

### SSH key file read (no agent, passphraseless key)
With passphraseless keys, SSH can read `~/.ssh/id_*` directly when `SSH_AUTH_SOCK` is unavailable. But `~/.ssh` is in `denyRead`. Moving the push key outside `~/.ssh` would expose private key material to the agent — acceptable blast radius for signing (agent already makes commits), but the GPG signing blocker remains regardless.

### Docker sandbox
Claude Code runs inside a `docker/sandbox-templates:claude-code` container. Credentials live entirely outside the container via an OAuth proxy. **By design:** no SSH agent forwarding, no GPG forwarding, no access to `~/.config/gh`. Appropriate for CI/CD or untrusted-code execution — not for a personal dev machine that needs GPG signing over SSH remotes. Docs: [docs.docker.com/ai/sandboxes/agents/claude-code](https://docs.docker.com/ai/sandboxes/agents/claude-code/).

### NVIDIA AI Workbench
Same bwrap + socat dual-layer stack. Adds `enableWeakerNestedSandbox: true` to handle nested user namespaces when Claude Code runs inside a Docker container (bwrap can't create namespaces inside containers without this). Also actively denies access to credential paths (`~/.claude.json`, `~/.claude/credentials.json`). Solves the "bwrap inside Docker" problem, not the AF_UNIX/seccomp problem. Docs: [docs.nvidia.com/ai-workbench/…/quickstart-claude-sandbox.html](https://docs.nvidia.com/ai-workbench/user-guide/latest/quickstart/quickstart-claude-sandbox.html).

---

## Security model without sandbox

Without bwrap, Claude runs as your user with full filesystem access — the same surface as any terminal session. Protection comes from:

- **`validate-bash.sh`** — blocks `rm -rf /~`, `dd` to devices, `mkfs`, pipe-to-shell, force-push to main, `sudo`, bulk `git add`
- **`validate-write.sh`** — blocks Write/Edit/MultiEdit tools from touching `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/gh`, `/etc`, `/usr`, `/boot`, `/sys`, `/proc`
- **OS file permissions** — Claude runs as your user; it can't access root-owned files regardless

The gap relative to sandbox-enabled: a Bash command like `echo foo > /etc/hosts` bypasses `validate-write.sh` (hooks don't cover shell redirects) and there's no `denyRead` enforcement. These are theoretical risks rather than practical ones on a single-user dev machine, but they're real gaps.

---

## Re-enable checklist

When [#44180](https://github.com/anthropics/claude-code/issues/44180) ships:

1. Check the release notes confirm `allowUnixSockets` (or equivalent) is available on Linux
2. In `settings.json`, flip `"enabled": false` → `"enabled": true`
3. Verify inside a Claude Code session:
   ```bash
   git commit --allow-empty -S -m "sandbox gpg test"   # must sign without prompt
   git push                                              # must push via SSH
   gh api user                                          # must return your GitHub user
   ```
4. If GPG fails: check whether `/run/user/$UID/gnupg/S.gpg-agent` needs to be added to `allowUnixSockets`
5. If SSH fails: check whether `$SSH_AUTH_SOCK` path needs to be in `allowUnixSockets`
6. Once verified: also add `~/.config/gh` back to `denyRead` and configure `GH_TOKEN` in `settings.json` env (see [PLAN.md](PLAN.md) item 2)

The `denyRead`/`allowWrite` filesystem config is already in place in `settings.json` and requires no changes.

---

## `enableWeakerNestedSandbox` — future note

If Claude Code ever runs inside a Docker container on this machine, add this to `settings.json`:

```json
"sandbox": {
  "enabled": true,
  "enableWeakerNestedSandbox": true
}
```

bwrap cannot create user namespaces inside an unprivileged container; this flag falls back to a reduced-capability mode that maintains isolation without nested namespaces. Not needed for bare-metal / VM setups.

---

## Upstream issues to watch

| Issue | Description |
|---|---|
| [#44180](https://github.com/anthropics/claude-code/issues/44180) | **Primary blocker** — Linux: add `allowUnixSockets` equivalent for seccomp BPF |
| [#41817](https://github.com/anthropics/claude-code/issues/41817) | Path-scoped Unix socket support (macOS) — Linux parity likely follows |
| [#10524](https://github.com/anthropics/claude-code/issues/10524) | `excludedCommands` bypasses filesystem only, not seccomp |
| [#24238](https://github.com/anthropics/claude-code/issues/24238) | seccomp config in settings.json silently ignored |
