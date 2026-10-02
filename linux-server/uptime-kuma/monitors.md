# Uptime Kuma monitors

Uptime Kuma runs at `https://<server>.<tailnet>.ts.net:8444` (host tailscale
serve, see [`../HTTPS.md`](../HTTPS.md)). Its monitors live in its own
database (`./data/kuma.db`), not in this repo, so this list is the reference to
create or edit them in the UI: **Add New Monitor**, or open a monitor and
**Edit**. There is no SQL import: the database schema is not checked
(docs/ONE_NODE_PER_HOST.md O15).

`<host>` below is `<server>.<tailnet>.ts.net`, the server's host node.

## HTTP(s) monitors: the front doors

These test the URL a person uses, so they run from the server to its own
tailnet name (and to the three Service names). Whether a host reaches its own
serve listener and Service VIPs is not verified (docs/ONE_NODE_PER_HOST.md
D10). If a monitor fails while the same URL works from another tailnet device,
switch that monitor to the loopback URL in the last column.

| Name | URL | Accepted codes | Loopback fallback |
|---|---|---|---|
| homepage | `https://<host>/` | 200 | `http://127.0.0.1:3000/` |
| glances | `https://<host>/glances/api/4/status` | 200 | `http://127.0.0.1:61208/api/4/status` |
| openspeedtest | `https://<host>/openspeedtest/` | 200 | `http://127.0.0.1:3030/` |
| qbittorrent | `https://<host>/qbittorrent/api/v2/app/version` | 200, 401, 403 | `http://127.0.0.1:8080/api/v2/app/version` |
| syncthing | `https://<host>/syncthing/rest/noauth/health` | 200 | `http://127.0.0.1:8384/rest/noauth/health` |
| watchtower | `https://<host>/watchtower/v1/metrics`, header below | 200 | `http://127.0.0.1:8105/v1/metrics` |
| cockpit | `https://<host>/cockpit-ui/` | 200 | `https://127.0.0.1:9090/cockpit-ui/` (ignore TLS errors) |
| filebrowser | `https://<host>/filebrowser/` | 200 | `http://127.0.0.1:8102/` |
| portainer | `https://<host>/portainer/api/system/status` | 200 | `http://127.0.0.1:9000/api/system/status` |
| tailscale-web | `https://<host>/tailscale-web/` | 200 | `http://127.0.0.1:8088/` |
| adguard | `https://<host>:8443/control/status` | 401, 403 | `http://127.0.0.1:8100/control/status` |
| speedtest-tracker | `https://<host>:8445/admin/login` | 200 | `http://127.0.0.1:8104/admin/login` |
| ups (PeaNUT) | `https://<host>:8446/` | 200 | `http://127.0.0.1:8097/` |
| nginx-proxy-manager | `https://<host>:8447/` | 200 | `http://127.0.0.1:81/` |
| atvloadly | `https://<host>:8448/` | 200 | `http://127.0.0.1:8101/` |
| ntfy | `https://ntfy.<tailnet>.ts.net/v1/health` | 200 | `http://127.0.0.1:8103/v1/health` |
| immich | `https://immich.<tailnet>.ts.net/api/server/ping` | 200 | `http://127.0.0.1:2283/api/server/ping` |
| forgejo | `https://forgejo.<tailnet>.ts.net/api/v1/version` | 200 | `http://127.0.0.1:3300/api/v1/version` |

Uptime Kuma itself is not in the list: a monitor cannot report its own outage.

Watchtower has no UI; its monitor needs the header
`Authorization: Bearer <WATCHTOWER_API_TOKEN>` (the value from
`../watchtower/.env`). An unauthenticated probe gets `401`, so the header is
what proves the API is both up and reachable.

## Push monitors

A push monitor waits for a host job to call it. Each job runs on the server,
so its `KUMA_PUSH_URL` uses the loopback host (D10):
`http://127.0.0.1:3001/api/push/<token>`. When you create the monitor, Uptime
Kuma shows the URL with its own host; keep only the `/api/push/<token>` part.

| Name | Job | Interval | `.env` |
|---|---|---|---|
| backup | `backup.timer` (nightly) | 24h + slack | `../backup/.env` |
| Forgejo runner | `forgejo-runner-status.timer` (120s) | 120s, Retries 2, Retry Interval 20s | `../forgejo/.env` |
| Pi backup | the Pi's backup timer | its schedule | on the Pi: `linux-pi/backup/.env` with `https://<host>:8444/api/push/<token>` |

Push tokens don't change when the URL host changes, so existing push monitors
keep working once each `.env` points at the new host.

## Status page

Create a status page with the slug `default`; the homepage uptime-kuma widget
reads it.
