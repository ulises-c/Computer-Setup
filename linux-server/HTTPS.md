# HTTPS over Tailscale: one node per host

Every self-hosted web service is reached over HTTPS on the tailnet, through
the server's own Tailscale node. There is no per-service sidecar: adding a
service adds no tailnet node, and adding a host adds exactly one. The design,
with the reasons behind each choice, is
[`../docs/ONE_NODE_PER_HOST.md`](../docs/ONE_NODE_PER_HOST.md) (#86).

## How a request gets to a service

```
tailnet ──HTTPS──▶ host tailscaled (the server's node, <server>.<tailnet>.ts.net)
                     │  tailscale serve: TLS, then proxy by port and path
                     ▼
                   127.0.0.1:<backend-port>   the app, published on loopback only
```

Each app publishes its web port on `127.0.0.1` only
(`127.0.0.1:<host>:<container>` in its compose file), or runs host-networked.
`tailscale serve` on the host terminates TLS with the node's Let's Encrypt
cert and proxies to that port. It sets `X-Forwarded-Proto: https`; it does not
rewrite `Location`, cookies or bodies.

A service gets one of four front doors:

| Front door | Used by | Why |
|---|---|---|
| `https://<server>.<tailnet>.ts.net/` | homepage | Root-only app; the natural landing page |
| `https://<server>.<tailnet>.ts.net/<service>/` | glances, openspeedtest, qbittorrent, syncthing, watchtower, cockpit (`/cockpit-ui/`), filebrowser, portainer, tailscale-web | The app works under a path prefix, on its own or with a base-path setting |
| `https://<server>.<tailnet>.ts.net:<port>` | adguard, uptime-kuma, speedtest-tracker, PeaNUT, the NPM admin UI, atvloadly | Root-only apps; one HTTPS port each from the registry below |
| `https://<name>.<tailnet>.ts.net` (a Tailscale Service) | forgejo, ntfy, immich | Root-only apps with off-host clients (git remotes, the runner, phones) that keep their old URL |

Serve strips the mount from the request path unless the proxy target repeats
it. So `/glances/` → `http://127.0.0.1:61208` gives the app `/…`, and
`/cockpit-ui/` → `https+insecure://127.0.0.1:9090/cockpit-ui/` keeps the prefix
for Cockpit's `UrlRoot`.

### Port registry

A service uses the same tailnet HTTPS port on every host. None of these ports
has a host listener, and none is 5252 (reserved for the Tailscale web client).

| Tailnet port | Service |
|---|---|
| 443 | path mounts and the host's homepage at `/` |
| 8443 | adguard (both hosts) |
| 8444 | uptime-kuma |
| 8445 | speedtest-tracker |
| 8446 | ups (PeaNUT) |
| 8447 | nginx-proxy-manager admin UI |
| 8448 | atvloadly |
| 8449 | cups (Pi) |

### Server routes

The single source of truth is
[`tailscale-serve/serve.json`](tailscale-serve/serve.json). In table form:

| Service | Front door | Backend | App setting |
|---|---|---|---|
| homepage | `/` | `127.0.0.1:3000` (host network) | Host node name in `HOMEPAGE_ALLOWED_HOSTS` |
| glances | `/glances/` | `127.0.0.1:61208` (host network) | Host node name in `GLANCES_ALLOWED_HOSTS` |
| openspeedtest | `/openspeedtest/` | `127.0.0.1:3030` | — |
| qbittorrent | `/qbittorrent/` | `127.0.0.1:8080` | Web UI address `*` (not `127.0.0.1`) in `qBittorrent.conf` |
| syncthing | `/syncthing/` | `127.0.0.1:8384` | `STGUIADDRESS=0.0.0.0:8384` in the container |
| watchtower | `/watchtower/` | `127.0.0.1:8105` | — (token-only API) |
| cockpit | `/cockpit-ui/` (prefix kept) | `https+insecure://127.0.0.1:9090` (host service) | `cockpit.conf`: `UrlRoot`, `Origins` |
| filebrowser | `/filebrowser/` | `127.0.0.1:8102` | `FB_BASE_URL=/filebrowser` |
| portainer | `/portainer/` | `127.0.0.1:9000` | `--base-url /portainer` |
| tailscale-web | `/tailscale-web/` | `127.0.0.1:8088` (host user unit) | `--prefix /tailscale-web --origin …` |
| adguard | `:8443` | `127.0.0.1:8100` | — |
| uptime-kuma | `:8444` | `127.0.0.1:3001` | — |
| speedtest-tracker | `:8445` | `127.0.0.1:8104` | `APP_URL`, `ASSET_URL` with `:8445` |
| ups (PeaNUT) | `:8446` | `127.0.0.1:8097` (host network) | — |
| nginx-proxy-manager | `:8447` | `127.0.0.1:81` | — |
| atvloadly | `:8448` | `127.0.0.1:8101` | — |
| forgejo | `svc:forgejo`, plus SSH `:22` | `127.0.0.1:3300`, SSH `127.0.0.1:2222` | none (`ROOT_URL`, `SSH_DOMAIN`, `SSH_PORT=22` unchanged) |
| ntfy | `svc:ntfy` | `127.0.0.1:8103` | none (`NTFY_BASE_URL` unchanged) |
| immich | `svc:immich` | `127.0.0.1:2283` | none |

Non-HTTP ports never go through serve (it has no UDP, and these are LAN or
peer ports): DNS `:53`, Syncthing `:22000`/`:21027`, BitTorrent `:6881`,
openspeedtest's LAN `:3030`/`:3031`, NUT `:3493`, Dragonwilds UDP `:7777`.
They stay published on the host, so tailnet peers reach them on the host
node's IP as before.

### Pi routes

The Raspberry Pi uses the same mechanism and script with its own template,
[`../linux-pi/tailscale-serve/serve.json`](../linux-pi/tailscale-serve/serve.json);
see `../linux-pi/README.md`.

| Service | Front door | Backend | App setting |
|---|---|---|---|
| homepage | `https://<pi-hostname>.<tailnet>.ts.net/` | `127.0.0.1:3001` (host network) | — |
| motioneye | `/motioneye/` | `127.0.0.1:8765` (host service) | — |
| adguard | `:8443` | `127.0.0.1:80` (host network) | — |
| cups | `:8449` | `127.0.0.1:8631` cups-proxy shim → `127.0.0.1:631` | shim sets `Host: localhost` |

The Pi's cups front door (`:8449`) proxies to a loopback Host-rewrite shim on
`127.0.0.1:8631`, not to `:631`: cupsd rejects a non-localhost `Host` on
loopback connections (see `../linux-pi/cups/README.md`).

## Prerequisites (one time)

1. Admin console, DNS page: **MagicDNS** and **HTTPS certificates** on.
2. The host's tailscaled is logged in (`sudo tailscale up`) and the operator
   is set (`sudo tailscale set --operator=$USER`), so the apply script runs
   without sudo.
3. For the Tailscale Services: the server node carries `tag:server`. Add
   `tag:server` to `tagOwners`, apply it on the Machines page, and disable key
   expiry for the node. A host without tags can still apply everything except
   the Services (`--services none`).
4. `jq` is installed.

## Applying the serve config

[`../scripts/ts-serve-apply.sh`](../scripts/ts-serve-apply.sh) renders the
template, validates it, merges it into the live config, and reads it back:

```sh
cd <repo>/linux-server/tailscale-serve
(umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
cd <repo>
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --dry-run
scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json
```

- The template has two placeholders: `${TS_CERT_DOMAIN}` (the node's name)
  and `${TS_MAGICDNS_SUFFIX}` (`<tailnet>.ts.net`, for Service names). Their
  values come from the environment, then `tailscale-serve/.env`
  (`.env.example` shows the format), then `tailscale status` with a warning
  when that `.env` is missing. A value that differs from the live node is
  rejected, so the `.env` can only be right or refused.
- `--dry-run` runs only `tailscale version`, `tailscale status --json` and
  `tailscale serve status --json`. It prints the rendered template, the keys
  it owns, a diff against the live config, the keys it keeps, and the write
  commands it would run.
- The script owns every listener in the template and replaces each one
  whole: a mount someone added by hand on `:443` is removed (the dry-run diff
  shows it). Every other listener, `Web` host and Service is kept.
- A listener of a different type already on an owned port (for example an
  HTTP listener on `:8444`) stops the run before any write; remove it by hand.
- `--services all|none|svc:a[,svc:b]` picks which Services this run owns
  (default `all`). Services not picked are left exactly as they are.
- Running it twice prints `up to date` and writes nothing.

The config is stored in tailscaled's state file, so it survives reboots and
tailscaled restarts. The script does not remove a listener dropped from the
template: use `tailscale serve --https=<port> off`, or for a Service
`tailscale serve drain svc:X` then `tailscale serve clear svc:X`.

## Adding a service

1. Publish the app's web port on loopback in its compose file, at a free
   port: `"127.0.0.1:<port>:<container-port>"`. Do not use `0.0.0.0`.
2. Pick the front door:
   - A path, if the app works under a prefix. Prefer an app with relative
     URLs or a base-path setting; serve cannot fix root-absolute redirects.
     Add `"/<service>/": { "Proxy": "http://127.0.0.1:<port>" }` to the
     `${TS_CERT_DOMAIN}:443` handlers.
   - Otherwise the next registry port: add it to `TCP` with `"HTTPS": true`
     and add a `${TS_CERT_DOMAIN}:<port>` entry under `Web`. Add the port to
     the registry table above and to `docs/ONE_NODE_PER_HOST.md` 2.1.
   - A Tailscale Service only when off-host clients need their own host name
     (see below). There are at most 10 per tailnet.
3. Re-run the apply script with `--dry-run`, read the diff, then without it.
4. Add the homepage card: `href:
   https://{{HOMEPAGE_VAR_HOMEPAGE_DOMAIN}}/<service>/` (or `:<port>/`), and
   point any widget `url:` at the loopback backend.
5. Add the Uptime Kuma monitor ([`uptime-kuma/monitors.md`](uptime-kuma/monitors.md)).

No auth key, no `ts-state/`, no new node.

## Adding a Tailscale Service

A Service has its own MagicDNS name and IP, hosted by the server node. Do this
once per Service, before the first apply that includes it:

1. Admin console, Services page: **Define a Service** named `<name>`, with the
   ports it uses (`tcp:443`, plus `tcp:22` for forgejo). The name must be
   free: delete an old node with that name from the Machines page first.
2. Access controls: `autoApprovers.services["svc:<name>"] = ["tag:server"]`,
   and a grant from `autogroup:member` to `svc:<name>` on the same ports.
3. Add the Service to the template: a `Services["svc:<name>"]` entry with its
   own `TCP` and a `Web` key `<name>.${TS_MAGICDNS_SUFFIX}:443`.
4. `scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services svc:<name> --dry-run`,
   then without `--dry-run`. The script advertises the Service after writing.
5. Approve the host on the Services page if `autoApprovers` did not.

If the Service shows as misconfigured after a `set-raw` apply, configure it
with the CLI instead and note it in `docs/ONE_NODE_PER_HOST.md`:
`tailscale serve --service=svc:<name> --https=443 http://127.0.0.1:<port>`.

## Git over SSH (Forgejo)

`svc:forgejo` forwards its `:22` to the forgejo container's sshd on
`127.0.0.1:2222`. The Service has its own IP, so its `:22` does not collide
with the host's sshd. Clone URLs are unchanged:

```
git clone ssh://git@forgejo.<tailnet>.ts.net:22/<username>/<repo>.git
```

## Same-host clients use loopback

Anything that runs on the server and calls a service on the server uses the
loopback backend, not a `*.ts.net` URL: homepage widget `url:`s, and the
`NTFY_URL`/`KUMA_PUSH_URL` of `backup`, `dragonwilds`, `ups` and the forgejo
runner monitor. A host reaching its own serve listener or Service IP is not
verified, and loopback keeps alerts working while tailscaled is down.
Homepage card `href`s still use the tailnet URLs, because the browser follows
them.

Uptime Kuma HTTP monitors are the exception: they test the front doors on
purpose. See [`uptime-kuma/monitors.md`](uptime-kuma/monitors.md) for each
URL and its loopback fallback.

## Homepage links

Card links are built from `HOMEPAGE_VAR_HOMEPAGE_DOMAIN`, the server node's
MagicDNS name (setup.sh fills it from `tailscale status`):
`https://{{HOMEPAGE_VAR_HOMEPAGE_DOMAIN}}/glances/`,
`https://{{HOMEPAGE_VAR_HOMEPAGE_DOMAIN}}:8444/`. The three Services keep their
own variables (`HOMEPAGE_VAR_FORGEJO_DOMAIN`, `_NTFY_DOMAIN`, `_IMMICH_DOMAIN`),
and the Pi card uses `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN`, the Pi node's name.

**`docker compose restart homepage` does not pick up a new or changed `.env`
var** — `env_file` is baked into the container at creation time, and `restart`
reuses that same container. The tile renders the literal `{{HOMEPAGE_VAR_...}}`
placeholder until you run `docker compose up -d` (in `linux-server/homepage`),
which recreates the container with the current `.env`. Verify with
`docker exec homepage printenv | grep HOMEPAGE_VAR_`.

### Monitoring a UI-less service in Uptime Kuma (watchtower)

Watchtower is a headless daemon — no UI, nothing to click. To get the same
up/down tracking as the other services, enable its HTTP metrics API and point an
Uptime Kuma HTTP monitor at it (metrics-only, so the `WATCHTOWER_SCHEDULE` keeps
running — only the *update* API would disable periodic polls):

1. In `watchtower/.env`: set `WATCHTOWER_API_TOKEN` (e.g. `openssl rand -hex 32`);
   `docker compose up -d`.
2. In Uptime Kuma, add an **HTTP(s)** monitor:
   - URL: `https://<server>.<tailnet>.ts.net/watchtower/v1/metrics`
   - Header: `Authorization: Bearer <WATCHTOWER_API_TOKEN>`
   - Accepted status codes: `200` (an unauthenticated probe gets `401`, so the
     header is what proves it's both up *and* reachable).

The same pattern fits any future no-UI service that exposes a health/metrics
endpoint. For a daemon with *no* endpoint at all, Uptime Kuma's "Docker Container"
monitor (via the docker socket) checks the container's running state instead.

## Gotchas

- **Path mounts share one origin.** Every path-mounted app is on
  `https://<server>.<tailnet>.ts.net`, so a `Path=/` cookie or a localStorage
  entry from one is visible to the others. Browsers don't isolate cookies by
  port either, so registry-port apps see those cookies too. Only the three
  Services have their own host name. Move a sensitive app to a Service if
  that matters.
- **A root-absolute link escapes its mount** and lands on homepage at `/`,
  which shows a 404. That is how an app that is not prefix-aware fails here;
  give it a registry port instead.
- **Serve sends a port-less `Host` on `:443`** and `Host: <name>:<port>` on a
  registry port. Apps with a host check (homepage, glances, qBittorrent,
  Cockpit `Origins`) must list the host node's name.
- **NPM is bound to `NPM_BIND_IP`.** On `0.0.0.0:443`, Docker's DNAT could
  catch the server's own requests to its tailnet name before serve does.
  NPM fails to start if that IP is not on the host, so give the server a fixed
  LAN address.
- **Cockpit needs the prefix on the LAN too**:
  `https://<server-ip>:9090/cockpit-ui/`. The mount cannot be `/cockpit/`,
  which Cockpit reserves.
- **ntfy's `/config.js` and `/v1/config` always report `"base_url": ""`** —
  this is not a sign that `NTFY_BASE_URL` failed to apply. ntfy's source
  hardcodes that field blank on purpose (`server.go`'s `configResponse()`),
  so the web app falls back to `window.location.origin` instead of trusting
  the server. To verify `NTFY_BASE_URL` actually took effect server-side,
  hit `GET /_matrix/push/v1/notify` instead — its handler 500s
  (`errHTTPInternalErrorMissingBaseURL`) if `BaseURL` is empty and returns
  `200` once it's set, regardless of whether Matrix push is otherwise used.
- **`tailscale web` needs `--prefix` and `--origin`.** Without `--origin` it
  redirects browsers to its own bare `ip:port`, a hard
  `SSL_ERROR_RX_RECORD_TOO_LONG` once the page is HTTPS. The unit
  ([`tailscale-web.service`](tailscale-web.service), a `systemctl --user`
  unit) reads the origin from `~/.config/tailscale-web.env`. After an edit:
  `systemctl --user daemon-reload && systemctl --user restart tailscale-web`.
- **Don't proxy to port `:5252`.** It is reserved for the Tailscale web
  client, and something other than the `tailscale web` unit answers there.
  Confirm the unit's port with `systemctl --user status tailscale-web.service`
  (its `web server running on:` line) before changing a `Proxy` target.
- **One tailscaled for every front door.** A host tailscaled restart drops
  every service at once; the apps keep running. See the next section.

## Resilience / exit strategy

This layer leans on Tailscale's hosted control plane. Worth knowing what breaks
if Tailscale has an outage or goes away — and that there's a clean exit.

### What depends on Tailscale (hosted) vs what's open

Every `*.<tailnet>.ts.net` URL depends on the hosted **coordination server**
for: node auth + the `100.x` tailnet IP, **MagicDNS** (`ts.net` is Tailscale's
domain), the **Let's Encrypt certs** `tailscale serve` auto-provisions for
`*.ts.net`, the Tailscale Services, and **DERP** relays for NAT traversal.

What is **not** dependent: the data plane is **WireGuard** (open, in-kernel,
peer-to-peer — traffic never routes through Tailscale once peers are connected),
`tailscaled` is open source, and the apps + data are all local.

### Failure modes

- **Temporary control-plane outage:** mostly fine. Existing tunnels run on cached
  keys/endpoints; already-issued certs keep working (90-day lifetime). You just
  can't add/re-auth nodes until it's back.
- **Tailscale shuts down permanently:** a long fuse, not a cliff — it degrades
  over **~90 days** as certs hit renewal and can't reissue, MagicDNS for `.ts.net`
  stops, and the node eventually can't re-auth.

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

Every front door routes through `tailscaled` on this host — if the daemon or
its config breaks (local, not Tailscale's fault), all HTTPS URLs drop at once. The
apps keep running underneath. Two cheap mitigations:

- **Keep host SSH reachable on the LAN** (not only over the tailnet), so you can
  always get in to fix the box when the tailnet is the broken thing.
- Each service's compose file shows its loopback publish, so re-exposing it on
  the LAN is a one-line change (next section).

### Sharing a container on the LAN without Tailscale

A service can be reachable both through serve and at
`http://<server-lan-ip>:<port>` for devices not on the tailnet. Add a second
publish on the LAN address next to the loopback one:

```yaml
    ports:
      - "127.0.0.1:8102:80"      # serve backend
      - "<server-ip>:8102:80"    # LAN access at http://<server-ip>:8102
```

That's plaintext HTTP on the LAN, which browsers flag as "not secure." For
**trusted LAN HTTPS** (no warning) you need a publicly-valid cert — that's NPM's
job, see the next section. Host-networked services (e.g. glances) already keep
their LAN port open, so no change is needed for those.

## NPM — trusted HTTPS for non-tailnet clients

Tailnet HTTPS gives no-warning certs, but **only to devices on the tailnet**
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
3. **NPM proxies** `https://plex.home.ulises-c.me` → the service. NPM runs in a
   container, so point it at the service's LAN publish (previous section) or at
   its tailnet URL (the host is on the tailnet).

Result: `https://plex.home.ulises-c.me` loads with a green lock on any LAN device,
no tailnet membership, no warning. For **public** access (outside the LAN), add a
router port-forward `80/443` → the server; DNS-01 means the cert already works.

**Plex caveat:** Plex ships its own TLS (`*.plex.direct` certs) and its clients
prefer Plex's own discovery/relay, so they often bypass a reverse proxy. Plex is
usually best left on its native HTTPS rather than fronted by NPM; the NPM path
above is the general recipe for the *other* services you'd share this way.
