# Immich

Self-hosted photo and video backup — a Google Photos replacement with iOS/Android
apps that back up the camera roll in the background, a timeline, face and object
search, shared albums, and map view. Served at `https://immich.<tailnet>.ts.net/`
through its own Tailscale sidecar, like the other services (see [`../HTTPS.md`](../HTTPS.md)).

## Why Immich

Compared with the other self-hosted photo apps (as of 2026-09):

| | mobile auto-backup | notes |
| --- | --- | --- |
| **Immich** | first-party iOS + Android | Most active project, closest to Google Photos. Heavier stack (server, ML, Postgres, Valkey) and upgrades occasionally need manual steps |
| Ente | first-party, E2E-encrypted | Best privacy story, but self-hosting means running its S3-backed server and the ML runs on-device. Worth it only if E2E encryption matters more than server-side search |
| PhotoPrism | none (web upload / WebDAV / third-party sync) | Good at browsing an existing library, weak as a phone-backup tool; some features sit behind a paid tier |
| Nextcloud Memories | Nextcloud app | Only makes sense if you already run Nextcloud |
| LibrePhotos | third-party | Smaller project, slower pace |

The job here is backing up phones, so Immich wins. Ente is the one to revisit if
end-to-end encryption becomes a requirement.

## Layout

| container | role |
| --- | --- |
| `immich-ts` | Tailscale sidecar; `tailscale serve` proxies `:443` → `127.0.0.1:2283` |
| `immich-server` | web UI + API, shares the sidecar's netns; Quick Sync via `/dev/dri` |
| `immich-machine-learning` | face / CLIP search models (CPU); model cache in the `model-cache` volume |
| `redis` (`immich-redis`) | Valkey job queue |
| `database` (`immich-postgres`) | Postgres + VectorChord, data in `DB_DATA_LOCATION` (SSD) |

Media goes to `UPLOAD_LOCATION` (the 14TB drive by default). Nothing is published
on host ports — tailnet only, so phones need the Tailscale app running to back up.

Each container gets only the variables it needs (upstream uses `env_file: .env`,
which would hand `TS_AUTHKEY` to the app). Every Immich container carries
`com.centurylinklabs.watchtower.enable=false`: Immich releases can include
breaking changes, so upgrades are manual.

## Deploy

```sh
cd linux-server/immich
cp .env.example .env && chmod 600 .env
# set TS_AUTHKEY and DB_PASSWORD (openssl rand -hex 24); check UPLOAD_LOCATION
sudo mkdir -p /mnt/wd14tb/immich   # match UPLOAD_LOCATION
docker compose up -d
docker compose logs -f immich-ts   # watch the node join + cert provision
```

Not in `setup.sh`'s auto-start loop — like Forgejo, it needs `.env` filled first.

## First run

1. Open `https://immich.<tailnet>.ts.net/` and create the admin account (the
   first sign-up becomes admin).
2. **Administration → Settings → Server → External domain**:
   `https://immich.<tailnet>.ts.net` — used in shared-album links.
3. **Administration → Settings → Video Transcoding → Hardware Acceleration**:
   select **Quick Sync** (the iGPU is already passed through).
4. **Administration → Settings → Backup**: confirm database dumps are enabled
   (default: daily at 02:00, keep 14) — see [Backups](#backups).
5. Homepage widget: **Account Settings → API Keys** → new key with the
   `server.statistics` permission; put it in `homepage/.env` as
   `HOMEPAGE_VAR_IMMICH_KEY`, then `docker compose up -d` in `linux-server/homepage`.
6. Phone: install the Immich app, server URL `https://immich.<tailnet>.ts.net`,
   log in, then turn on backup for the albums you want.

Importing an existing library (e.g. a Google Takeout export) is best done with
[immich-go](https://github.com/simulot/immich-go), which keeps Takeout's
metadata sidecars with the photos.

## Upgrading

```sh
cd linux-server/immich
# read the release notes first: https://github.com/immich-app/immich/releases
docker compose pull && docker compose up -d
```

Minor releases within `IMMICH_VERSION=v3` just pull. For a new major, bump
`IMMICH_VERSION` and diff this compose file against that release's
`docker-compose.yml` — the Postgres and Valkey images are pinned by digest and
upstream moves them between releases.

## Backups

**Not in the nightly restic backup yet** — the library grows without bound and
the restic target is the 1TB drive. Offsite image backup to Amazon Photos is
tracked in [#87](https://github.com/ulises-c/Computer-Setup/issues/87). Until
then, keep the originals on your phones. `immich/.env` (the DB password) is
still captured, since `backup.sh` picks up every service's `.env`.

Immich still writes its own nightly database dump to `UPLOAD_LOCATION/backups/`
(default 02:00, keep 14), which is what a restore needs alongside the originals.

## Networking notes

- The stack adds exactly one Docker bridge (`immich_default`), which gets a `/24`
  from the `172.16.0.0/12` pool that `setup.sh --profile server` pins (see
  [Docker address pools](../README.md#8-docker-address-pools), #75). Bring
  Immich up after that pin is applied; if it was started before, `verify.sh
  --profile server` flags the stray subnet and `docker compose down && docker
  compose up -d` recreates it inside the pool.
- Immich [can't be served under a sub-path](https://docs.immich.app/administration/reverse-proxy/),
  so it keeps `immich.<tailnet>.ts.net` even if services move to
  `<host>.<tailnet>.ts.net/<service>` routing.
- If the sidecar is recreated, restart `immich-server` too — it holds the old
  netns (see the netns gotcha in [`../HTTPS.md`](../HTTPS.md)).
