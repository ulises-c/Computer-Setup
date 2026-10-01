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
loses its user identity, and a tagged device can SSH only to tagged devices
(users can still SSH in). Key expiry is disabled when the device
re-authenticates with the tag; a tag applied from the admin console keeps the
current expiry until it is disabled on the Machines page. For always-on
servers these are acceptable, and no expiry is an improvement.

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
| `scripts/test-ts-serve-apply.sh` | server card | Regression test with a stubbed `tailscale` on `PATH` (the `test-docker-address-pools.sh` pattern); a step in `.github/workflows/lint.yml` runs it. It covers render, the `.env` precedence and each render-value error of 3.3 (missing file fallback, malformed line, unknown key, empty key, unedited placeholder, drift), each validation error, merge-preserves-unrelated-keys, the no-op re-apply, the conflict stop, `--services` selection, and that `--dry-run` calls no write command |
| `linux-server/tailscale-serve/serve.json` | server card | Server template: every row of 2.2 |
| `linux-pi/tailscale-serve/serve.json` | Pi card | Pi template: every row of 2.3 |
| `linux-server/tailscale-serve/.env.example` | server card | The two render keys (3.3), placeholder values only |
| `linux-pi/tailscale-serve/.env.example` | Pi card | The same two keys for the Pi, placeholder values only |
| `<host-dir>/tailscale-serve/.env` | nobody (host-local) | Gitignored by the repo-wide `.env` rule. Created on the host during the runbook (4.2, 4.4), mode `0600`. The backup jobs already collect every `<host-dir>/*/.env` |

The template has the `.json` extension, so pre-commit `check-json` validates
it. Placeholders sit inside JSON strings, so the unrendered file is valid JSON.

Both `.env.example` files hold exactly:

```sh
TS_CERT_DOMAIN=<server>.<tailnet>.ts.net
TS_MAGICDNS_SUFFIX=<tailnet>.ts.net
```

(`<pi-hostname>.<tailnet>.ts.net` in the Pi file.)

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

The render values come from `.env` next to the template
(`<template-dir>/.env`, e.g. `linux-server/tailscale-serve/.env`).

Precedence, per key (highest first):
1. The process environment (`TS_CERT_DOMAIN=... scripts/ts-serve-apply.sh ...`).
   For the test and for workstation dry-runs with placeholders.
2. `<template-dir>/.env`.
3. Fallback, only when `<template-dir>/.env` does not exist: the live node,
   from `tailscale status --json` (`TS_CERT_DOMAIN` is `.Self.DNSName`
   without the trailing dot; `TS_MAGICDNS_SUFFIX` is
   `.CurrentTailnet.MagicDNSSuffix`). The script prints
   `warning: <template-dir>/.env not found; using values from tailscale status`
   to stderr and continues.

Parsing: the script reads `.env` as data and never sources it (it may run as
root; the file is user-owned). It accepts blank lines, `#` comments and
`KEY=value` lines, and strips one layer of matching quotes from the value (as
`env_value` in `linux-server/backup/backup.sh` does).

Errors (exit non-zero, before any write, also in `--dry-run`). Messages name
the key and the file, never the value:
- `.env` exists but a line is not blank, a comment, or `KEY=value`; or it
  sets a key other than the two above (a typo must not pass silently).
- `.env` exists but a key is missing or empty. A half-filled file is a
  mistake, not a reason to fall back to the live node.
- Format: `TS_MAGICDNS_SUFFIX` must match `^[a-z0-9-]+(\.[a-z0-9-]+)*\.ts\.net$`
  (lower case, no scheme, no trailing dot); `TS_CERT_DOMAIN` must be exactly
  one `[a-z0-9-]+` label followed by `.` and `TS_MAGICDNS_SUFFIX`. A value
  that still contains `<` or `>` (an unedited `.env.example` copy) fails here.
- Drift: after resolution, both values must equal the live node's values from
  `tailscale status --json`. A mismatch stops the run and says which key
  differs. So the `.env` can never misroute: it can only be right or rejected.
  (Under the test's stub, the stub's status returns the placeholder values.)

Rendering is a literal string replacement of exactly those two tokens,
followed by `jq -e .`. A `${` that is still present after rendering is an
error.

### 3.4 Validation (always, including `--dry-run`)

The script refuses to apply, and exits non-zero, when:
- any render-value error from 3.3 occurs;
- the rendered file is not valid JSON, or it has a top-level key other than
  `TCP`, `Web`, `Services`;
- a `Web` key `<host>:<port>` (node level or inside a Service) has no matching
  `TCP[<port>]` with `HTTPS: true`;
