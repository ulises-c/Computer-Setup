# One tailnet node per host (#86)

Design for replacing the per-service Tailscale sidecars with one tailnet node
per host, with services at `https://<server>.<tailnet>.ts.net/<service>` or a
documented fallback.

Research inputs (working notes, not committed): [A] per-app subpath matrix,
[B] Tailscale architecture Q1–Q6, [C] URL-consumer inventory. They were
checked against Tailscale v1.102.3 and a local nginx spike of every app. Where
a claim decides a choice, the upstream source is linked inline.

## 1. Decision record

### D1. Host `tailscale serve`, not a proxy sidecar

Choice: each host runs one tailscaled on the host (the one `setup.sh` already
installs on the server) and publishes every web service with `tailscale serve`
on that node. Backends are reached on `127.0.0.1:<port>`. No reverse proxy is
added behind serve.

Rejected:
- One reverse-proxy sidecar per host (tailscale + caddy/nginx). It is a second
  node per host unless the host node is dropped, which breaks "adding a host
  adds exactly one node" [B Q4].
- A loopback caddy/nginx behind host serve, for prefix injection or `Location`
  rewrites. Every app that would need it has a working fallback (D2, D3), so it
  would be a component with no job [A verdicts].

Reason: host serve is the only option that meets the node-count goal, and it
keeps today's `ts-serve.json` schema [B Q2, Q4]. Serve strips the mount prefix;
a target URL that carries the same path restores it, so every mount can pick
STRIP or KEEP [B Q1] ([serve.go v1.102.3](https://github.com/tailscale/tailscale/blob/v1.102.3/ipn/ipnlocal/serve.go)).
Serve never rewrites `Location`, cookies or bodies, and sends no
`X-Forwarded-Prefix` [A, B Q1]. So an app goes on a path only when it is
prefix-aware on its own.

Accepted cost: a host tailscaled restart drops every service at once [B Q4].
The serve config survives it, because it is stored in the tailscaled state
file [B Q2].

### D2. Addressing: path, root, per-service port, or Tailscale Service

Choice, per service (full list in section 2):
- Path `https://<server>.<tailnet>.ts.net/<service>/` on `:443` for the 10
  prefix-safe apps across both hosts: 6 `subpath` and 4 `subpath-with-config`
  [A]. Forgejo is the fifth `subpath-with-config` app; it becomes a Service
  instead (D3).
- Root `/` of each host node for that host's homepage. Homepage is root-only
  (Next.js without a base path [A #7]) and is the natural landing page. Any
  root-absolute request that escapes another app's prefix lands on homepage,
  which only shows a 404 [A Findings].
- Per-service HTTPS port `https://<server>.<tailnet>.ts.net:<port>` for the
  remaining root-only apps [A `fallback-port`]. Ports come from one registry,
  and a service uses the same port on every host (section 2).
- A Tailscale Service for three apps (D3).
- Own node: none.

Rejected:
- Own node for root-only apps: it keeps the problem #86 is fixing.
- A Service for every root-only app: the 12 root-only apps [A] plus forgejo
  exceed the 10-Service cap [B Q3] and would rebuild the flat namespace.

### D3. Tailscale Services: `svc:forgejo`, `svc:ntfy`, `svc:immich`

Choice: three Services hosted by the server node, each with `https:443` to the
app's loopback port; `svc:forgejo` also has `tcp:22` (D4). Each Service keeps
the MagicDNS name its sidecar has today (`forgejo`, `ntfy`, `immich`
`.<tailnet>.ts.net`), so their off-repo clients don't change:
- forgejo: every clone's remote, the macOS runner's registration `instance`
  URL, and `ROOT_URL`/`SSH_DOMAIN` [C §8].
- ntfy: phone subscriptions and the `NTFY_URL` of every publisher on another
  host [C §6, §11.3]. Publishers on the server itself switch to loopback (D10).
- immich: the mobile app server URL on each phone and the External domain
  setting [C §11.3, §11.7].

Rejected:
- Forgejo web on a path (`/forgejo/` with `ROOT_URL`): it works [A #5], but it
  changes every remote and the runner URL, needs a separate root route for the
  fixed `/v2` registry, and puts forgejo on the same origin as every other app,
  which Forgejo warns it cannot protect against
  ([Forgejo reverse-proxy docs](https://forgejo.org/docs/latest/admin/setup/reverse-proxy)).
- ntfy and immich on per-service ports: both run at a root [A #8, #10], so a
  port works on the server side, but every phone must be reconfigured. Whether
  the Immich mobile app accepts a port-bearing HTTPS URL is also UNVERIFIED
  [A #8]; a Service avoids the question.

Reason: Services have their own MagicDNS name and VIP, work on every plan up
to 10 per tailnet, and can move between hosts [B Q3]
([KB 1552](https://tailscale.com/kb/1552/tailscale-services)). Their costs are
a tagged host (D8), one approval or `autoApprovers` entry, and a grant [B Q3].
Using 3 of 10 leaves room.

Constraint for part 2: the Service name equals the sidecar node's current
MagicDNS name. Whether the admin console lets a Service claim a name that a
live node still holds is UNVERIFIED — fallback chosen: stop and delete the old
sidecar node before the Service is defined (a short planned outage per
Service).

### D4. Forgejo git SSH: `svc:forgejo` `tcp:22`

Choice: the forgejo container keeps sshd on its own `:22` and publishes it as
`127.0.0.1:2222:22`. `svc:forgejo` forwards `tcp:22` to `127.0.0.1:2222`.
`SSH_PORT=22` and `SSH_DOMAIN=${FORGEJO_DOMAIN}` stay as they are, so clone
URLs don't change.

Rejected:
- Host-node `--tcp=2222` with `SSH_PORT=2222`: every SSH remote changes to
  `ssh://…:2222/…` [B Q5].
- Host-node `tcp:22`: a serve TCP listener on `:22` shadows the host's sshd on
  the tailnet IP [B Q4, Q5].
- Forgejo as its own node: breaks the goal.

Reason: Service traffic is intercepted per VIP and port, so the Service's
`:22` does not collide with the host node's `:22` [B Q3]. A peer granted a
Service could once reach unserved host ports through the VIP
([tailscale#20362](https://github.com/tailscale/tailscale/issues/20362),
closed 2026-07-10); the grants in D8 name ports explicitly (not `*`) anyway.

### D5. DNS / AdGuard

Choice:
- DNS stays where it is: server AdGuard publishes `53/tcp+udp` on the host;
  Pi AdGuard runs `network_mode: host`. Neither goes through serve (serve has
  no UDP [B Q3]).
- Both `adguard-ts` and `adguard-pi-ts` sidecars are removed. The web UI moves
  to the adguard fallback port on each host node, because the login and logout
  redirects are root-absolute [A #1, #20].
- `adguardhome-sync` `ORIGIN_URL` moves to the server's adguard port URL.

Rejected: AdGuard web on a path. It needs `proxy_redirect` and
`proxy_cookie_path`, which serve lacks [A #1].

UNVERIFIED — fallback chosen: nothing in the repo says a tailnet DNS
nameserver points at an adguard sidecar's 100.x IP [B Q5], but the admin
console is not in the repo. The migration checks the DNS page first and, if
one does, repoints it at the host node's tailnet IP (the server publishes
`:53` on all interfaces) before deleting the sidecar.

### D6. Other non-HTTP endpoints

Choice: none of them goes through serve. Each keeps its LAN/host exposure.
Where a sidecar used to publish the port, the publish moves to the app
container:
- syncthing `22000/tcp+udp`, `21027/udp`: move to the syncthing container.
- qbittorrent `6881/tcp+udp`: move to the qbittorrent container.
- openspeedtest `3030`, `3031` (LAN speed tests): move to the openspeedtest
  container.
- NUT `3493`, CUPS/IPP `631`, dragonwilds UDP `7777`: unchanged (host
  services, never behind a sidecar).
- DNS `53`: see D5.

Reason: serve has no UDP, and these are LAN or internet peer ports, not
tailnet front doors [B Q5]. Tailnet peers still reach any host-published port
through the host node's IP, as they do today.

### D7. NPM `:443` vs host serve `:443`

Choice: bind NPM's `80` and `443` publishes to the server's LAN IP from `.env`
(`${NPM_BIND_IP}:443:443`), and publish the admin port as `127.0.0.1:81:81`
plus `${NPM_BIND_IP}:81:81`.

Why: today NPM publishes `80`/`443`/`81` on all interfaces [A #9]. Remote
tailnet traffic to serve's `:443` is intercepted in netstack before the
kernel [B Q4], so it should not reach NPM. Traffic that starts on the server
itself and goes to its own tailnet name (homepage widgets, Uptime Kuma) goes
through the kernel instead, where Docker's DNAT for `0.0.0.0:443` would send
it to NPM. UNVERIFIED (not spiked) [A Findings, B Q5] — fallback chosen: take
NPM off the tailnet IP so the collision cannot happen. NPM keeps serving the
LAN.

### D8. ACL and tag model

Choice:
- One tag per host role: `tag:server` for the server (required, because it
  hosts Services [B Q3]) and `tag:pi` for the Pi. A future server joins as
  `tag:server`.
- Policy changes: add both to `tagOwners`; add
  `autoApprovers.services` for the three Services → `tag:server`; add grants
  from `autogroup:member` to each Service with explicit ports (`tcp:443`, plus
  `tcp:22` for forgejo); declare the three Services with their ports.
- Retire `tag:container` from `tagOwners` after the last sidecar is gone.
- Do not tighten the rest of the policy in this migration. The tailnet's
  existing member-to-device rule stays, so host-published ports (Syncthing,
  DNS, SSH, Cockpit `:9090`, …) keep working over the tailnet.

Rejected:
- Least-privilege grants for the host nodes in the same change. A missed port
  would break a service in a way that looks like a migration bug; this stays
  in #49 (D9) with the port list from section 2 as its input.
- Keeping `tag:container` for host nodes: the name no longer means anything.

Tagging costs [B Q6] ([KB 1068](https://tailscale.com/kb/1068/tags)): the host
loses its user identity, key expiry is disabled, and a tagged device can SSH
only to tagged devices (users can still SSH in). For always-on servers these
are acceptable, and no expiry is an improvement.

### D9. What happens to #49

Choice: #86 makes these #49 items obsolete; close them with a pointer to #86
when it merges:
- DRY the sidecar boilerplate (no sidecars left).
- One shared `TS_AUTHKEY` (no per-service keys; the host authenticates once
  [B Q6]).
- Pin the sidecar image (host tailscaled is updated by the package manager,
  not watchtower).

#49 stays open for:
- Tighten the ACL, reworded to least-privilege grants for `tag:server`,
  `tag:pi` and the three Services (D8).
- The stack validation script, retargeted: every serve mount must point at a
  port its compose file publishes on `127.0.0.1`, and no stack may carry a
  `TS_AUTHKEY` or `ts-state/`.
- Watchtower observability and NPM forward-auth: unaffected.

### D10. Consumers on the same host use loopback, not the tailnet name

Choice: a client that runs on the server and talks to a service on the server
uses the backend `http://127.0.0.1:<port>` from section 2, not a `*.ts.net`
URL. This covers:
- homepage widget `url:` values (hrefs still use the tailnet URLs, because
  the browser follows them) [C §5];
- server-side ntfy publishers' `NTFY_URL` and Uptime Kuma `KUMA_PUSH_URL`s
  (`dns-watchdog.sh`, `backup.sh`, `runner-status.sh`, `ups-notify.sh`,
  dragonwilds) [C §6, §7].

The Pi does the same for its own services, and uses the tailnet URLs for
services on the server.

Uptime Kuma HTTP monitors keep the user-facing URLs, because they exist to test
the real front door. That is a request from the server to its own node (and
Service VIPs), so it depends on the same UNVERIFIED self-reach below. If a
self-check fails on install, that monitor falls back to its loopback backend.

Reason: whether a host can reach its own Service VIP, and whether a host
reaches its own serve listener without a Docker DNAT rule getting there first
(D7), are both UNVERIFIED (no KB statement; not spiked) — fallback chosen:
loopback, which removes the dependency. It also keeps alerts working while
tailscaled is down.

## 2. Routing table

`<server>` and `<pi-hostname>` are the host nodes' MagicDNS names.

Conventions used in the rows:
- Front door: the URL a person or client uses. A path mount is registered
  with a trailing slash (`/glances/`); serve also answers the bare path without
  a redirect [B Q1].
- Serve target: the handler's proxy URL. STRIP targets have no path, so the
  app sees `/…`. KEEP targets carry the mount path, so the app sees
  `/<mount>/…` [B Q1].
- Backend: `127.0.0.1:<port>` on the host. A new publish is always
  `127.0.0.1:<host-port>:<container-port>`, never all interfaces.
- Removed: yes means the `<svc>-ts` sidecar block, `ts-serve.json`, its
  `ts-state/` directory, `TS_AUTHKEY` in `.env`/`.env.example`, and the
  `depends_on` on the sidecar all go. Every stack in scope has one; no sidecar
  survives.

### 2.1 Per-service HTTPS port registry

A service keeps the same tailnet HTTPS port on every host, so a second server
reuses it with no new choice. None of these ports has a listener on either
host in the repo, and none is 5252 (reserved for the web client [B Q4]).

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

The three Services (D3) each use `:443` (plus `:22` for forgejo) on their own
VIP, so they need no entry here.

### 2.2 Server (`linux-server/`)

| Service | Front door | Serve target | App config change | Compose change | Removed |
|---|---|---|---|---|---|
| homepage | `https://<server>.<tailnet>.ts.net/` | `http://127.0.0.1:3000` | `HOMEPAGE_ALLOWED_HOSTS` gains `<server>.<tailnet>.ts.net`. Hrefs move to the new URLs; widget `url:`s use loopback (D10) | Stays `network_mode: host`, `PORT=3000` | yes |
| glances | `/glances/` | `http://127.0.0.1:61208` (STRIP) | None; relative URLs [A #6] | Stays `network_mode: host` | yes |
| openspeedtest | `/openspeedtest/` | `http://127.0.0.1:3030` (STRIP) | None [A #11] | Leaves the sidecar netns; `3030:3000` and `3031:3001` move to the app (the existing LAN publish is also the backend) | yes |
| qbittorrent | `/qbittorrent/` | `http://127.0.0.1:8080` (STRIP) | WebUI must listen on all container interfaces, not `127.0.0.1` (off-repo `qBittorrent.conf`) [C §11.8]. Host validation passes, because serve on `:443` sends a port-less `Host` [A #13] | Leaves the sidecar netns; `127.0.0.1:8080:8080`; `6881/tcp+udp` moves to the app | yes |
| syncthing | `/syncthing/` | `http://127.0.0.1:8384` (STRIP) | `STGUIADDRESS=0.0.0.0:8384` inside the container. This turns Syncthing's Host check off, which a tailnet `Host` needs anyway [A #15]; the GUI password is the guard | Leaves the sidecar netns; `127.0.0.1:8384:8384`; `22000/tcp+udp` and `21027/udp` move to the app | yes |
| watchtower | `/watchtower/` | `http://127.0.0.1:8105` (STRIP) | None; token-only API [A #19] | Leaves the sidecar netns; `127.0.0.1:8105:8080` | yes |
| cockpit | `/cockpit-ui/` | `https+insecure://127.0.0.1:9090/cockpit-ui/` (KEEP) | `cockpit.conf` `[WebService] UrlRoot=/cockpit-ui`, `Origins = https://<server>.<tailnet>.ts.net wss://<server>.<tailnet>.ts.net`. The mount cannot be `/cockpit/`, which Cockpit reserves [A #3] | Stack deleted (sidecar-only); `cockpit.conf.example` stays | yes |
| filebrowser | `/filebrowser/` | `http://127.0.0.1:8102` (STRIP) | `FB_BASE_URL=/filebrowser` [A #4] | Leaves the sidecar netns; `127.0.0.1:8102:80` | yes |
| portainer | `/portainer/` | `http://127.0.0.1:9000` (STRIP) | `command: --base-url /portainer` [A #12] | Leaves the sidecar netns; `127.0.0.1:9000:9000` | yes |
| tailscale-web | `/tailscale-web/` | `http://127.0.0.1:8088` (STRIP) | `tailscale-web.service` `ExecStart=tailscale web --listen 127.0.0.1:8088 --prefix /tailscale-web --origin https://<server>.<tailnet>.ts.net` [A #16] | Stack deleted (sidecar-only) | yes |
| adguard | `https://<server>.<tailnet>.ts.net:8443` | `http://127.0.0.1:8100` | None | `adguardhome` gains `127.0.0.1:8100:80`; DNS `53` unchanged (D5) | yes |
| uptime-kuma | `:8444` | `http://127.0.0.1:3001` | Monitors move to the new URLs [C §7] | Leaves the sidecar netns; `127.0.0.1:3001:3001` | yes |
| speedtest-tracker | `:8445` | `http://127.0.0.1:8104` | `APP_URL` and `ASSET_URL` = `https://<server>.<tailnet>.ts.net:8445` | Leaves the sidecar netns; `127.0.0.1:8104:80` | yes |
| ups (PeaNUT) | `:8446` | `http://127.0.0.1:8097` | None | Stays `network_mode: host`, `WEB_PORT=8097` | yes (`peanut-ts`) |
| nginx-proxy-manager | `:8447` (admin UI) | `http://127.0.0.1:81` | None | `80`, `443`, `81` bound to `${NPM_BIND_IP}` (LAN IP from `.env`), plus `127.0.0.1:81:81` (D7) | yes |
| atvloadly | `:8448` | `http://127.0.0.1:8101` | None | Leaves the sidecar netns; `127.0.0.1:8101:80`. Avahi and D-Bus sockets are bind mounts, so discovery is unaffected | yes |
| forgejo | `svc:forgejo`: `https://forgejo.<tailnet>.ts.net`, `ssh://git@forgejo.<tailnet>.ts.net` | `https:443` → `http://127.0.0.1:3300`; `tcp:22` → `127.0.0.1:2222` | None: `FORGEJO_DOMAIN`, `ROOT_URL`, `SSH_DOMAIN`, `SSH_PORT=22` keep their values (D3, D4) | Leaves the sidecar netns; `127.0.0.1:3300:3000`, `127.0.0.1:2222:22`. `forgejo-runner-status` stays on `127.0.0.1:8098` | yes |
| ntfy | `svc:ntfy`: `https://ntfy.<tailnet>.ts.net` | `https:443` → `http://127.0.0.1:8103` | None: `NTFY_BASE_URL` keeps its value | Leaves the sidecar netns; `127.0.0.1:8103:80` | yes |
| immich | `svc:immich`: `https://immich.<tailnet>.ts.net` | `https:443` → `http://127.0.0.1:2283` | None | `immich-server` leaves the sidecar netns and joins the project's default network, so `database`, `redis` and `immich-machine-learning` still resolve; `127.0.0.1:2283:2283` | yes |

Neighbours on the server (no front door of their own):

| Stack | Change |
|---|---|
| tailscale-proxy | None. It is host-networked on `:8089`, and `TAILSCALE_DEVICE_ID` is already the host node's ID |
| dragonwilds | UDP `7777` and status `127.0.0.1:8096` unchanged. `NTFY_URL` becomes loopback (D10) |
| backup | Status `127.0.0.1:8099` unchanged. `NTFY_URL` and `KUMA_PUSH_URL` become loopback (D10). The `ts-state` exclude can stay; it matches nothing |
| forgejo runner status | `127.0.0.1:8098` unchanged. `NTFY_URL`, `KUMA_PUSH_URL` and `FORGEJO_RUNNER_API_URL` become loopback (D10) |

Server loopback ports after the change, one owner each: 81, 2222, 2283, 3000,
3001, 3030, 3031, 3300, 8080, 8088, 8089, 8096, 8097, 8098, 8099, 8100, 8101,
8102, 8103, 8104, 8105, 8384, 9000, 9090, 61208. The only ones that are new
are 2222, 3300 and 8100–8105. The other new publishes reuse the container's
own port, which no other stack uses on the host. Where two apps both listen
on container `:80` (adguard, atvloadly, filebrowser, ntfy, speedtest-tracker)
or `:8080` (qbittorrent, watchtower), or collide with homepage on `:3000`
(forgejo), they get a port from the 8100 block or 3300.

### 2.3 Pi (`linux-pi/`)

| Service | Front door | Serve target | App config change | Compose change | Removed |
|---|---|---|---|---|---|
| homepage | `https://<pi-hostname>.<tailnet>.ts.net/` | `http://127.0.0.1:3001` | `HOMEPAGE_ALLOWED_HOSTS` gains `<pi-hostname>.<tailnet>.ts.net`. Links to server services use the server's new URLs | Stays `network_mode: host`, `PORT=3001` | yes (`homepage-pi-ts`) |
| motioneye | `/motioneye/` | `http://127.0.0.1:8765` (STRIP) | None [A #23] | Stack deleted (sidecar-only) | yes |
| adguard | `https://<pi-hostname>.<tailnet>.ts.net:8443` | `http://127.0.0.1:80` | None | `adguardhome` stays `network_mode: host`; DNS unchanged (D5) | yes (`adguard-pi-ts`) |
| cups | `:8449` | `http://127.0.0.1:631` | `CUPS_SERVER_ALIAS` swaps the old sidecar name for `<pi-hostname>.<tailnet>.ts.net`. `setup.sh` drops the pinned sidecar subnet from the allow lists; serve connects from `localhost`, which is already allowed for print and admin (admin still requires `@SYSTEM` auth) | Stack deleted (sidecar-only, including its pinned bridge network) | yes |

Neighbours on the Pi:

| Stack | Change |
|---|---|
| adguardhome-sync | `ORIGIN_URL` becomes `https://<server>.<tailnet>.ts.net:8443`. `REPLICA1_URL` is LAN; unchanged |
| backup | Status `127.0.0.1:8099` unchanged. `NTFY_URL` unchanged (`svc:ntfy`). `KUMA_PUSH_URL` becomes `https://<server>.<tailnet>.ts.net:8444/api/push/…` |

Pi loopback ports after the change: 80, 631, 3001, 8099, 8765. No new
publishes.

## 3. Serve-config mechanism

This section is the contract for the implementers. It was checked against the
Tailscale v1.102.3 CLI source
([serve_v2.go](https://github.com/tailscale/tailscale/blob/v1.102.3/cmd/tailscale/cli/serve_v2.go),
[ipn/serve.go](https://github.com/tailscale/tailscale/blob/v1.102.3/ipn/serve.go))
and [KB 1589](https://tailscale.com/kb/1589/tailscale-services-configuration-file).

### 3.1 Files

| Path | Owner | What |
|---|---|---|
| `scripts/ts-serve-apply.sh` | server card | The one apply script. Host-agnostic: it takes the template path as an argument. The Pi runs this same file from its checkout; there is no copy |
| `scripts/test-ts-serve-apply.sh` | server card | Regression test with a stubbed `tailscale` on `PATH` (the `test-docker-address-pools.sh` pattern); a step in `.github/workflows/lint.yml` runs it. It covers render, each validation error, merge-preserves-unrelated-keys, the no-op re-apply, the conflict stop, `--services` selection, and that `--dry-run` calls no write command |
| `linux-server/tailscale-serve/serve.json` | server card | Server template: every row of 2.2 |
| `linux-pi/tailscale-serve/serve.json` | Pi card | Pi template: every row of 2.3 |

The template has the `.json` extension, so pre-commit `check-json` validates
it. Placeholders sit inside JSON strings, so the unrendered file is valid JSON.

### 3.2 Template format

The template is a raw `ipn.ServeConfig`: the JSON that
`tailscale serve status --json` prints and today's `ts-serve.json` files use.
Allowed top-level keys: `TCP`, `Web`, `Services`. Anything else
(`AllowFunnel`, `Foreground`) is a validation error.

Two placeholders, and no others:
- `${TS_CERT_DOMAIN}`: the host node's MagicDNS name,
  `<server>.<tailnet>.ts.net` (the same token containerboot fills today).
- `${TS_MAGICDNS_SUFFIX}`: `<tailnet>.ts.net`. It is needed only for the
  `Web` keys of Services, which the CLI builds as `<name>.<suffix>:<port>`
  ([ipn/serve.go `SetWebHandler`](https://github.com/tailscale/tailscale/blob/v1.102.3/ipn/serve.go)).

Excerpt of the server template (one path mount, one KEEP mount, one registry
port, one Service; the implementer writes the full file from 2.2):

```json
{
  "TCP": { "443": { "HTTPS": true }, "8443": { "HTTPS": true } },
  "Web": {
    "${TS_CERT_DOMAIN}:443": {
      "Handlers": {
        "/": { "Proxy": "http://127.0.0.1:3000" },
        "/glances/": { "Proxy": "http://127.0.0.1:61208" },
        "/cockpit-ui/": { "Proxy": "https+insecure://127.0.0.1:9090/cockpit-ui/" }
      }
    },
    "${TS_CERT_DOMAIN}:8443": {
      "Handlers": { "/": { "Proxy": "http://127.0.0.1:8100" } }
    }
  },
  "Services": {
    "svc:forgejo": {
      "TCP": { "443": { "HTTPS": true }, "22": { "TCPForward": "127.0.0.1:2222" } },
      "Web": {
        "forgejo.${TS_MAGICDNS_SUFFIX}:443": {
          "Handlers": { "/": { "Proxy": "http://127.0.0.1:3300" } }
        }
      }
    }
  }
}
```

Why Services are in the raw config and not in a KB 1589 `set-config` file:
in the file format the inbound listener type comes from the target's scheme,
so `"tcp:443": "http://127.0.0.1:3300"` becomes a plain-HTTP listener on
`:443`; only an `https://` target gets TLS
(`serveTypeFromConfString`, serve_v2.go v1.102.3). Every backend here is plain
HTTP on loopback, so `set-config` cannot express "HTTPS in, HTTP to the
backend". The raw config can (`TCP[443].HTTPS=true` plus a `Proxy` handler),
and it is also what the CLI writes for `tailscale serve --service=svc:X
--https=443 http://127.0.0.1:P`.

Adding a service later means adding one handler (or one registry port, or one
Service) to the host's template and re-running the script. It adds no node.

### 3.3 Rendering

The values come from the live node, not from a `.env` file:
`TS_CERT_DOMAIN` is `.Self.DNSName` without the trailing dot, and
`TS_MAGICDNS_SUFFIX` is `.CurrentTailnet.MagicDNSSuffix`, both from
`tailscale status --json`. If either variable is already set in the
environment, the script uses that value instead (tests and dry-runs with
placeholders). There is no `.env` for serve: both values are facts about the
node, so a copy in a file can only go stale, and it would put the tailnet name
on disk for no reason.

Rendering is a literal string replacement of exactly those two tokens,
followed by `jq -e .`. A `${` that is still present after rendering is an
error.

### 3.4 Validation (always, including `--dry-run`)

The script refuses to apply, and exits non-zero, when:
- the rendered file is not valid JSON, or it has a top-level key other than
  `TCP`, `Web`, `Services`;
- a `Web` key `<host>:<port>` (node level or inside a Service) has no matching
  `TCP[<port>]` with `HTTPS: true`;
- a `Proxy` target is not `http://127.0.0.1:<port>[/path]` or
  `https+insecure://127.0.0.1:<port>[/path]`, or a `TCPForward` is not
  `127.0.0.1:<port>` (loopback backends only, per D1);
- a listener uses port 5252 (reserved for the web client [B Q4]).

### 3.5 Apply algorithm

```text
scripts/ts-serve-apply.sh <template> [--services all|none|svc:a[,svc:b]] [--dry-run]
```

`--services` picks which Services from the template this run owns
(default `all`). The migration uses `none` first and then adds one Service at
a time (section 4), because a Service's name must be free before it is
defined (D3). Services not picked are left exactly as they are.

1. Preconditions: `jq` present; `tailscale version` is at or above the floor
   (1.102.3, the verified version); `BackendState` is `Running`. If the picked
   set has a Service, `.Self.Tags` must be non-empty (Services need a tagged
   host, D8).
2. Read the current config: `tailscale serve status --json` (treat empty
   output or `null` as `{}`).
3. Owned keys: every key of the rendered `TCP` and `Web`, plus `Services[X]`
   for each picked `X`. Build the merged config: the current config with each
   owned key replaced by the template's value as a whole (not a deep merge,
   so a mount removed from the template disappears from that listener). The
   template owns the whole `<host>:443` listener, so a mount someone added by
   hand on it is removed; the dry-run diff shows that before any write. Every
   other key is kept as it is: unrelated ports, other `Web` hosts, other
   Services, `Foreground`, `AllowFunnel`.
4. Conflict check: if an owned `TCP` port already exists with a different
   type (HTTPS vs HTTP vs `TCPForward`), stop and name the port. tailscaled
   would reject the change anyway ("cannot change the serve type in use by a
   port", `validateServeConfigUpdate`), and the script must never silently
   replace an unrelated listener. The user removes that listener by hand.
5. If the merged config equals the current config (`jq -S` compare), print
   `up to date` and exit 0 without writing.
6. Otherwise write it: `tailscale serve set-raw < merged.json`. Then run
   `tailscale serve advertise svc:X` for each picked Service (it is a no-op if
   the Service is already advertised).
7. Read back: `tailscale serve status --json` must contain the owned keys
   exactly as rendered. If not, exit non-zero.

`--dry-run` runs only the read-only commands (`tailscale version`,
`tailscale status --json`, `tailscale serve status --json`). It prints the
rendered template, the owned keys, a `diff` of current vs merged, the
preserved keys, and the write commands it would run. It writes nothing. On a
workstation, run it only with a stub `tailscale` on `PATH` and placeholder
values in the environment, never against the workstation's own tailscaled.

Run it as the tailscaled operator (`sudo tailscale set --operator=$USER`,
which the server footer already prints) or with `sudo`.

What the script does not do:
- Remove a listener that was dropped from the template: that is a one-off
  `tailscale serve --https=<port> off`, or `tailscale serve drain svc:X` and
  then `tailscale serve clear svc:X`. There is no prune mode.
- Run from `setup.sh`. The apply is an install step (section 4) and needs a
  logged-in, tagged node. `setup.sh`, `lib/` and `platforms/` do not change
  in this migration.

Write path: `set-raw` is an undocumented debug command that is still present
in v1.102.3 [B Q2]. It has no ETag, so a write made by another admin between
steps 2 and 6 would be lost. On a single-admin host that is acceptable. The
test in 3.1 pins its behaviour through the stub; if a future release removes
it, the fallback is the imperative CLI (`tailscale serve --bg --https=443
--set-path /glances/ http://127.0.0.1:61208`, one command per handler).
Applying a `Services` map through `set-raw` goes through the same
`SetServeConfig` call as the CLI, but it has not been run live.
UNVERIFIED — fallback chosen: if the step 7 read-back or the Services page
shows the Service as misconfigured, configure it with
`tailscale serve --service=svc:X --https=443 http://127.0.0.1:P` (plus
`--tcp=22 tcp://127.0.0.1:2222` for forgejo) and record the deviation.

Backup and restore use the same format: `tailscale serve status --json` is a
complete `ServeConfig`, and `tailscale serve set-raw < <backup>` restores it
exactly. `tailscale serve get-config --all` covers only Services, so it is a
secondary backup.

## 4. Migration runbook

TODO (part 2)

## 5. Work breakdown

TODO (part 2)

## 6. User-overridable defaults

TODO (part 2)

## Notes for part 2

Choices the user may want to override (turn these into section 6):
- Which apps are Services (D3): forgejo, ntfy, immich. Alternatives: forgejo
  on `/forgejo/` with `ROOT_URL`; ntfy/immich on ports.
- Service names reuse the old node names `forgejo`, `ntfy`, `immich`, which
  forces "delete the old node before defining the Service" (D3).
- The homepage owns `/` on each host (D2).
- The tailnet port registry 8443–8449 and the order of services in it (2.1).
- New loopback backend ports 2222, 3300, 8100–8105 (2.2).
- Mount names: `/cockpit-ui/` (forced off `/cockpit/`), `/tailscale-web/`,
  `/openspeedtest/`, `/qbittorrent/` and the rest match the stack directory
  name.
- NPM bound to a LAN IP from `.env` (`NPM_BIND_IP`) instead of all interfaces
  (D7). A DHCP change breaks it; a DHCP reservation or an interface-name
  firewall rule are alternatives.
- Host tags `tag:server` and `tag:pi` (D8); ACL tightening deferred to #49.
- Same-host consumers use loopback (D10).
- Syncthing GUI bound to `0.0.0.0` inside its container, which disables its
  Host check (2.2).

What part 2 needs to know:
- Serve config shape per host: one `Web["${TS_CERT_DOMAIN}:443"]` with the
  path handlers and `/`; one `Web["${TS_CERT_DOMAIN}:<port>"]` per registry
  port; matching `TCP` entries with `HTTPS: true`. Services use
  `set-config --service=svc:<name>` [B Q2], so node-level and Service config
  are applied by different commands.
- Every serve write must keep unrelated listeners (the host may have its own
  serve entries); the apply mechanism is the part 2 decision [B Q2].
- Order matters for the three Services: stop the sidecar, delete its node,
  then define and approve the Service (D3). For adguard, check the admin DNS
  page first (D5). For NPM, rebind it before the host serves `:443` (D7).
- The Pi has no `setup.sh` profile; its host tailscaled install and
  `tailscale up --advertise-tags=tag:pi` are manual today (`linux-pi/README.md`
  runbook).
- Tagging the server re-authenticates it; key expiry stops (D8).
- `linux-pi/cups/setup.sh` pins and validates the sidecar subnet
  (`PINNED_SIDECAR_SUBNET`); removing it is a script change, not only `.env`.
- The glances `allowed_hosts` vs `webui_allowed_hosts` bug and the syncthing
  Host-check comment [A Findings] are separate bugs; 2.2 routes around the
  second one, the first needs its own card.
- All path-mounted apps share one origin, so a `Path=/` cookie or localStorage
  entry from one app is visible to the others [A]. Port-based apps are
  separate origins for localStorage, but browsers do not isolate cookies by
  port, so a `Path=/` cookie on the host name is still shared with them. Only
  the three Services have their own host name.
- `NPM_BIND_IP` must exist when Docker starts NPM, or the publish fails; the
  install must check that NPM comes back after a reboot (D7).
- With `UrlRoot=/cockpit-ui`, direct LAN access to Cockpit also needs the
  prefix (`https://<server-ip>:9090/cockpit-ui/`), and `Origins` must list any
  LAN origin still in use.
- The committed `linux-server/tailscale-web.service` runs a bare
  `tailscale web`; the flags live only on the host today
  (`tailscale-web/docker-compose.yml` comment). 2.2 gives the full `ExecStart`.
- CUPS on `:8449` gets `Host: <pi-hostname>.<tailnet>.ts.net:8449`. Whether
  `ServerAlias` matching ignores the port is UNVERIFIED; a 400 on install
  means the alias needs the port form.
- `runner-status.sh` defaults `FORGEJO_RUNNER_API_URL` to
  `https://${FORGEJO_DOMAIN}/api/v1/admin/actions/runners`, a same-host call
  to `svc:forgejo`. Under D10 it becomes
  `http://127.0.0.1:3300/api/v1/admin/actions/runners` (a default change in
  the script, not only `.env`).
- Unverified on install: the Immich mobile app is not affected (it keeps its
  root URL); Uptime Kuma self-checks through the host's own node (D10); the
  cockpit login and the `tailscale web` manage flow under a prefix; portainer
  websocket exec; watchtower callers with a path URL; the openspeedtest body
  limit under serve [A unverified list].
