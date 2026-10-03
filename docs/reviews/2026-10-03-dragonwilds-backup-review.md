# Dragonwilds pre-update backup review

- Date: 2026-10-03
- Repository: `ulises-c/Computer-Setup`
- Branch: `feat/server-base`
- Commit reviewed: `25f1f2325a8222b3b09a401988b2a1491a0dcfae`
- Review type: independent adversarial background review
- Delegation: `deleg_aa251fd4`
- Reviewer model: not exposed by the delegation result
- Verdict: PASS

## Scope

The review checked the staged Dragonwilds backup/update implementation for:

- systemd ordering and synchronous backup execution;
- clean-stop evidence and fail-closed behavior;
- root-owned backup executor bundles and status paths;
- fixed Dragonwilds and Forgejo path capture;
- helper hash pinning and checkout/environment redirection;
- host-specific backup-unit allowlists;
- direct installer coverage;
- timeout budgets, tests, and documentation parity.

## Changes reviewed

- Added a root-run `dragonwilds-pre-update-backup.service` gate before SteamCMD.
- Kept `AUTO_UPDATE_RESTART=false` semantics unchanged.
- Installed backup executors and helpers outside the writable checkout.
- Captured authoritative paths during setup and restored protected unit values after bundle environment loading.
- Moved backup status state under `/var/lib/computer-setup-backup/`.
- Pinned the copied Dragonwilds save helper with SHA-256.
- Rejected invalid or drifting paths and non-host backup service targets.
- Added direct-installer backup protection.
- Recorded unclean Dragonwilds stops under `/run/dragonwilds/stop-failure` and blocked the next start until acknowledged.
- Added regression tests, backup-engine coverage, documentation, and rendered-unit validation.

## Verification

- 42 Python tests: passed.
- Backup engine tests: passed.
- Bash syntax checks: passed.
- ShellCheck: passed.
- Backup setup dry-runs for server, game server, and Pi: passed.
- Rendered units on `ollie-game-server`: `systemd-analyze verify` passed.
- `git diff --cached --check`: passed.

## Review result

No security concerns or logic errors were found. The reviewer suggested adding a native Linux/systemd integration test in the future. The implementation was committed and pushed; deployment remained a separate privileged step.

## Discord delivery

Discord delivery was attempted on 2026-10-03 but could not complete because the available browser session was logged out, no saved Discord login was available, and headless browser sessions cannot request a new login. The review is stored here until Discord access is available.
