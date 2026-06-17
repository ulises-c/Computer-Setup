# Per-service HTTPS over Tailscale

Goal: reach every self-hosted service at its own HTTPS URL
(`https://<service>.<tailnet>.ts.net/`) instead of `http://<server-ip>:<port>`.
The immediate driver is Forgejo — git breaks when Forgejo's `ROOT_URL` is HTTP on
a non-standard port.

## Why subdomains require one Tailscale node per service

A Tailscale node has exactly **one** MagicDNS name (`ollie-server.<tailnet>.ts.net`).
You cannot mint arbitrary subdomains of it — `forgejo.<tailnet>.ts.net` only
exists, resolves, and can get a TLS cert if there is a **node named `forgejo`**.

So `<service>.<tailnet>.ts.net` (the layout we want) is achievable exactly one
way: run a small **Tailscale sidecar container per service**, each joining the
tailnet under its own hostname and terminating HTTPS with `tailscale serve`.
This also avoids the subpath breakage (`/forgejo`) that apps like Forgejo and
Portainer suffer under path routing.

NPM cannot produce these names — it can only route hostnames that already
resolve to it and for which it holds a cert. Keep NPM for LAN/`.local` access if
you want; it is orthogonal to the tailnet HTTPS layer below and does **not**
conflict (each sidecar binds `:443` inside its own network namespace / tailnet
IP, not the host's `:443`).

## Architecture (per service)

```
tailnet ──HTTPS:443──▶ [<svc>-ts sidecar]  tailscale serve, owns <svc>.<tailnet>.ts.net + cert
                              │ (shared network namespace via network_mode: service:)
                              ▼
                        [<svc> app]  listens on 127.0.0.1:<app-port>
```

The app container uses `network_mode: service:<svc>-ts`, so it shares the
sidecar's network namespace: `tailscale serve` proxies inbound `:443` to
`127.0.0.1:<app-port>`, and the sidecar sets `X-Forwarded-Proto: https` so the
app generates correct HTTPS URLs.

## Prerequisites (one-time, in the Tailscale admin console)

1. **Enable HTTPS** for the tailnet (DNS → "Enable HTTPS"), so `tailscale serve`
   can provision Let's Encrypt certs for `*.ts.net`.
2. **MagicDNS** enabled (it is, since you resolve `ollie-server.<tailnet>.ts.net`).
3. **An auth method for the sidecars.** Two options — pick one:
   - **OAuth client + tag (recommended, reuses what you have).** You already have
     a Tailscale OAuth client (`tailscale-proxy/.env`). Add a tag (e.g.
     `tag:container`) to the ACL `tagOwners`, grant the OAuth client that tag,
     and pass the client secret as `TS_AUTHKEY` with
     `TS_EXTRA_ARGS=--advertise-tags=tag:container`. Sidecars never expire.
   - **Reusable auth key (simplest).** Generate a *reusable* key in admin →
     Settings → Keys and put it in each service's `.env` as `TS_AUTHKEY`. Watch
     its expiry.
4. **ACL** must allow tailnet → the sidecar nodes on `:443` (HTTPS) and, for git
   over SSH, `:22`. The default allow-all ACL already does; if you've tightened
   it, add a grant for `tag:container`.

## The reusable pattern

Add to a service's `docker-compose.yml` (replace `<svc>` and `<app-port>`):

```yaml
services:
  <svc>-ts:
    image: tailscale/tailscale:latest
    container_name: <svc>-ts
    hostname: <svc>                       # → <svc>.<tailnet>.ts.net
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_SERVE_CONFIG=/config/serve.json
      - TS_EXTRA_ARGS=--advertise-tags=tag:container   # omit if using a plain reusable key
    volumes:
      - ./ts-state:/var/lib/tailscale
      - ./ts-serve.json:/config/serve.json:ro
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
    restart: unless-stopped

  <svc>:
    image: <app-image>
    container_name: <svc>
    network_mode: service:<svc>-ts        # share the sidecar's network namespace
    depends_on: [<svc>-ts]
    # NO `ports:` block — access is via the tailnet, not host ports
    restart: unless-stopped
```

`ts-serve.json` (kernel-mode sidecar; `${TS_CERT_DOMAIN}` is filled by Tailscale
with the node's own MagicDNS name, so this file is identical for every service
except the `<app-port>`):

```json
{
  "TCP": { "443": { "HTTPS": true } },
  "Web": {
    "${TS_CERT_DOMAIN}:443": {
      "Handlers": { "/": { "Proxy": "http://127.0.0.1:<app-port>" } }
    }
  }
}
```

Kernel networking (`/dev/net/tun` + `NET_ADMIN`) is used so the node exposes raw
ports (e.g. SSH `:22`) to the tailnet directly, not only the `:443` serve proxy.

## Applying the Forgejo change (the reference, already implemented)

Forgejo is intentionally **not** in `setup.sh`'s auto-start loop — it needs the
auth key and domain set first. Apply it by hand:

```bash
cd linux-server/forgejo
cp .env.example .env
# edit .env: set TS_AUTHKEY and FORGEJO_DOMAIN=forgejo.<tailnet>.ts.net
docker compose up -d
docker compose logs -f forgejo-ts   # watch the node join + cert provision
```

Then in Forgejo → Site Administration, confirm the app URL, and update any
existing local clones' remotes (see Migration below).

## Git over SSH (Forgejo)

With kernel-mode networking the sidecar's tailnet IP exposes Forgejo's container
`:22` directly, so SSH clones use the standard port:

```
git clone git@forgejo.<tailnet>.ts.net:user/repo.git
```

Set `SSH_DOMAIN=forgejo.<tailnet>.ts.net` and `SSH_PORT=22` (done in the Forgejo
change below). HTTP(S) clone URLs come from `ROOT_URL`.

## Homepage links

`homepage/config/services.yaml` hrefs are plain `http://ip:port` today — that's
why a tile click leaves HTTPS. As each service is converted, change its href to
`https://<svc>.<tailnet>.ts.net/`. Widget `url:` fields stay
`http://localhost:<port>` (homepage talks to containers locally; only the
human-facing `href` changes). Keep homepage itself on the main node (it uses host
networking + the docker socket — a sidecar is awkward there); serve it with
`tailscale serve --bg https / http://127.0.0.1:3000` on `ollie-server`.

## Rollout order and per-service ports

Convert one at a time, verify, then move on. Internal ports (from the homepage
widget configs):

| service           | app port | notes                                            |
|-------------------|----------|--------------------------------------------------|
| forgejo           | 3000     | **done — reference impl**; also exposes SSH :22  |
| portainer         | 9000     | straightforward                                  |
| uptime-kuma       | 3001     | straightforward                                  |
| speedtest-tracker | 8765     | straightforward                                  |
| ntfy              | 5080     | set `base-url: https://ntfy.<tailnet>.ts.net`    |
| filebrowser       | 8080     | straightforward                                  |
| syncthing         | 8384     | GUI only; sync ports stay host-published         |
| glances           | 61208    | straightforward                                  |
| adguard           | 8083     | admin UI; DNS :53 stays host-published           |
| nginx-proxy-mgr   | 81       | optional — only if you keep NPM                  |
| homepage          | 3000     | special case — keep on main node (see above)     |
| cockpit           | 9090     | host service (not a container); use host serve   |

Services that also expose **non-HTTP** ports the LAN/tailnet needs (AdGuard DNS
`:53`, Syncthing sync `:22000`, Forgejo SSH `:22`) keep those as direct
tailnet/host ports — only the web UI goes through `tailscale serve`.

## Gotchas / migration

- **Existing git remotes** pointing at `http://...:3300` must be updated:
  `git remote set-url origin git@forgejo.<tailnet>.ts.net:user/repo.git`.
- **Forgejo data persists** (`./data`); only the URL config changes. Forgejo
  regenerates `app.ini` from the `FORGEJO__*` env vars on each start.
- **Device count**: each sidecar is a tailnet device (fine on the free 100-device
  tier). Name them after the service.
- **One node, one cert**: first start of each sidecar takes a few seconds to
  provision its cert; `tailscale serve status` inside the sidecar shows progress.

## Decisions to confirm

1. **Auth**: OAuth-client-with-tag (recommended) vs reusable auth key?
2. **NPM**: retire it (tailnet-only access) or keep it for `.local`/LAN HTTPS?
3. **Homepage host**: keep on the main `ollie-server` node (recommended) or give
   it its own `homepage.<tailnet>.ts.net` sidecar?
