# TODO

## Validate safeguards

After a fresh install, run each check to confirm hooks and railguard are wired correctly.

### Hooks

- [ ] `validate-bash.sh` — blocked patterns exit 2: `rm -rf /`, `sudo`, `git add -A`, `curl | sh`, force-push to main
- [ ] `validate-write.sh` — writes to `~/.ssh/`, `/etc/` blocked (exit 2); project paths allowed (exit 0)
- [ ] `post-edit-shellcheck.sh` — fires after shell script edits and blocks on shellcheck errors
- [ ] `post-test-runner.sh` — auto-detects test suite and runs after source edits; exits 2 on failure
  - **uv projects**: `.claude/test-cmd` must use `uv run --no-sync pytest`, not bare `uv run pytest`. Without `--no-sync`, every edit triggers `uv sync` which reverts out-of-band package installs (e.g. ROCm torch back to CUDA torch). Consider patching `post-test-runner.sh` to inject `--no-sync` when it detects `uv run` in the resolved test command.
- [ ] `driftcheck.sh` — flags `.sh` files missing execute permission or shebang at session end

### Railguard

- [ ] `railguard memory verify` — no integrity warnings at session start
- [ ] Path fence blocks writes to `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `/etc`
- [ ] Traces appear in `.railguard/traces/` after a session
- [ ] Snapshots appear in `.railguard/snapshots/` after Write/Edit calls
- [ ] `railguard-config-edit-2` rule fires on edits to railguard policy content

## Sandbox

Revisit `sandbox.enabled` once the upstream seccomp/AF_UNIX issue is resolved.

- Upstream: [#44180](https://github.com/anthropics/claude-code/issues/44180) — seccomp BPF blocks `AF_UNIX`, breaking `gpg-agent` and `ssh-agent`
- [ ] Re-enable sandbox after upstream fix and test on CachyOS
- [ ] Verify GPG commit signing still works with sandbox on
- [ ] Verify SSH push to GitHub/Bitbucket/Forgejo still works
- [ ] Re-evaluate whether `validate-write.sh` path fence is redundant with sandbox on