- a `Proxy` target is not `http://127.0.0.1:<port>[/path]` or
  `https+insecure://127.0.0.1:<port>[/path]`, a `TCPForward` is not
  `127.0.0.1:<port>` (loopback backends only, per D1), or a handler uses
  anything other than `Proxy` (`Path`, `Text`, `Redirect`);
- a Service's `Web` key is not `<name>.${TS_MAGICDNS_SUFFIX}:<port>` for its
  own `svc:<name>`;
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
  logged-in, tagged node. No `setup.sh`, `lib/` or `platforms/` change is
  needed for it.

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

An outline for the install handoff (`docs/HANDOFF.md`, written by the
integration card). Run the server first, then the Pi: the Pi's neighbours
point at server URLs. Steps marked HUMAN need the admin console or a phone.
Commands run on the host being migrated, from the repo checkout (`<repo>`);
a few server steps also edit a gitignored `.env` on the Pi, over SSH.

Rules for every step:
- Cut over one stack at a time, and verify it before the next one.
- Run each apply with `--dry-run` first, and read the diff.
- Do not delete an old node, revoke a key or delete `ts-state/` until the
  soak (4.7) is over, except for the three Service names, which D3 forces.

### 4.1 Admin console, before either host (HUMAN)

1. DNS page (D5). Record every nameserver IP. On the server, get
   `docker exec adguard-ts tailscale ip -4`; on the Pi,
   `docker exec adguard-pi-ts tailscale ip -4`. If a nameserver matches one of
   them, change it to that host node's tailnet IP now, before any sidecar is
   removed.
2. Access controls: add `tag:server` and `tag:pi` to `tagOwners` (D8). Leave
   `tag:container` in place until 4.7. Service entries come later (4.3).
3. Machines page: apply `tag:server` to the server's host node. This does not
   re-authenticate the node, so its IP and device ID stay the same (the
   tailscale-proxy `TAILSCALE_DEVICE_ID` keeps working). Then disable key
   expiry for it (KB 1068). Confirm on the server:
   `tailscale status --json | jq -r '.Self.Tags'` lists `tag:server`.

### 4.2 Server: pre-flight and backups

1. `git -C <repo> rev-parse HEAD`: record the pre-migration commit.
2. `tailscale version` is 1.102.3 or later; `tailscale status --json` shows
   `BackendState` `Running`.
3. `tailscale serve status --json`: record it. Expected empty; if not, every
   listener in it must survive the migration unchanged.
4. Every backend port in 2.2 is either free or held by the service that 2.2
   says owns it (`ss -ltnpH 'sport = :<port>'`). In particular the new ports
   2222, 3300 and 8100–8105 print nothing. No host listener on the tailnet
   registry ports (8443–8449).
5. On the Pi: `getent hosts <server>.<tailnet>.ts.net` resolves, on the host
   and inside the adguardhome-sync container
   (`docker exec adguardhome-sync nslookup <server>.<tailnet>.ts.net`). The
   server's host node already has this name, and the Pi resolves the old
   sidecar names in the same zone today, so it should. UNVERIFIED — fallback
   chosen: if it does not resolve, fix the Pi's resolver before 4.3 step 5,
   which points Pi `.env` values at the server's name.
