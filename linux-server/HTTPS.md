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
tailnet via MagicDNS.

Homepage itself uses the **host-networked variant**: it keeps `network_mode:
host` (it reaches the host-networked helpers — the tailscale-proxy widget on
`:8089` and glances on `:61208` — via localhost), and its sidecar proxies
`https://homepage.<tailnet>.ts.net` to the host's `:3000` via
`host.docker.internal`. The new domain must be appended to
`HOMEPAGE_ALLOWED_HOSTS` in `homepage/docker-compose.yml`, or homepage rejects
the proxied request (its reverse-proxy host-check).

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
| atvloadly         | 80    | ✅ done       | no `hostname:` on the app container — conflicts with `network_mode: service:...`; Apple TV discovery is unaffected by the shared netns since it goes through the host's avahi-daemon via bind-mounted sockets, not this container's own network |
| nginx-proxy-mgr   | 81    | ✅ done       | host edge (binds `:80/:443/:81`); its **admin UI** is fronted by a host-gateway sidecar at `npm.<tailnet>`, while NPM itself stays the non-tailnet trusted-cert edge (see section below) |
| homepage          | 3000  | ✅ done       | host-networked variant — keep `network_mode: host` (reaches localhost widgets), sidecar proxies via `host.docker.internal`; add the domain to `HOMEPAGE_ALLOWED_HOSTS` |
| cockpit           | 9090  | ✅ done       | host systemd service — **sidecar-only** stack proxies `https+insecure://host.docker.internal:9090`; `cockpit.conf.example`'s `Origins` line turned out to be unnecessary in practice — see Gotchas |
| tailscale-web     | 8088  | ✅ done       | not in the original rollout — added because the homepage Tailscale tile linked plain HTTP. `tailscale web` is a host **systemd user unit**, not a container; `ExecStart` needs `--listen 0.0.0.0:8088 --origin https://tailscale-web.<tailnet>.ts.net` so it's reachable via `host.docker.internal` and knows it's reverse-proxied. Don't use port `:5252` — see Gotchas |
| watchtower        | 8080  | todo          | **no UI** — the sidecar fronts only watchtower's token-gated `/v1/metrics` HTTP API (enable `WATCHTOWER_HTTP_API_METRICS=true` + `WATCHTOWER_HTTP_API_TOKEN`); no homepage `href`. Monitor it in Uptime Kuma — see below |

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

### Monitoring a UI-less service in Uptime Kuma (watchtower)

Watchtower is a headless daemon — no UI, nothing to click. To get the same
up/down tracking as the other services, enable its HTTP metrics API and point an
Uptime Kuma HTTP monitor at it (metrics-only, so the `WATCHTOWER_SCHEDULE` keeps
running — only the *update* API would disable periodic polls):

1. In `watchtower/.env`: set `WATCHTOWER_API_TOKEN` (e.g. `openssl rand -hex 32`)
   and `TS_AUTHKEY`; `docker compose up -d`.
