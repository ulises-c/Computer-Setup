@AGENTS.md

## Claude Code

The section above is imported from `AGENTS.md` — the shared instruction set for
all agents. Everything there applies. Below are Claude-Code-only notes for this
repo:

- **`/verify` before committing** changes to `setup.sh`, `lib/`, `platforms/`, or
  `packages.json`: exercise `setup.sh --dry-run` across all four platforms. Only
  one platform can run live here, so dry-run parity is the real test — don't claim
  live verification for the others.
- **`/security-review` before committing** changes to `.env` handling, `custom`
  `install_command` shell execution, or any path/network code.