6. Backups. `<backup-dir>` is a new directory outside the repo (for example
   `/root/cs86-backup-<date>`). Its parent must exist and it must not exist
   yet: the capture creates it as root, mode `0700`, and stops if it is
   already there, so a stale file from an earlier run can never pass as this
   run's backup. Every write into it and every read from it happens in a root
   process, so no redirect runs in the unprivileged shell.

   The capture is one non-interactive root script with
   `set -euo pipefail`. Any failed step stops it before the last line, so
   `capture-complete` exists only when every step succeeded. `sudo` sets
   `SUDO_USER` to the operator:

   ```sh
   sudo bash -euo pipefail -c 'B="$1"; R="$2"
   mkdir -m 700 -- "$B"
   systemctl start backup.service
   cd "$R/linux-server"
   tar -czf "$B/ts-state-server.tgz" -- */ts-state
   out=$(tailscale serve status --json)
   [[ -n "$out" ]] || out="{}"
   jq -e "if . == null then {} else . end | objects" <<< "$out" > "$B/serve-before.json"
   if [[ "$(jq length "$B/serve-before.json")" == 0 ]]; then printf "empty\n"; else printf "config\n"; fi > "$B/serve-before.state"
   rc=0; tailscale serve get-config --all "$B/serve-services-before.json" || rc=$?
   printf "%s\n" "$rc" > "$B/serve-services-before.rc"
   if [[ -e /etc/cockpit/cockpit.conf ]]; then cp -a /etc/cockpit/cockpit.conf "$B/"; else : > "$B/cockpit.conf.absent"; fi
   home=$(getent passwd "${SUDO_USER:?}" | cut -d: -f6)
   cp -a "$home/.config/systemd/user/tailscale-web.service" "$B/"
   : > "$B/capture-complete"' _ <backup-dir> <repo>
   ```

   - `backup.service` is a oneshot: `systemctl start` waits for it and exits
     non-zero if it fails. It covers app data and every `<host-dir>/*/.env`.
   - The backup job excludes `ts-state/`; the tarball is what lets a stack
     roll back to its old node identity. A glob that matches nothing makes
     `tar` fail, which stops the capture.
   - `serve-before.json` is the primary Serve backup (3.5). It is written only
     when `tailscale serve status --json` exits 0 and prints a JSON object;
     empty output or `null` is stored as `{}`, the same rule as 3.5 step 2. A
     failed read, or output that is not a JSON object, stops the capture. The
     `serve-before.state` file records the result: `empty` for a confirmed
     empty config, `config` for anything else. Rollback (4.6) reads it.
   - `get-config --all` covers only Services; before the migration the node
     hosts none, so a non-zero exit is expected. Its exit code goes into
     `serve-services-before.rc` and does not stop the capture.
   - `cockpit.conf.absent` records that there was no `cockpit.conf`, so the
     rollback knows to remove the new one instead of restoring a file.

   Then check the backup, and do not start 4.3 unless it prints `backup-ok`.
   The check runs with the same `set -euo pipefail`, so any failed test stops
   it before the `printf`:

   ```sh
   sudo bash -euo pipefail -c 'B="$1"
   [[ "$(stat -c "%a %U" "$B")" == "700 root" ]]
   [[ -f "$B/capture-complete" ]]
   [[ "$(systemctl show -p Result --value backup.service)" == success ]]
   [[ "$(tar -tzf "$B/ts-state-server.tgz")" == */ts-state/* ]]
   n=$(jq -e "objects | length" "$B/serve-before.json")
   state=$(<"$B/serve-before.state")
   [[ ( "$state" == empty && "$n" == 0 ) || ( "$state" == config && "$n" != 0 ) ]]
   [[ -f "$B/cockpit.conf" || -f "$B/cockpit.conf.absent" ]]
   [[ -s "$B/tailscale-web.service" ]]
   printf "backup-ok\n"' _ <backup-dir>
   ```

   If either script stops, fix the cause and rerun both with a new
   `<backup-dir>`.
7. `git -C <repo> checkout <migration-branch>`. Running containers are not
   affected until each stack is brought up again.
8. Create the render `.env` (3.3) from the live node, as the operator user
   (not root), with no world-readable window:

   ```sh
   cd <repo>/linux-server/tailscale-serve
   (umask 077; tailscale status --json | jq -r '"TS_CERT_DOMAIN=\(.Self.DNSName | rtrimstr("."))\nTS_MAGICDNS_SUFFIX=\(.CurrentTailnet.MagicDNSSuffix)"' > .env)
   ```

   The 4.3 step 2 dry-run validates it (format and drift).

### 4.3 Server: cutover order

Each stack step is: set the new `.env` keys (names from its `.env.example`),
then `docker compose up -d --remove-orphans` in the stack directory. The
`--remove-orphans` flag removes the old `<svc>-ts` container, which is no
longer in the compose file. Then verify (4.5).

1. nginx-proxy-manager (D7). Set `NPM_BIND_IP` to the LAN IP. It must go
   first, so NPM no longer holds `0.0.0.0:443` when host serve starts. Its
   tailnet admin URL is down until step 2.
2. Node-level serve config:
   `scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services none --dry-run`,
   then the same without `--dry-run`. From now on every new URL answers. A
   URL whose stack is not cut over yet returns 502 until then, and the old
   sidecar URL keeps working in parallel.
3. Host-networked services, whose new URL works as soon as their config
   changes: glances, ups (`peanut-ts` removed), homepage (`.env`: allowed
   hosts, new hrefs; keep `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` at its old value
   until the Pi is migrated in 4.4), cockpit (deploy `cockpit.conf` with `UrlRoot` and
   `Origins`, `sudo systemctl restart cockpit`), tailscale-web (install the
   new unit, `systemctl --user daemon-reload && systemctl --user restart
   tailscale-web`). The cockpit and tailscale-web stacks are deleted on the
   new branch, so `--remove-orphans` cannot reach their sidecars; remove them
   with `docker rm -f cockpit-ts tailscale-web-ts`.
4. Stateless apps: openspeedtest, watchtower, speedtest-tracker, atvloadly,
   filebrowser, portainer.