2. In Uptime Kuma, add an **HTTP(s)** monitor:
   - URL: `https://watchtower.<tailnet>.ts.net/v1/metrics`
   - Header: `Authorization: Bearer <WATCHTOWER_API_TOKEN>`
   - Accepted status codes: `200` (an unauthenticated probe gets `401`, so the
     header is what proves it's both up *and* reachable).

The same pattern fits any future no-UI service that exposes a health/metrics
endpoint. For a daemon with *no* endpoint at all, Uptime Kuma's "Docker Container"
monitor (via the docker socket) checks the container's running state instead.

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
- **Cockpit's WebSocket Origin check worked without touching
  `cockpit.conf.example`'s `Origins` line.** That file documents the
  textbook fix for "Cockpit rejects proxied requests from an unrecognized
  Origin," but on this Cockpit version it already derives the allowed origin
  from the proxied request's `Host`/`X-Forwarded-Proto` (which `tailscale
  serve` sets correctly), so the default behavior just works. Verified by
  hand-crafting a WebSocket upgrade to `/cockpit/socket`: matching `Origin`
  header → `101 Switching Protocols`, a foreign `Origin` → `403` (proving the
  check is live, just already satisfied). Keep `cockpit.conf.example` as a
  fallback if a future Cockpit/Tailscale version regresses this.
- **`tailscale web` needs both `--listen 0.0.0.0:<port>` and `--origin
  https://<svc>.<tailnet>.ts.net` on its `ExecStart`**, unlike the other
  "host-networked apps" sidecars (glances, cockpit) which needed no app-side
  change at all. It's a host **systemd user unit**
  (`tailscale-web.service` — `systemctl --user`, not the system scope), not a
  container. By default it listens on `localhost:8088` only, which
  `host.docker.internal` can't reach (loopback is per-network-namespace);
  `--listen 0.0.0.0:8088` fixes that. Without `--origin` set to the HTTPS
  sidecar domain, the app redirects browsers to its own bare `ip:port` —
  harmless over plain HTTP, but a hard `SSL_ERROR_RX_RECORD_TOO_LONG` once
  the tile is HTTPS (the browser inherits `https:` from the page and tries
  to TLS-handshake a plain-HTTP port). Edit with `systemctl --user edit --full
  tailscale-web.service`, then `daemon-reload` + `restart`.
- **Don't proxy to port `:5252`** — something else (unidentified, not this
  unit, not a container, not killed by a reboot) answers there and serves
  what looks like the same Tailscale UI but never reflects `--origin`/
  `--listen` changes made to `tailscale-web.service`. Cost real debugging
  time chasing a stale redirect before realizing the sidecar's
  `ts-serve.json` was still pointed at the old `:5252` address instead of
  wherever `tailscale web` actually ends up listening. Always confirm the
  port with `systemctl --user status tailscale-web.service`'s logged
  `web server running on:` line before setting the `Proxy` target.

## Decisions to confirm

1. ~~**Auth**: OAuth-client-with-tag (recommended) vs reusable auth key?~~
   Resolved during the Forgejo rollout: OAuth client + `tag:container`, reusing
   the existing `tailscale-proxy` client elevated to read+write scope. See
   Prerequisites above.
2. ~~**NPM**: retire it or keep it?~~ Resolved: **keep** NPM as the non-tailnet
   HTTPS edge — trusted certs (no browser warning) for clients that can't/won't
   join the tailnet (e.g. a TV running Plex). See "NPM — trusted HTTPS for
   non-tailnet clients" below. (It's also the vendor-independent equivalent of
   the whole tailnet layer — see "Resilience / exit strategy".)
3. ~~**Homepage host**: main node vs own sidecar?~~ Resolved: its own
   `homepage.<tailnet>.ts.net` sidecar (host-networked variant), to keep the
   per-service subdomain scheme consistent.

## Resilience / exit strategy

This layer leans on Tailscale's hosted control plane. Worth knowing what breaks
if Tailscale has an outage or goes away — and that there's a clean exit.

### What depends on Tailscale (hosted) vs what's open

Every `<svc>.<tailnet>.ts.net` URL depends on the hosted **coordination server**
for: node auth + the `100.x` tailnet IP, **MagicDNS** (`ts.net` is Tailscale's
domain), the **Let's Encrypt certs** `tailscale serve` auto-provisions for
`*.ts.net`, and **DERP** relays for NAT traversal. The sidecars' OAuth auth keys
also flow through it.

What is **not** dependent: the data plane is **WireGuard** (open, in-kernel,
peer-to-peer — traffic never routes through Tailscale once peers are connected),
`tailscaled` is open source, and the apps + data are all local.

### Failure modes

- **Temporary control-plane outage:** mostly fine. Existing tunnels run on cached
  keys/endpoints; already-issued certs keep working (90-day lifetime). You just
  can't add/re-auth nodes until it's back.
- **Tailscale shuts down permanently:** a long fuse, not a cliff — it degrades
  over **~90 days** as certs hit renewal and can't reissue, MagicDNS for `.ts.net`
  stops, and sidecars eventually can't re-auth.

### The exit: Headscale (planned)

