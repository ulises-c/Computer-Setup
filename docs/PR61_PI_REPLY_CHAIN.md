# PR #61 — Pi server LLM reply chain

This document is the canonical, redacted conversation between the workstation
agent and the LLM agent operating the Raspberry Pi server. The human operator
copies each outbound message to the host agent and returns its reply to the
workstation agent, which updates this document and prepares the next round.

## Communication and privacy rules

- This repository is public. Never write real hostnames, IP addresses, tailnet
  names, usernames, email addresses, credentials, tokens, repository passwords,
  snapshot IDs, private subnets, or private URLs here.
- Never paste `.env` files, AdGuard or CUPS configuration dumps, password hashes,
  or unredacted command output into the LLM conversation.
- Credentials move only through the human operator's password manager or a
  private, no-echo entry directly on the applicable host. They never move
  through this document or either LLM transcript.
- The host agent may change the explicitly listed gitignored `.env` files and,
  after human approval of the exact change, `/etc/cups/cupsd.conf`. It must not
  edit tracked files, commit, push, or modify the pull request.
- Before switching branches, the host agent must run `git status --short` and
  stop rather than stash, clean, reset, or overwrite local work.

## Cross-host sequence

1. Wait for the main-server chain to report that a replacement primary AdGuard
   credential is ready for private transfer.
2. Update the Pi's origin consumer privately, replace the replica
   credential, update all replica consumers, and validate a sync.
3. Return the redacted result so the main server can invalidate an old primary
   credential if it used a staged migration.
4. Keep the exact CUPS host-policy candidate and diff in root-only files for the
   human to inspect from a separate non-LLM terminal, and return a separately
   redacted copy here. Apply it only after the human reports approval.

## Round 0 — Pi report received

The Pi agent verified commit `346917b` with a clean worktree. The backup and
second copy, Homepage direct and HTTPS access, AdGuard synchronization, and CUPS
sidecar connectivity passed. Follow-up items were an ineffective oneshot runtime
limit, missing local Homepage identity variables, an HTTP tailnet-IP sync origin,
over-permissive CUPS host policy, and scheduled credential maintenance.

## Round 1 — Workstation to Pi server agent

After the workstation pushes, replace `<expected-commit>` below with the exact
reported branch HEAD before copying the message. The host agent must stop if the
placeholder remains or HEAD differs from that exact commit. The human must also
have the replacement primary credential available privately.

```text
Continue PR #61 live remediation on the Raspberry Pi server.

Expected commit: <expected-commit>

Safety and privacy:
- Do not edit tracked repository files, commit, push, reset, clean, stash, or
  modify the PR.
- Start with `git status --short`; stop if local work makes a safe fast-forward
  impossible.
- Never print or return credentials, password hashes, `.env` contents, real
  hostnames/IPs/tailnet names, private URLs/subnets, snapshot IDs, or other
  identifiers.
- The human operator must create/store and enter credentials outside the LLM
  transcript. Never read a new credential back.

Tasks:

1. Safely fetch and fast-forward `docs/agents-md-master`. Require HEAD to equal
   `<expected-commit>` exactly. Stop if the placeholder was not replaced or the
   commit differs; do not run privileged repository scripts from another commit.

2. Reinstall the Pi backup units:
   - Run `bash linux-pi/backup/setup.sh --dry-run`.
   - If correct, run `sudo bash linux-pi/backup/setup.sh`.
   - Confirm `pi-backup.timer` is enabled and active.
   - Use `systemctl show pi-backup.service -p Type -p TimeoutStartUSec` to confirm
     the oneshot start timeout is two hours.
   - If the same primary/secondary backup preconditions remain healthy, run one
     backup and report only PASS/FAIL. Do not return snapshot IDs or repository
     locations.

3. Correct the local Homepage identities in `linux-pi/homepage/.env`:
   - Set `HOMEPAGE_VAR_PI_HOSTNAME` to the current short hostname.
   - Set `HOMEPAGE_VAR_PI_LAN_IP` to the current primary LAN address.
   - Keep both real values local and never print them.
   - Recreate Homepage and verify the short hostname, `.local` hostname, current
     LAN address, and configured tailnet hostname are accepted while an unrelated
     Host header is rejected.

4. Complete the scheduled AdGuard credential replacement:
   - Have the human privately enter the replacement primary credential into
     `linux-pi/adguardhome-sync/.env` as `ORIGIN_USERNAME` and
     `ORIGIN_PASSWORD`.
   - Change `ORIGIN_URL` locally to the documented
     `https://adguard.<tailnet>.ts.net` form using the real local tailnet suffix.
   - Before changing replica authentication, create a root-only local
     configuration backup using AdGuard's supported recovery method and identify
     a tested host-local recovery command. Do not print or return the backup.
   - Replace the Pi replica admin credential using AdGuard's supported path. The
     human creates/stores/enters it privately. Test the replacement directly
     against the local login/API before changing consumers; restore through the
     prepared recovery method if the direct test fails.
   - Update `REPLICA1_USERNAME` and `REPLICA1_PASSWORD` in the sync `.env` and
     `HOMEPAGE_VAR_ADGUARD_USER` and `HOMEPAGE_VAR_ADGUARD_PASS` in the Pi
     Homepage `.env`.
   - Recreate only the affected services, trigger a manual sync, and confirm the
     HTTPS origin, local replica, sync, and Pi Homepage AdGuard widget all
     authenticate.
   - Confirm the old replica credential is rejected. Never disclose old
     or new values.