5. Stateful or protocol-bearing apps: qbittorrent (WebUI bind in
   `qBittorrent.conf` first), syncthing (peers reconnect on `22000`),
   adguard (web UI only; DNS keeps serving; right after it, set the Pi's
   `linux-pi/adguardhome-sync/.env` `ORIGIN_URL` to the 2.3 value and restart
   that container, so sync pauses only between the two), uptime-kuma.
6. Right after uptime-kuma: `KUMA_PUSH_URL` to loopback in `backup/.env` and
   `forgejo/.env` (D10), and on the Pi, `KUMA_PUSH_URL` in
   `linux-pi/backup/.env` to the 2.3 value. Pushes to the old sidecar name
   fail from the uptime-kuma cutover until this step.
7. The three Services, one at a time, in this order: ntfy, immich, forgejo.
   For each `svc:X` (D3):
   1. `docker compose up -d --remove-orphans` in its stack. The old node goes
      offline; the outage starts.
   2. HUMAN: Machines page, delete the old `X` machine.
   3. HUMAN: Services page, Define a Service named `X`, with endpoint
      `tcp:443` (forgejo: `tcp:443` and `tcp:22`). Access controls: add
      `autoApprovers.services["svc:X"] = ["tag:server"]` and a grant from
      `autogroup:member` to `svc:X` on the same ports (D8).
   4. `scripts/ts-serve-apply.sh linux-server/tailscale-serve/serve.json --services svc:X --dry-run`,
      then without `--dry-run`.
   5. HUMAN: approve the host on the Services page if `autoApprovers` did not.
   6. Verify from another tailnet device (4.5). The outage ends.
   After ntfy: set `NTFY_URL` to loopback in `backup`, `dragonwilds`, `ups`
   and `forgejo` `.env` (D10). After forgejo: `FORGEJO_RUNNER_API_URL` to
   loopback, if `.env` overrides it.
8. Reboot the server. NPM must come back with `NPM_BIND_IP` bound (D7), and
   serve and Services must come back from the state file. Repeat the 4.5
   checks.

### 4.4 Pi: pre-flight, host node and cutover

1. Pre-flight: record the commit; `ss -ltnH` for 80, 631, 3001, 8765 shows
   the host services.
2. Host node. If the Pi already runs a host tailscaled (the adguardhome-sync
   container reaches the server's tailnet name today, which suggests it
   does), apply `tag:pi` from the Machines page as in 4.1 step 3. If it has
   none: the official Linux installer, then
   `sudo tailscale up --advertise-tags=tag:pi --accept-dns=false` (HUMAN: open
   the printed login URL). `--accept-dns=false` keeps the Pi's own resolver as
   it is, so DNS on the Pi does not start to depend on Tailscale (the README's
   resilience goal). Either way: `sudo tailscale set --operator=$USER`,
   install `jq`, disable key expiry (HUMAN).
3. Backups, with the same rules as 4.2 step 6 (a new `<backup-dir>` on the
   Pi, created by root with mode `0700`, one fail-closed root script, the
   same `serve-before.state` rule):

   ```sh
   sudo bash -euo pipefail -c 'B="$1"; R="$2"
   mkdir -m 700 -- "$B"
   systemctl start pi-backup.service
   cd "$R/linux-pi"
   tar -czf "$B/ts-state-pi.tgz" -- */ts-state
   out=$(tailscale serve status --json)
   [[ -n "$out" ]] || out="{}"
   jq -e "if . == null then {} else . end | objects" <<< "$out" > "$B/serve-before.json"
   if [[ "$(jq length "$B/serve-before.json")" == 0 ]]; then printf "empty\n"; else printf "config\n"; fi > "$B/serve-before.state"
   rc=0; tailscale serve get-config --all "$B/serve-services-before.json" || rc=$?
   printf "%s\n" "$rc" > "$B/serve-services-before.rc"
   : > "$B/capture-complete"' _ <backup-dir> <repo>
   ```

   Then the same check as 4.2 step 6, with `pi-backup.service` and
   `ts-state-pi.tgz`, and without the `cockpit.conf` and
   `tailscale-web.service` lines. Do not continue unless it prints
   `backup-ok`.
4. `git checkout <migration-branch>`. Create
   `linux-pi/tailscale-serve/.env` as in 4.2 step 8. Then
   `scripts/ts-serve-apply.sh linux-pi/tailscale-serve/serve.json --dry-run`,
   then without `--dry-run`. All four Pi backends are host services already,
   so the new URLs answer at once.
5. Stacks: homepage (`.env`), adguard (`--remove-orphans` removes
   `adguard-pi-ts`; DNS on `:53` is not touched). The motioneye and cups
   stacks are deleted on the new branch: `docker rm -f motioneye-ts cups-ts`,
   remove the cups sidecar's bridge network (`docker network ls` shows it),
   and rerun `linux-pi/cups/setup.sh` with the new alias.