[Headscale](https://github.com/juanfont/headscale) is an open-source, self-hostable
reimplementation of the coordination server (could even run on this box). Point
`tailscaled --login-server=https://<headscale>` and the tailnet model — MagicDNS,
ACLs, DERP — keeps working without the company. **Catch:** Headscale gives you
neither `.ts.net` nor the zero-config certs, so you switch to **a domain you own**
(`<svc>.home.example.com`) and **manage your own certs** — which is exactly the
**NPM + real-domain** setup. So NPM is the bridge to vendor independence; keeping
it (or the know-how) is the insurance policy.

### Operational single point of failure

Every front door now routes through `tailscaled` on this host — if the daemon or
its config breaks (local, not Tailscale's fault), all HTTPS URLs drop at once. The
apps keep running underneath. Two cheap mitigations:

- **Keep host SSH reachable on the LAN** (not only over the tailnet), so you can
  always get in to fix the box when the tailnet is the broken thing.
- Each service's compose still documents its container port, so re-exposing a
  host `ports:` block for LAN access is a one-line fallback (next section).

### Sharing a container on the LAN without Tailscale

The tailnet sidecar and a plain LAN host-port can **coexist** — a service can be
reachable both at `https://<svc>.<tailnet>.ts.net` (sidecar) and at
`http://<server-lan-ip>:<port>` (host port) for devices not on the tailnet.

Because a netns-shared app can't publish its own ports, add the `ports:` block to
the **sidecar** (it owns the namespace), exactly as syncthing/adguard already do
for their non-HTTP ports:

```yaml
  <svc>-ts:
    # ... sidecar as usual, plus:
    ports:
      - "8096:80"   # LAN access at http://<server-lan-ip>:8096 → app's :80
```

That's plaintext HTTP on the LAN, which browsers flag as "not secure." For
**trusted LAN HTTPS** (no warning) you need a publicly-valid cert — that's NPM's
job, see the next section. Host-networked services (e.g. glances) already keep
their LAN port open, so no change is needed for those.

## NPM — trusted HTTPS for non-tailnet clients

The tailnet sidecars give no-warning HTTPS, but **only to devices on the tailnet**
(`*.ts.net` resolves and is trusted only there). For clients that can't or won't
join the tailnet — a smart TV, a game console, a guest, a Plex client — plaintext
HTTP triggers the browser's "not secure" warning. NPM is kept to solve exactly
this: a **publicly-trusted cert** on a name those clients can use.

You **cannot** get a trusted cert for a made-up name (`*.local`, `*.home`) — a CA
must verify you control the domain. So the requirement is a **real public domain**
— that's **`ulises-c.me`** (already owned), so the prerequisite is met. **Not set
up yet — documented here to pick up later.** When you do, leveraging the two tools
already on this box:

1. **NPM holds a wildcard Let's Encrypt cert** for `*.home.ulises-c.me` via a
   **DNS-01** challenge (NPM has built-in DNS-provider plugins). DNS-01 proves
   domain control through a DNS record — it does **not** require exposing the
   server to the public internet, so this stays LAN-only if you want.
2. **AdGuard resolves those names to the server's LAN IP** via a DNS rewrite
   (`*.home.ulises-c.me` → `192.168.1.x`) — split-horizon DNS. Set AdGuard as the
   LAN's resolver (it already is, for ad-blocking).
3. **NPM proxies** `https://plex.home.ulises-c.me` → the service. Add a host
   `ports:` block on the relevant **sidecar** (see previous section) so NPM can
   reach the service, or point NPM at the service's `*.ts.net` name (the host is on
   the tailnet).

Result: `https://plex.home.ulises-c.me` loads with a green lock on any LAN device,
no tailnet membership, no warning. For **public** access (outside the LAN), add a
router port-forward `80/443` → the server; DNS-01 means the cert already works.

**Plex caveat:** Plex ships its own TLS (`*.plex.direct` certs) and its clients
prefer Plex's own discovery/relay, so they often bypass a reverse proxy. Plex is
usually best left on its native HTTPS rather than fronted by NPM; the NPM path
above is the general recipe for the *other* services you'd share this way.
