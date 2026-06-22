# Session Handoff

Scratchpad for in-progress work that spans more than one session — live
infrastructure state, decisions made outside of code, and what's next.
Branch-specific; delete or trim entries once they're fully landed and the
branch merges.

## 2026-06-17 — Forgejo HTTPS-over-Tailscale, live on ollie-server

Branch: `refactor/server-streamline-divergence` (PR [#47](https://github.com/ulises-c/Computer-Setup/pull/47))

`linux-server/HTTPS.md` (added in `8ff8a2c`, on a different machine) documents
per-service HTTPS via a Tailscale sidecar per service. This session executed
that plan for Forgejo on the actual server (`ollie-server`) and documented two
gotchas hit along the way.

**Code changes (committed, this session):**
- `linux-server/HTTPS.md` — resolved the auth-method decision (OAuth client +
  `tag:container`, not a reusable key); documented the ACL-tag gotcha and a
  network-namespace gotcha that will recur for every other service conversion
- `TODO.md` — added a tracked checklist for the 11 remaining services + 2 open
  decisions (NPM retire/keep, Homepage sidecar vs. main-node)
- `SSH_and_GPG/create_ssh_key.sh` + `README.md` — the self-hosted-server SSH
  port was hardcoded to `2222` (Forgejo's old host-published mapping); now
  prompts with default `22`, matching the sidecar setup. Verified live with
  `ssh-keyscan -p 22 forgejo.<tailnet>.ts.net`.

**Live state on `ollie-server` (not in git):**
- `linux-server/forgejo/.env`: `TS_AUTHKEY` set to the (now read+write-scoped)
  `tailscale-proxy` OAuth client secret; `FORGEJO_DOMAIN=forgejo.<tailnet>.ts.net`
- `forgejo-ts` + `forgejo` containers running under the new sidecar
  `docker-compose.yml`; old host-published ports (`3300`, `2222`) are gone
- Verified: `https://forgejo.<tailnet>.ts.net/` → `200`; SSH banner on `:22`
- Tailscale admin console changes (made by the user, not visible in this repo):
  existing `tailscale-proxy` OAuth client elevated from read-only to
  read+write scope; `tag:container` added to the tailnet ACL's `tagOwners`
  (owner: `autogroup:admin`)

**Not done yet:**
- Existing git remotes pointing at the old `http://...:3300` / `ssh://...:2222`
  Forgejo address still need updating to `git@forgejo.<tailnet>.ts.net:user/repo.git`
  (on every machine that had a clone, not just this one)
- Forgejo Site Administration → confirm the app URL picked up the new `ROOT_URL`
- Continue the rollout: Portainer is next per the `TODO.md` table