6. The Pi resolves the server's name: `getent hosts <server>.<tailnet>.ts.net`
   was checked in 4.2 step 5; repeat it after the Pi's own tailscaled change.
7. Neighbours: confirm `adguardhome-sync` `ORIGIN_URL` and `backup`
   `KUMA_PUSH_URL` hold the 2.3 values (set during 4.3) and that the next
   sync run and backup push succeed. Then set the server homepage's
   `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` to the Pi host node's name and restart
   the server homepage.
8. Reboot the Pi, and repeat the checks.

### 4.5 Verification per service

Run from a tailnet device that is not the host (D10). `curl -sS -o /dev/null
-w '%{http_code} %{redirect_url}\n' <url>` for the status; a redirect must stay
on the same origin and under the mount.

| Service | Probe (expected) | Also check |
|---|---|---|
| homepage | `/` 200 on each host | Widgets load (loopback URLs) |
| glances | `/glances/api/4/status` 200 | Dashboard renders |
| openspeedtest | `/openspeedtest/` 200 | A browser run with upload (body limit UNVERIFIED) |
| qbittorrent | `/qbittorrent/api/v2/app/version` 401 or 403 before login | Login, then the same call 200 |
| syncthing | `/syncthing/rest/noauth/health` 200 | GUI asks for the password; peers show connected |
| watchtower | `/watchtower/v1/metrics` 401 without token | 200 with `Authorization: Bearer <token>` |
| cockpit | `/cockpit-ui/` 200 | Browser login and a terminal (UNVERIFIED under a prefix) |
| filebrowser | `/filebrowser/` 200 | Login; file list loads |
| portainer | `/portainer/api/system/status` 200 | Login; container console (websocket, UNVERIFIED) |
| tailscale-web | `/tailscale-web/` 200 | The manage flow (UNVERIFIED) |
| adguard | `:8443/control/status` 401 or 403 without auth | Login; stats; `dig @<server-ip>` still resolves |
| uptime-kuma | `:8444/` 200 or 302 to `/dashboard` | Login; push monitors still green |
| speedtest-tracker | `:8445/admin/login` 200 | Assets load from `:8445` |
| ups (PeaNUT) | `:8446/` 200 | UPS values shown |
| nginx-proxy-manager | `:8447/` 200 | Admin login; LAN proxy hosts still work via `<server-ip>` |
| atvloadly | `:8448/` 200 | Device list |
| ntfy | `https://ntfy.<tailnet>.ts.net/v1/health` 200 | Publish a test message; the phone receives it |
| immich | `https://immich.<tailnet>.ts.net/api/server/ping` 200 | Mobile app syncs with no change |
| forgejo | `https://forgejo.<tailnet>.ts.net/api/v1/version` 200 | `git ls-remote` over HTTPS and SSH from a clone; the macOS runner shows online |
| Pi motioneye | `/motioneye/` 200 | Camera streams |
| Pi adguard | `:8443/control/status` 401 or 403 | `dig @<pi-lan-ip>` resolves |
| Pi cups | `:8449/` 200 | Not 400 (Host / `ServerAlias`, UNVERIFIED with a port); admin asks for auth |

On the host, for every stack: the backend listens on `127.0.0.1` only
(`ss -ltnH 'sport = :<port>'`), the old node shows offline in
`tailscale status`, and `tailscale serve status --json` matches the template.
Uptime Kuma HTTP monitors that use the front-door URLs are requests from the
server to itself (D10, UNVERIFIED): a monitor that fails while the same URL
works from another device moves to its loopback backend.

### 4.6 Rollback

Per stack, while its old node still exists (every stack except a Service
whose old node was deleted in step 7):
`git checkout <pre-migration-commit> -- <host-dir>/<stack>`, then
`docker compose up -d --remove-orphans`. The sidecar starts from its
`ts-state/` and gets its old name back. Revert that stack's `.env` from the
backup. The host serve handler can stay; it returns 502 until the stack is
migrated again.

Per Service, after its old node was deleted:
`tailscale serve drain svc:X`, `tailscale serve clear svc:X`; HUMAN: delete
the Service on the Services page, so the name is free; empty the stack's
`ts-state/` (its node key belongs to the deleted node); restore the old stack
as above. The sidecar re-authenticates with `TS_AUTHKEY` (this is why the
OAuth client keeps its Auth Keys scope until 4.7).

Global, per host: restore Serve from the backup in a root process, chosen by
`serve-before.state`, never by the size of a file:

```sh
sudo bash -euo pipefail -c 'B="$1"
[[ -f "$B/capture-complete" ]]
case "$(<"$B/serve-before.state")" in
  empty)  tailscale serve reset ;;
  config) tailscale serve set-raw < "$B/serve-before.json" ;;
  *)      exit 1 ;;
esac' _ <backup-dir>
```

Then roll back every Service as above, `git checkout <pre-migration-commit>`,
restore `cockpit.conf` (or, if `cockpit.conf.absent` is there, remove the new
one) and the tailscale-web unit from `<backup-dir>` with `sudo install` (the
unit back to the user's `~/.config/systemd/user/`, owned by that user),
restore every `.env` from the restic snapshot taken in 4.2 step 6, then bring
up every stack with `--remove-orphans`. The host tags can stay.

### 4.7 After a soak period (7 days with both hosts verified)

- HUMAN: Machines page, delete every remaining old sidecar node on both hosts.
- On each host: delete `*/ts-state/`, remove `TS_AUTHKEY` from every `.env`,
  and `sudo rm <backup-dir>/ts-state-*.tgz`.
- HUMAN: remove the Auth Keys scope from the OAuth client that the sidecars
  used. Keep its read scope: tailscale-proxy still uses the same client. Revoke
  any reusable auth key made for sidecars (Settings, Keys).
- HUMAN: remove `tag:container` from `tagOwners` (D8).
- Follow-up in the repo, after the soak: remove the `ts-state/` lines from
  `.gitignore` (5.4).

### 4.8 Client-side updates (HUMAN)

- Forgejo remotes and the macOS runner: no change (the Service keeps the
  name). If SSH warns that the host IP changed, remove the old entry with
  `ssh-keygen -R <old-ip>`; the host key itself is the same.
- ntfy phone apps and the Immich mobile app: no change. Check that a test
  notification arrives and a photo syncs.
- Bookmarks and password-manager entries: every other URL moves from
  `https://<svc>.<tailnet>.ts.net` to the front door in section 2. A
  password manager that matches by host now sees all path-mounted apps on
  one host name.
- Cockpit on the LAN also needs the prefix now:
  `https://<server-ip>:9090/cockpit-ui/`.
- Uptime Kuma: edit each HTTP monitor to its new URL in the UI (its DB schema
  is UNVERIFIED, so no SQL). Push monitors keep their tokens.
- Syncthing peers that dial `tcp://syncthing.<tailnet>.ts.net:22000`: change
  the address to `<server>.<tailnet>.ts.net` (UNVERIFIED whether any do).
- Off-repo shell rc files or scripts that `curl` ntfy or a `*.ts.net` URL.

## 5. Work breakdown

Two implementer cards work in parallel on separate branches, and the
integration card merges them (design, then server, then Pi). A file has
exactly one owner. A card that needs text in a file it does not own puts that
text in its handoff metadata under `needs_in_server_owned_files`, and the
integration card applies it.

### 5.1 Decisions both cards follow

- Serve script: `scripts/ts-serve-apply.sh` (section 3), written by the server
  card. The Pi card does not copy it and does not wait for it. It writes
  `linux-pi/tailscale-serve/serve.json` and validates it with `jq -e .` and a
  `sed` render of the two placeholders. The integration card dry-runs the
  script against both templates.
- Homepage links. Each homepage already has a variable that holds its own
  host's name: `HOMEPAGE_VAR_HOMEPAGE_DOMAIN` on the server and
  `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` on the Pi. Its value becomes the host
  node's MagicDNS name, and every link to a path or registry port on that
  host is built from it (`https://{{HOMEPAGE_VAR_HOMEPAGE_DOMAIN}}/glances/`,
  `https://{{HOMEPAGE_VAR_HOMEPAGE_DOMAIN}}:8444/`). The per-service
  `HOMEPAGE_VAR_<SVC>_DOMAIN` variables are removed, except
  `HOMEPAGE_VAR_FORGEJO_DOMAIN`, `HOMEPAGE_VAR_NTFY_DOMAIN` and
  `HOMEPAGE_VAR_IMMICH_DOMAIN` (Services). Cross-host links keep their
  variables: the server's `HOMEPAGE_VAR_PI_HOMEPAGE_DOMAIN` and the Pi's
  `HOMEPAGE_VAR_MAIN_HOMEPAGE_DOMAIN` now hold the other host node's name.
- `.gitignore` keeps both `*/ts-state/` lines in this migration. The
  directories stay on disk until the soak (4.7) for rollback, and they hold
  node keys, so they must stay ignored. The backup scripts' `ts-state`
  excludes stay too.
- The tailscale-web unit gets its origin from
  `EnvironmentFile=%h/.config/tailscale-web.env`
  (`TAILSCALE_WEB_ORIGIN=https://<server>.<tailnet>.ts.net`), with a committed
  `linux-server/tailscale-web.env.example`. The unit itself holds no host
  name, so the `diff -q` in `platforms/server.sh` keeps working.
  `server_extras` creates the env file when it is missing, filled from
  `tailscale status --json` the same way it fills `TAILSCALE_HOSTNAME` today.
- Changes to `docs/ONE_NODE_PER_HOST.md` for a deviation: the Pi card edits
  only the 2.3 tables and 4.4; the server card edits everything else. Record
  each deviation in the handoff metadata too.

### 5.2 Server card (`feat/86-server`) owns

| Files | Change |
|---|---|
| `scripts/ts-serve-apply.sh`, `scripts/test-ts-serve-apply.sh` | New (section 3) |
| `.github/workflows/lint.yml` | One step that runs `scripts/test-ts-serve-apply.sh` |
| `linux-server/tailscale-serve/serve.json` | New: every 2.2 row |
| `linux-server/tailscale-serve/.env.example` | New: the two render keys with placeholders (3.1, 3.3) |
| `linux-server/<stack>/` for the 19 stacks in 2.2 | Compose, `.env.example`, app config per 2.2; delete `ts-serve.json`; delete the `cockpit/` and `tailscale-web/` stacks except `cockpit/cockpit.conf.example` |
| `linux-server/glances/.env.example` | `GLANCES_ALLOWED_HOSTS` example lists the server's MagicDNS name. The entrypoint bug (`allowed_hosts` vs `webui_allowed_hosts`, [A Findings]) is not fixed here; add it to `docs/TODO.md` |
| `linux-server/backup/`, `linux-server/dragonwilds/`, `linux-server/forgejo/runner-status.sh` and its `.env.example` | Loopback defaults per D10 and 2.2 neighbours |
| `linux-server/tailscale-web.service`, `linux-server/tailscale-web.env.example`, `platforms/server.sh` | 5.1. Run `bash scripts/dryrun-smoke.sh` |
| `linux-server/HTTPS.md` | Rewritten for host serve: the section 3 mechanism, the 2.1 registry, how to add a service, the Service steps. The Pi part comes from the Pi card's metadata |
| `linux-server/README.md`, `post-install.md`, `immich/README.md`, `ntfy/README.md`, `ups/README.md`, `backup/README.md`, `dragonwilds/README.md`, `dragonwilds/QUICK_START.md` | URLs, `TS_AUTHKEY` and sidecar text [C §9] |
| `macOS/forgejo-runner/` (`lib.sh`, `verify.sh`, `.env.example`, `README.md`) | Comment wording only ("sidecar" becomes "Tailscale Service"); the URL does not change |
| `AGENTS.md` | The `linux-pi/` layout line drops `ts-serve.json` |
| `docs/TODO.md`, `docs/CHANGELOG.md` | TODO: close the #49 items D9 makes obsolete, reword the rest, add the glances bug and the post-soak `.gitignore` cleanup. CHANGELOG: one new entry for both hosts |

### 5.3 Pi card (`feat/86-pi`) owns

| Files | Change |
|---|---|
| `linux-pi/tailscale-serve/serve.json` | New: every 2.3 row |
| `linux-pi/tailscale-serve/.env.example` | New: the two render keys with placeholders (3.1, 3.3) |
| `linux-pi/adguard/`, `linux-pi/homepage/` | Remove the sidecar, `ts-serve.json`, `TS_AUTHKEY`; homepage links per 5.1 |
| `linux-pi/motioneye/`, `linux-pi/cups/docker-compose.yml`, `linux-pi/cups/ts-serve.json` | Delete (sidecar-only stacks) |
| `linux-pi/cups/setup.sh`, `test-setup.sh`, `.env.example`, `README.md` | Drop `PINNED_SIDECAR_SUBNET`/`CUPS_SIDECAR_SUBNET` from the allow lists and validation; the alias becomes the Pi's MagicDNS name |
| `linux-pi/adguardhome-sync/.env.example`, `linux-pi/backup/.env.example`, `linux-pi/backup/README.md` | 2.3 neighbours |
| `linux-pi/README.md` | Host tailscaled and `tag:pi` (4.4), host serve instead of sidecars, the new URLs |

### 5.4 Not in either card

- Removing the `ts-state/` lines from `.gitignore`: after the soak, a
  separate change.
- The ACL least-privilege work (#49, D8).
- A `setup.sh` profile for the Pi.

## 6. User-overridable defaults

Each item is a default the design picked where another choice also works. To
change one, edit the listed sections before the implementer cards start, or
record the change as a deviation afterwards (5.1).

| # | Default | Alternatives | Cost of changing | Sections |
|---|---|---|---|---|
| O1 | Services: `svc:forgejo`, `svc:ntfy`, `svc:immich` | forgejo at `/forgejo/` with `ROOT_URL`; ntfy or immich on a registry port | Every clone's remote, the runner URL and the phones change; the Forgejo `/v2` registry needs its own root route | D3, D4, 2.2, 4.3 |
| O2 | Service names reuse the old node names | New names (e.g. `git`) | No outage window for the delete-then-define step, but every client changes | D3, 4.3 |
| O3 | Homepage owns `/` on each host | Homepage on a registry port and `/` redirects to it | One more port; root-absolute escapes from other apps land on a redirect instead of a 404 | D2, 2.2, 2.3 |
| O4 | Tailnet port registry 8443–8449 and its order | Any other free ports | Bookmarks and monitors use these numbers | 2.1 |
| O5 | New loopback ports 2222, 3300, 8100–8105 | Any free ports | None outside the host | 2.2 |
| O6 | Mount names equal the stack directory name; `/cockpit-ui/` for cockpit | Shorter names (`/qbt/`, `/st/`) | App base-path settings must match | 2.2, 2.3 |
| O7 | NPM bound to `NPM_BIND_IP` (the LAN IP) | A DHCP reservation plus the same bind; an interface-name firewall rule; test the all-interfaces bind live and keep it if self-traffic reaches serve | A DHCP change breaks the bind at boot | D7, 4.3 |
| O8 | Host tags `tag:server`, `tag:pi`; ACL tightening deferred to #49 | Tighten grants in this change | A missed port breaks a service | D8, D9, 4.1 |
| O9 | Same-host consumers use loopback | Use the front-door URLs once self-reach is verified live | Alerts depend on tailscaled | D10 |
| O10 | Syncthing GUI on `0.0.0.0` inside its container | `insecureSkipHostcheck` in its config with a loopback bind | The same effect, but in off-repo config | 2.2 |
| O11 | Serve apply via `set-raw` with a whole-listener replace | Imperative `tailscale serve --bg ... --set-path` commands per handler | Harder to diff, no single template | 3.5 |
| O12 | Render values from a gitignored `<host-dir>/tailscale-serve/.env` (committed `.env.example`), checked against `tailscale status --json`; the live node is the fallback only when that `.env` is missing | Live node only, no `.env` | A drifted `.env` is rejected, so only the extra file and the drift check go away | 3.3 |
| O13 | Server first, Services last, in the order ntfy, immich, forgejo | Forgejo in its own maintenance window, on another day | None | 4.3 |
| O14 | Soak of 7 days before deleting old nodes, `ts-state/` and the Auth Keys scope | Shorter or longer | Rollback gets harder after cleanup | 4.7 |
| O15 | Uptime Kuma monitors are edited in the UI | A SQL update on `kuma.db` once its schema is checked | A bad update corrupts the DB | 4.8 |
| O16 | Pi host node joins with `--accept-dns=false` if it is new | `--accept-dns=true` | The Pi's resolver depends on tailscaled | 4.4 |
| O17 | tailscale-web origin from a user env file | A hard-coded origin in the unit on the host only (today's pattern) | The unit in the repo no longer matches the host | 5.1 |
| O18 | Path-mounted apps share one origin, `https://<server>.<tailnet>.ts.net` | Move a sensitive app to a registry port or a Service | Uses a port or 1 of the 7 Services left | D2, 2.2 |

Accepted cost behind O18: a `Path=/` cookie or a localStorage entry from one
path-mounted app is visible to the others [A]. Registry-port apps are separate
origins for localStorage, but browsers do not isolate cookies by port, so a
`Path=/` cookie on the host name reaches them too. Only the three Services
have their own host name.

UNVERIFIED items and their fallbacks, in one place:
- A Service claiming a live node's name (fallback: delete the node first; D3).
- A tailnet nameserver pointing at a sidecar IP (fallback: check and repoint;
  D5, 4.1).
- NPM `0.0.0.0:443` vs serve for same-host traffic (fallback: `NPM_BIND_IP`;
  D7).
- A host reaching its own serve listener or Service VIP (fallback: loopback;
  D10).
- `Services` applied through `set-raw` (fallback: `tailscale serve
  --service=...`; 3.5).
- CUPS `ServerAlias` with a port-bearing `Host` (fallback: add the port form
  if it returns 400; 4.5).
- The Pi resolving the server's MagicDNS name (fallback: fix before the
  neighbour step; 4.4).
- From research [A]: cockpit login and the `tailscale web` manage flow under
  a prefix, portainer websocket exec, watchtower callers with a path URL, the
  openspeedtest body limit, the Uptime Kuma schema, Syncthing peers dialing a
  sidecar name. Each has a check in 4.5 or 4.8.