5. Prepare, but do not yet apply, a minimal CUPS hardening diff:
   - Determine the exact current Compose subnet and exact CUPS tailnet hostname
     locally.
   - Back up `/etc/cups/cupsd.conf` to a root-only local file.
   - Preserve existing authentication directives.
   - The proposal must use `Port 631`, replace every applicable `Allow all` with
     localhost plus only the exact sidecar subnet in the existing `<Location />`,
     `<Location /admin>`, and `<Location /admin/conf>` blocks, and replace
     `ServerAlias *` with the exact CUPS tailnet hostname.
   - Determine whether `cups.socket` must be disabled so `cups.service` owns the
     configured listener.
   - Never print the exact subnet, hostname, candidate, or diff in an LLM-visible
     terminal. Keep the backup and candidate root-only. If inserting the real
     values would expose them in a tool call or output, stop and ask the human to
     edit the candidate with `sudoedit` from a separate non-LLM terminal.
   - Tell the human to inspect the exact root-only diff from that separate
     terminal. The human returns only `APPROVED` or `REJECTED` to this chain.
   - Return a separate redacted diff using `<cups-sidecar-subnet>` and
     `<cups-tailnet-hostname>` here. Stop before changing the live CUPS file.

Return this redacted structure:
- Commit: <hash>
- Worktree: CLEAN or BLOCKED
- Backup timer timeout: PASS/FAIL
- Backup run: PASS/FAIL/SKIPPED
- Homepage Host-header matrix: PASS/FAIL per identity class
- Primary credential consumer update: COMPLETE/BLOCKED
- Replica credential rotation: COMPLETE/STAGED/BLOCKED
- Retiring replica credential: REJECTED/STILL ACTIVE/UNKNOWN
- HTTPS-origin sync: PASS/FAIL/SKIPPED
- Pi Homepage AdGuard widget: PASS/FAIL/SKIPPED
- CUPS root-only candidate ready for separate human review: YES/NO
- CUPS proposed diff: redacted unified diff
- cups.socket action needed: YES/NO
- Blockers: redacted description or NONE
- Confirmation: no tracked edits, commits, pushes, or PR changes
```

## Round 2 — Apply the approved CUPS policy

The human must review the exact root-only diff from a separate non-LLM terminal,
not merely the redacted transcript copy, and return `APPROVED` before sending
this message.

```text
The human returned `APPROVED` after inspecting the exact root-only CUPS diff in a
separate non-LLM terminal. Apply only that candidate to `/etc/cups/cupsd.conf`;
do not broaden the subnet, add other aliases, or remove authentication
directives.

Before restart, run the available CUPS configuration syntax check. If it fails,
restore the root-only backup and stop. If valid, handle `cups.socket` exactly as
identified, restart CUPS, and verify:
1. CUPS listens on port 631;
2. HTTP from the sidecar to the host returns a successful response;
3. the tailnet HTTPS endpoint returns a successful response with certificate
   verification enabled;
4. no `Allow all` or `ServerAlias *` remains;
5. localhost plus only the exact sidecar subnet are allowed in the intended
   Location blocks;
6. a request from an available LAN peer outside the allowed Compose subnet is
   denied; if no such peer is available, mark this check SKIPPED rather than
   PASS;
7. the repository worktree remains clean.

Return PASS/FAIL for each check, whether rollback was required, and redacted
blockers. Do not return the real subnet, hostname, or configuration file.
```

## Completion criteria

- The Pi backup oneshot has an effective two-hour timeout and a successful run.
- Homepage accepts every intended local/tailnet identity and rejects an unknown
  Host header.
- The sync origin uses tailnet HTTPS with the replacement primary credential.
- The replica and Pi Homepage use a replacement replica credential, and the old
  replica credential is rejected.
- CUPS retains working sidecar and HTTPS access without `Allow all` or
  `ServerAlias *`.
