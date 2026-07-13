# cups/ — Pi print server + HTTPS front door

The Pi hosts a USB printer shared through CUPS (`cupsd` on the host, `:631`).
This directory adds a **Tailscale sidecar** (`cups-ts`) that publishes an HTTPS
front door at `https://cups-pi.<tailnet>.ts.net`, and a **`setup.sh`** that
applies the host CUPS access policy from a gitignored `.env`.

## Who prints, and how

There are two classes of client, and the config has to serve both:

1. **Family devices on the home Wi‑Fi.** They are *not* on the tailnet. They
   discover the printer over Bonjour/mDNS and print directly to the Pi on the
   LAN (`:631`), addressing it by IP or by `<hostname>.local`.
2. **The operator's own devices, remote.** They reach the printer through the
   Tailscale sidecar: `:443` HTTPS → `host.docker.internal:631`, encrypted over
   WireGuard, no LAN exposure required.

Because of (1), a "tailnet-only" lockdown is wrong here — it would silently stop
the whole family from printing. The policy therefore allows the **home LAN** as
well as the sidecar, while still refusing everything else.

## Why the host CUPS config is hardened (and not left at defaults)

CUPS out of the box (and a drifted config) commonly ends up with two dangerous
lines:

- **`ServerAlias *`** — disables HTTP `Host` header validation. Any `Host` is
  accepted, which opens a **DNS‑rebinding** path: a malicious web page the user
  visits can script requests to the local print server. We replace `*` with the
  explicit names the server legitimately answers to.
- **`Allow all`** on the root `<Location />` — lets *any* host that can reach
  `:631` browse the UI and submit jobs. We replace it with an explicit allow
  list: `localhost`, the sidecar's Docker subnet, and the home LAN subnet.

Net access after hardening: **localhost + home LAN + the Tailscale sidecar** —
appropriate for a shared home printer, and never `*` / `all`. The Pi is not
port‑forwarded, so it is not reachable from the internet regardless.

The `<Location /admin*>` blocks keep their `Require user @SYSTEM` authentication
untouched — administering printers still needs a login.

## Why the values live in `.env`

This repo is public. The home LAN subnet, the Pi's hostname, and the tailnet
name are all identifying, so they must not be committed. They live in a
gitignored `.env`; `setup.sh` renders them into `/etc/cups/cupsd.conf`. The
tracked files (`setup.sh`, `.env.example`, this README) carry only placeholders.

- `CUPS_SERVER_ALIAS` → the `ServerAlias` line (tailnet name + `<hostname>` +
  `<hostname>.local`).
- `CUPS_ALLOW_FROM` → the `Allow` lines on the root `<Location />` (`localhost` +
  sidecar subnet + LAN subnet).

`setup.sh` refuses to write `ServerAlias *` or `Allow all`, so the safe posture
can't be re-introduced by accident.

## The sidecar subnet pin

`CUPS_ALLOW_FROM` includes the `cups-ts` sidecar's Docker bridge subnet
(`172.21.0.0/16`). Docker assigns bridge subnets dynamically, so that subnet is
**pinned** in `docker-compose.yml` (`networks.default.ipam.config.subnet`). If it
weren't, recreating the network could hand out a different subnet and silently
break the HTTPS front door (the sidecar would no longer match the `Allow` rule).
If you ever change the pin, update `CUPS_ALLOW_FROM` and re-run `setup.sh`.

## Usage

```bash
cd linux-pi/cups
cp .env.example .env        # then fill in real values (see below)

# find the sidecar's actual bridge subnet if you need to confirm it:
docker compose create
net="$(docker inspect cups-ts --format '{{range $n,$_ := .NetworkSettings.Networks}}{{$n}}{{end}}')"
docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}'

bash setup.sh --dry-run     # show the exact cupsd.conf diff + validate, no writes
sudo bash setup.sh          # apply, cupsd -t validate, restart cups.service
```

`setup.sh` is idempotent — re-running only rewrites the `ServerAlias` line and
the root `<Location />` allow rules to match `.env`, backs up the previous
`cupsd.conf` to `cupsd.conf.bak.<epoch>`, and leaves everything else alone.

### Note on macOS "Hold for authentication"

If a Mac shows a job stuck on **"Hold for authentication"**, it usually means the
server refused the request (a `403`/`400` from a too-tight allow list or
`ServerAlias`), which macOS surfaces as an auth prompt even when no auth is
actually required. Fix the policy (add the client's subnet / the Bonjour name),
then **resume or re-print** the held job — macOS does not always retry it
automatically.

### Debian socket activation

On socket‑activated installs, `cups.socket` can own `:631`. If config changes
don't take effect, force the service to own the port:

```bash
sudo systemctl disable --now cups.socket
sudo systemctl enable --now cups.service
sudo systemctl restart cups.service
```
