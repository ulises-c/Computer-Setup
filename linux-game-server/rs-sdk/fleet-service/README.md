# Fleet service (rs-fleet-service)

The single source of truth for the bot fleet, shared by every bot host (the bot workstation, later
the other bot hosts) and the portal. It holds the safety gate (fleet pause, per-bot
latches, the systemic rule, local stops, archives), bot pinning, the accounts table and the
append-only datasets (journals, NPC aggression, benchmarks, deaths, observations). It is a
small bun HTTP service with a SQLite database (WAL). The design, API and cutover plan are in
the bot repo: `2004Scape-Botting/docs/fleet-service.md`.

Phase 1: the bot hosts' files are still authoritative. The service is filled by a one-shot
import, `push`, and the bot repo's `FLEET_SERVICE_MIRROR=1` shadow writes. Nothing reads from
it yet.

| | |
|---|---|
| URL | `https://<host>.<tailnet>.ts.net:9447` (tailnet only; `tailscale serve --https=9447`) |
| Container | `rs-fleet-service`, published on `127.0.0.1:8100` only |
| Data | `~/.local/share/rs-fleet-service/data/fleet.sqlite` |
| Tokens | `~/.config/rs-fleet-service/service.env` (`FLEET_TOKENS=host=token,...,portal:ro=token`, mode 600) |
| Limits | read-only rootfs (+16 MB `/tmp`), `cap_drop: ALL`, `no-new-privileges`, 256 MB, 0.5 CPU, 64 pids, healthcheck `/healthz` |

```sh
bash linux-game-server/rs-sdk/fleet-service/install.sh     # build, (re)start, tailscale serve :9447
bash linux-game-server/rs-sdk/fleet-service/uninstall.sh   # stop and remove the container and :9447 (data and tokens kept)
docker logs rs-fleet-service
```

`install.sh` keeps existing tokens and adds a token for any missing bot
host (plus `portal:ro`). Each bot host keeps its own token in
`~/.config/rs-fleet/token` (mode 600). Copy it there without printing it.

`fleet-service.js` is generated. Don't edit it. To update it, run this in the bot repo:
`scripts/fleet-service-bundle.sh <this dir>/fleet-service.js`, then rerun `install.sh`. The
file's header names the source commit. The image is pinned by digest to the bun the bot hosts
use.

Backup: `backup/sources.sh` lists the data directory, so the nightly game backup takes an
online `sqlite3 .backup` of `fleet.sqlite`. The root-installed copy only picks this up after
`sudo bash linux-game-server/backup/setup.sh`. That's an owner step: until it's done, the
service isn't backed up. In phase 1 that's harmless, because the service can be rebuilt with
`bun tools/fleet-service.ts import` from the files.
