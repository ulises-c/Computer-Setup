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
3. **An auth method for the sidecars — resolved: OAuth client + tag.** Reuses
   the existing Tailscale OAuth client (`linux-server/tailscale-proxy/.env`,
   originally created read-only for the device-status proxy):
   - In the admin console, edit that OAuth client's **scope** to include
     **Auth Keys (read+write)**, in addition to its existing Core - Read scope.
     Same `client_secret` continues to work for both the proxy and sidecars —
     no new client or secret needed.
   - Add `tag:container` to the ACL's `tagOwners` (e.g.
     `"tag:container": ["autogroup:admin"]`). This alone was sufficient — the
     OAuth client did **not** need a separate per-client tag assignment in its
     own settings.
   - Pass the existing `client_secret` as `TS_AUTHKEY` with
     `TS_EXTRA_ARGS=--advertise-tags=tag:container` (already set in
     `docker-compose.yml`). Sidecars never expire.
   - **Gotcha hit during the Forgejo rollout**: granting the Auth Keys scope
     without also adding `tag:container` to `tagOwners` fails at sidecar
     startup with `Status: 400, Message: "requested tags [tag:container] are
     invalid or not permitted"`. Add the tag to `tagOwners` and restart the
     sidecar.
   - (Reusable auth key remains a simpler fallback if you'd rather not touch
     the OAuth client: generate one in admin → Settings → Keys and put it in
     the service's `.env` as `TS_AUTHKEY`, but watch its expiry.)
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

### Variant: host-networked apps (glances)

A service that must keep `network_mode: host` — e.g. glances, which reads the
host's real network interfaces and processes — can't be moved into the sidecar's
namespace without degrading exactly what it measures. Leave that app untouched
and run the sidecar in its **own** netns, proxying back to the host's port via
the docker bridge gateway:

```yaml
  <svc>-ts:
    # ... same sidecar as above, plus:
    extra_hosts:
      - "host.docker.internal:host-gateway"
  # the app keeps network_mode: host, its own ports, everything — unchanged
```

with `ts-serve.json` proxying to `http://host.docker.internal:<port>` instead of
`127.0.0.1:<port>`. Because the app keeps its host port, its homepage **widget**
`url:` can stay `http://localhost:<port>` (only the `href` moves to HTTPS) — the
opposite of the netns-shared services. Trade-off: the host port stays open on the
LAN/tailnet (plaintext) since the app still binds it directly.

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

If you have to restart/recreate the sidecar (`forgejo-ts`) for any reason
*after* the app container is already up — e.g. to pick up a new ACL tag grant —
restart the app container too. See the netns gotcha below.

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
`https://{{HOMEPAGE_VAR_<SVC>_DOMAIN}}/` and add the matching
`HOMEPAGE_VAR_<SVC>_DOMAIN=<svc>.<tailnet>.ts.net` line to `homepage/.env`.
If the service has a **widget**, its `url:` must move too — `http://localhost:<port>`
no longer resolves once the host `ports:` block is dropped (homepage runs on host
networking and the container no longer publishes a port). Point the widget `url:`
at `https://{{HOMEPAGE_VAR_<SVC>_DOMAIN}}` as well; homepage reaches it over the
tailnet via MagicDNS. Keep homepage itself on the main node (it uses host
networking + the docker socket — a sidecar is awkward there); serve it with
`tailscale serve --bg https / http://127.0.0.1:3000` on `ollie-server`.

**`docker compose restart homepage` does not pick up a new/changed `.env`
var** — `env_file` is baked into the container at creation time, and `restart`
reuses that same container. The tile renders the literal `{{HOMEPAGE_VAR_...}}`
placeholder instead of the URL until you run `docker compose up -d` (in
`linux-server/homepage`), which recreates the container with the current
`.env`. Verify with `docker exec homepage printenv | grep HOMEPAGE_VAR_<SVC>`.

## Rollout order and per-service ports

Convert one at a time, verify, then move on. The sidecar steps are identical
every time (ports below); the only part that varies is the **app config** column
— apps that generate absolute URLs or host-check need one extra setting, the
rest work at the root unchanged. `tailscale serve` already sends
`X-Forwarded-Proto: https`.

The **port** column is the container's *internal* listening port — what
`ts-serve.json` proxies to (`127.0.0.1:<port>`). It equals the old
host-published port for every service except `speedtest-tracker`, whose host
mapping was `8765:80`, so its serve target is `:80`. Always read the container
side of the `ports:` mapping (`host:container`), not the host side.

| service           | port  | status        | app config beyond the sidecar                          |
|-------------------|-------|---------------|--------------------------------------------------------|
| forgejo           | 3000  | ✅ done       | `ROOT_URL` + `SSH_DOMAIN`; also exposes git SSH `:22`  |
| portainer         | 9000  | ✅ done       | none — works at root (websocket console proxied)       |
| uptime-kuma       | 3001  | ✅ done       | none — works at root (websockets proxied)              |
| speedtest-tracker | 80    | ✅ done       | `APP_URL=https://speedtest.<tailnet>.ts.net` (Laravel); proxy to container :80, **not** the old 8765 host map |
| ntfy              | 80    | ✅ done       | `NTFY_BASE_URL=https://ntfy.<tailnet>.ts.net` + `NTFY_BEHIND_PROXY=true`; proxy to container :80, **not** the old 5080 host map |
| filebrowser       | 80    | ✅ done       | none — works at root; proxy to container :80, **not** the old 8080 host map |
| syncthing         | 8384  | ✅ done       | set `STGUIADDRESS=127.0.0.1:8384` (disables Syncthing's Host-header check, else `Host check error`); publish sync `:22000`/`:21027` on the **sidecar** (raw TCP/UDP, not via serve) |
| glances           | 61208 | ✅ done       | **host-networked variant** — keep `network_mode: host`, sidecar proxies via `host.docker.internal`; widget url stays localhost |
| adguard           | 80    | ✅ done       | UI at container :80 (not the 8083 host map); publish DNS `:53` tcp+udp on the **sidecar** (raw DNS, not via serve); no :443 so no DoH/serve conflict |
| nginx-proxy-mgr   | 81    | optional      | only if you keep NPM                                   |
| homepage          | 3000  | special case  | keep on main node — `tailscale serve` on `ollie-server`, no sidecar |
| cockpit           | 9090  | special case  | host service (not a container) — host-level serve      |

Services that also expose **non-HTTP** ports the LAN/tailnet needs (AdGuard DNS
`:53`, Syncthing sync `:22000`, Forgejo SSH `:22`) keep those as direct
tailnet/host ports — only the web UI goes through `tailscale serve`.

Each conversion is five mechanical edits — copy the sidecar block + `ts-serve.json`
(change only the port), set `TS_AUTHKEY` in the service's `.env`, drop the app's
`ports:` block, add `HOMEPAGE_VAR_<SVC>_DOMAIN=<svc>.<tailnet>.ts.net` to
`homepage/.env`, and point the homepage `href` at
`https://{{HOMEPAGE_VAR_<SVC>_DOMAIN}}/` — plus the app-config cell above where
non-empty. `ts-state/` is already gitignored for every service
(`linux-server/*/ts-state/`). Remember `docker compose up -d` (not `restart`)
for `homepage` afterward — see Homepage links below.

## Gotchas / migration

- **Existing git remotes** pointing at `http://...:3300` must be updated:
  `git remote set-url origin git@forgejo.<tailnet>.ts.net:user/repo.git`.
- **Forgejo data persists** (`./data`); only the URL config changes. Forgejo
  regenerates `app.ini` from the `FORGEJO__*` env vars on each start.
- **Device count**: each sidecar is a tailnet device (fine on the free 100-device
  tier). Name them after the service.
- **One node, one cert**: first start of each sidecar takes a few seconds to
  provision its cert; `tailscale serve status` inside the sidecar shows progress.
- **Stale netns after restarting the sidecar alone**: `network_mode:
  service:<svc>-ts` makes the app container join the sidecar's network
  namespace at *the app container's own start time* — it does not stay
  dynamically linked. If you restart only the sidecar (e.g.
  `docker compose restart <svc>-ts`) after the app is already running, the
  sidecar gets a fresh netns but the app is still pinned to the old one. The
  app's own healthcheck (`wget http://localhost:<port>` from inside the app
  container) keeps reporting healthy — checking against its own stale
  loopback, not the sidecar's — so the only symptom is `tailscale serve`
  returning `502` with sidecar logs showing
  `http: proxy error: dial tcp 127.0.0.1:<port>: connect: connection refused`.
  Fix: `docker compose restart <svc>` (the app) after the sidecar so it
  re-resolves and rejoins the sidecar's current namespace.
- **ntfy's `/config.js` and `/v1/config` always report `"base_url": ""`** —
  this is not a sign that `NTFY_BASE_URL` failed to apply. ntfy's source
  hardcodes that field blank on purpose (`server.go`'s `configResponse()`),
  so the web app falls back to `window.location.origin` instead of trusting
  the server. To verify `NTFY_BASE_URL` actually took effect server-side,
  hit `GET /_matrix/push/v1/notify` instead — its handler 500s
  (`errHTTPInternalErrorMissingBaseURL`) if `BaseURL` is empty and returns
  `200` once it's set, regardless of whether Matrix push is otherwise used.

## Decisions to confirm

1. ~~**Auth**: OAuth-client-with-tag (recommended) vs reusable auth key?~~
   Resolved during the Forgejo rollout: OAuth client + `tag:container`, reusing
   the existing `tailscale-proxy` client elevated to read+write scope. See
   Prerequisites above.
2. **NPM**: retire it (tailnet-only access) or keep it for `.local`/LAN HTTPS?
3. **Homepage host**: keep on the main `ollie-server` node (recommended) or give
   it its own `homepage.<tailnet>.ts.net` sidecar?
