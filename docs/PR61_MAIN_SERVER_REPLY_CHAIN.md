# PR #61 — Main server LLM reply chain

This document is the canonical, redacted conversation between the workstation
agent and the LLM agent operating the main Ubuntu server. The human operator
copies each outbound message to the host agent and returns its reply to the
workstation agent, which updates this document and prepares the next round.

## Communication and privacy rules

- This repository is public. Never write real hostnames, IP addresses, tailnet
  names, usernames, email addresses, credentials, tokens, repository passwords,
  snapshot IDs, or private URLs here.
- Never paste `.env` files, AdGuard configuration dumps, password hashes, or
  unredacted command output into the LLM conversation.
- Credentials move only through the human operator's password manager or a
  private, no-echo entry directly on the applicable host. They never move
  through this document or either LLM transcript.
- The host agent may change the explicitly listed gitignored `.env` files and
  host configuration. It must not edit tracked files, commit, push, or modify
  the pull request.
- Before switching branches, the host agent must run `git status --short` and
  stop rather than stash, clean, reset, or overwrite local work.

## Cross-host sequence

1. Main server rotates or stages replacement credentials for the primary
   AdGuard and updates its local consumers.
2. The human operator transfers the replacement primary credential privately to
   the Pi. The Pi updates the sync origin and validates replication.
3. If the old primary credential remained active for a staged migration, the
   main server invalidates it after the Pi reports a successful sync.

The retiring credential must not remain active after the coordinated migration.

## Round 0 — Main server report received

The server agent verified commit `346917b` with a clean worktree. UPS services,
backup and runner-status timers, Forgejo runner status, Glances 4.5.4, the local
Glances API, the HTTPS sidecar, and stable disk aliases passed. The only server
verification failure was an unprivileged read of the intentionally protected
NUT configuration file. Actual NUT services and `upsc` were healthy. UPS ntfy
delivery was not confirmed.

## Round 1 — Workstation to main server agent

After the workstation pushes, replace `<expected-commit>` below with the exact
reported branch HEAD before copying the message. The host agent must stop if the
placeholder remains or HEAD differs from that exact commit.

```text
Continue PR #61 live remediation on the main Ubuntu server.

Expected commit: <expected-commit>

Safety and privacy:
- Do not edit tracked repository files, commit, push, reset, clean, stash, or
  modify the PR.
- Start with `git status --short`; stop if local work makes a safe fast-forward
  impossible.
- Never print or return credentials, password hashes, `.env` contents, real
  hostnames/IPs/tailnet names, private URLs, or other identifiers.
- The human operator must create/store replacement credentials outside the LLM
  transcript and enter them privately. Never read a new credential back.

Tasks:

1. Safely fetch and fast-forward `docs/agents-md-master`. Require HEAD to equal
   `<expected-commit>` exactly. Stop if the placeholder was not replaced or the
   commit differs; do not run privileged repository scripts from another commit.

2. Re-run unprivileged server verification:
   `bash verify.sh --platform server`
   Confirm the former NUT `MODE=standalone` permission false-negative is gone.
   Report the PASS/FAIL counts and redacted evidence that the driver, server,
   monitor, and `upsc cyberpower@localhost ups.status` checks pass.

3. Coordinate replacement of the primary AdGuard admin/API
   credential using AdGuard's supported credential-change path:
   - Inventory local consumers by variable name only; do not print values.
   - Before changing authentication, create a root-only local configuration
     backup using AdGuard's supported backup/recovery method and identify a
     tested host-local recovery command. Do not print or return the backup.
   - Have the human generate/store and enter the replacement credential outside
     the transcript.
   - Update the primary AdGuard credential, then test the replacement directly
     against the local login/API before changing consumers or retiring the old
     credential. Restore through the prepared recovery method if direct
     replacement authentication fails.
   - After direct authentication passes, update
     `linux-server/homepage/.env` keys `HOMEPAGE_VAR_ADGUARD_USER` and
     `HOMEPAGE_VAR_ADGUARD_PASS` locally.
   - Recreate/restart only the server Homepage service as needed and confirm its
     AdGuard widget authenticates.
   - Verify the old credential is rejected unless it must remain briefly
     active for a supported staged migration. If it remains active, report state
     `STAGED`; do not disclose either credential.
   - Tell the human privately that the same replacement primary credential must
     be entered on the Pi in `linux-pi/adguardhome-sync/.env` as
     `ORIGIN_USERNAME` and `ORIGIN_PASSWORD`.

4. If safe, send one ordinary UPS test notification. Do not simulate battery,
   power-loss, forced-shutdown, or low-battery events. Report only whether the
   notification was received.

Return this redacted structure:
- Commit: <hash>
- Worktree: CLEAN or BLOCKED
- Server verify: PASS/FAIL and counts
- NUT functional checks: PASS/FAIL
- Primary credential rotation: COMPLETE/STAGED/BLOCKED
- Retiring primary credential: REJECTED/STILL ACTIVE/UNKNOWN
- Server Homepage AdGuard widget: PASS/FAIL/SKIPPED
- UPS ntfy delivery: PASS/FAIL/SKIPPED
- Pi private handoff ready: YES/NO
- Blockers: redacted description or NONE
- Confirmation: no tracked edits, commits, pushes, or PR changes
```

## Round 2 — Finalize a staged primary rotation

Use this only if Round 1 returns `STAGED`. Wait until the Pi chain reports that
the HTTPS origin authenticates and a sync succeeds with the replacement primary
credential.

```text
The Pi has confirmed that the replacement primary credential authenticates over
the documented tailnet HTTPS origin and that a sync succeeds. Invalidate the
old primary credential now using AdGuard's supported credential-change
path. Do not print either credential or any private identifier.

Then verify:
1. the old credential is rejected;
2. the replacement credential still works;
3. the server Homepage AdGuard widget still works;
4. the repository worktree remains clean.

Reply only with PASS/FAIL for those four checks plus redacted blockers.
```

## Completion criteria

- Server verification passes without reading protected NUT configuration.
- Primary AdGuard replacement credential works for the server Homepage.
- The old primary credential is rejected.
- The Pi confirms a successful HTTPS-origin sync with the replacement
  credential.
- Optional UPS notification delivery is recorded without simulating an outage.
