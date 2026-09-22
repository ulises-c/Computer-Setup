# RuneScape: Dragonwilds dedicated server

Native Linux dedicated server (Steam app **4019830**), run by `dragonwilds.service`
and surfaced on the homepage dashboard through a loopback status endpoint.

Listens on **UDP 7777**, with ufw rules allowing it from the LAN and the tailnet
only — no public exposure, no router port-forward. Those rules are enforced only
if ufw is **active**; `setup.sh` warns when it is not, in which case nothing but
the router's lack of a port-forward keeps the server off the internet.

Join by IP literal (`192.168.x.y:7777` or `100.x.y.z:7777`); the client does not
resolve hostnames — see pain point 10.

In a hurry? [QUICK_START.md](QUICK_START.md) is the copy-paste path. This file
explains the reasoning and documents where the official guide is wrong.

---

## Pain points

Everything below was hit while standing this up. Most are silent failures, which
is what makes them expensive.

### 1. `OwnerId` is mandatory and is not your SteamID

Without it the server boots, binds its port, looks healthy — and never creates a
world. The only signal is two lines in the log:

```
The [OwnerId] for this server is empty.
An OwnerId is required for normal Server operation.
```

It is an **Epic Online Services Product User ID**: 32 hex characters, from the
in-game **Settings** menu. Not a SteamID64 (17 decimal digits). Steam is only the
delivery channel here — the server authenticates through EOS
(`LogRedpointEOSIdentity: Performed Login on dedicated server`), so Steam identity
is not involved. The anonymous `steamcmd` login has nothing to do with it.

`setup.sh` warns when it sees an empty `OwnerId`.

### 2. The config path is `Config/LinuxServer`, not `Config/Linux`

The official guide says `RSDragonwilds/Saved/Config/Linux/DedicatedServer.ini`.
The server actually writes:

```
RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
```

### 3. The save directory is `SaveGames`, not `Savegames`

The guide says `RSDragonwilds/Saved/Savegames`. The server uses
`RSDragonwilds/Saved/**SaveGames**` — capital G, the Unreal standard. On Windows
these are the same directory; on Linux they are not, so following the guide
literally creates a directory the server never reads. Files dropped there are
silently ignored.

### 4. World loading keys off the name *inside* the save, not the filename

The guide says the server "loads the latest `.sav` file available". It does not.
Nothing is selected by modification time. Verified by running the server against
each layout and reading `LogPersistence`:

| Location | `DefaultWorldName` | Name inside save | Result |
| --- | --- | --- | --- |
| `Savegames/1.sav` (as documented) | `World-90667` | `1` | ignored → `NewGame()` |
| `SaveGames/1.sav` | `World-90667` | `1` | ignored → `NewGame()` |
| `SaveGames/<owner>.sav` | `<owner>` | `1` | ignored, no load attempted |
| `SaveGames/1.sav` | `1` | `1` | `LoadGameFromSaveGame()` — loads |

Row 3 is the trap: renaming the file *and* the config to match each other still
fails, because the world name recorded in the save's header still says `1`. So
the rule is:

> `DefaultWorldName` must equal the world name stored inside the save, and the
> file must be named `<that name>.sav`, in `SaveGames/`.

A mismatch produces **no error and no load attempt**. The server quietly creates a
fresh world, which overwrites the import on the next save.

### 5. A client save's world name is a slot number, and the owner name looks like it

Client worlds are named by slot, so an imported singleplayer save is almost
always `WorldName[1]` — needing `DefaultWorldName=1`, which does not look like a
world name at all.

Worse, the save header lists its *field names* first and then its values, so a
naive `strings` read suggests the world is named after you. The value block is:

```
1           <- WorldName
L_World     <- WorldMapName
<owner>       <- WorldNameOwner
<owner>       <- owner display name
```

`strings` cannot read this at all: a one-character world name is below any
minimum-length threshold, so `1` never appears in its output. Use the helper,
which parses the length-prefixed fields:

```bash
./read-save-info.sh <save>.sav
```
```
world name : 1
map        : L_World
owner      : <owner>
saved at   : 2026-09-21T22:14:36.086Z

set DefaultWorldName=1 and name the file 1.sav
```

### 6. The client is Windows-only, so on Linux the save is inside a Proton prefix

Steam app **1374490** ships `oslist "windows"` only. The `C:\Users\…\AppData\Local`
path the wiki gives maps into the prefix; there is no native Linux save location:

```bash
find ~/.local/share/Steam ~/.var/app/com.valvesoftware.Steam \
  -path '*RSDragonwilds/Saved/SaveGames*' -name '*.sav' 2>/dev/null
```

Steam Cloud uses Auto-Cloud against that same path rather than keeping a separate
downloadable copy, so launch the game once and let it sync before copying.

### 7. A port conflict looks like a clean exit — `Restart=on-failure` will not recover it

If something already holds UDP 7777, the server logs, shuts down, and returns
**exit status 0**. systemd sees success, so `Restart=on-failure` does not fire and
the unit stays dead:

```
Main PID: … (code=exited, status=0/SUCCESS)
Duration: 5.168s
```

Known gap, deliberately not papered over: `Restart=always` would mask genuine
clean shutdowns. Check for a stray process before blaming the unit:

```bash
ss -ulnp | grep :7777
```

### 8. The server rewrites `DedicatedServer.ini` on shutdown

Edit it only while the service is stopped, or your changes are overwritten. It
also rewrites `DefaultWorldName` itself when it creates a world.

### 9. `RSDragonwildsServer.sh` does not `exec`

The launcher spawns the real binary as a child, so killing the wrapper orphans a
running server that keeps holding port 7777. systemd handles this correctly via
cgroups; it only bites when starting the server by hand.

### 10. The client needs an IP literal, not a MagicDNS name

Joining over Tailscale needs the tailnet IP (`100.x.y.z:7777`, from
`tailscale ip -4`). The MagicDNS name is rejected by the client's connect field
even though the name resolves correctly at the OS level — `getent hosts
<host>.<tailnet>.ts.net` returns the right `100.x` address on the server. The
client parses the address itself and never performs a DNS lookup.

### 11. Browser entries and join codes dial the WAN address, which never arrives

The server shows up in the browser by name, but on some clients joining that
entry fails with "Connection Lost / Network connection was interrupted", while
typing the address by hand works. Join codes fail the same way. The log shows
the client's LAN probes being answered and **no** matching
`NotifyAcceptedConnection`, so the client never reaches the server at all.

The cause is not this host's multi-homing, which an earlier revision of this file
blamed. A browser entry resolves to the server's LAN address only if the client
receives the server's reply to its LAN probe. A client firewall with
default-deny incoming drops that reply, so the client falls back to the address
EOS holds. The server registers `0.0.0.0:7777` with EOS, so EOS holds the address
it observes, the WAN address, and a LAN client dialling that needs NAT loopback
the router does not do. Join codes appear to use the EOS address regardless
(retesting after the fix is still open). Captured on both
ends; see [Network connectivity](#network-connectivity) for the evidence and the
client-side fix.

### 12. Connections are unencrypted unless you configure signing keys

```
The dedicated server had no public/private signing keypair set, so the connection
will not be automatically encrypted.
Skipping verification of connecting user <id> because this connection is not
trusted. To verify users, turn on trusted dedicated servers.
```

Normal for an unconfigured dedicated server. Over Tailscale the traffic is inside
WireGuard anyway; on plain LAN it is in the clear. Worth knowing before forwarding
the port publicly.

### 13. "Running" does not mean joinable

Roughly 30 seconds of asset loading separate process start from the UDP socket
opening. The status card reports `starting` until the port is actually bound
rather than claiming the server is up.

---

## How players join

Three routes, in rough order of reliability:

1. **Invite code** — the server mints one per session and it is the only way in
   for console players, who cannot enter an IP. It appears on the homepage card
   and in the log:

   ```bash
   journalctl -u dragonwilds.service --since "$(systemctl show dragonwilds.service -p ActiveEnterTimestamp --value)" \
     | grep JoinCode
   ```

   Format is `XXXX-XXXX`. Players enter it from the World Browser.

2. **Direct connect** — multiplayer menu → Direct, then `<ip>:7777`. IP literal
   only; see pain point 10.

3. **Server browser** — Worlds → Public, search the exact `ServerName`
   (case-sensitive).

Steam invites are a known Jagex issue: they do not currently connect to a
dedicated server. Use one of the above instead.

On this network the join code does not work: it resolves the address through
EOS, which hands out the WAN address (pain point 11). The browser entry works
on LAN clients that receive the server's reply to their LAN probe; a
client firewall has to allow it. Direct connect always works — see
[Network connectivity](#network-connectivity).

The code is minted per session, so assume it changes whenever the service
restarts — which is why the status card reads it from the current run's journal
rather than caching it.

## Playing from outside the network

The tailnet address works from anywhere — that is the whole point of the `100.x`
range. Nothing needs to change on the server: the ufw rule is bound to the
`tailscale0` interface, not to a subnet, so a peer connecting from another
network is allowed exactly like one at home.

For other people to join, they each need to be on the tailnet. Inviting them to
the whole tailnet gives them every machine on it; **sharing just this node** is
the narrower option and is usually what you want:

> Tailscale admin console → Machines → this host → **Share** → send the link.

A shared user sees only this one machine. They still connect to
`100.x.y.z:7777`.

If a connection feels laggy, check whether Tailscale found a direct path or fell
back to a relay:

```bash
tailscale ping <peer>
```

`direct` is a normal peer-to-peer UDP path. `via DERP` means NAT traversal failed
and traffic is being relayed, which adds real latency for a game — usually fixed
by enabling UPnP/NAT-PMP on the restrictive side.

The alternative is forwarding UDP 7777 on the router, which makes the server
public. That needs a matching ufw rule (`setup.sh` deliberately adds none) and
means anyone who finds the port can attempt to join — set `WorldPassword` first.

## Network connectivity

Every join route ends in the client dialling an IP literal on UDP `SERVER_PORT`.
What differs is **where that address comes from**, and one of the sources is
wrong on this network.

| Route | Address comes from | Works here |
| --- | --- | --- |
| Typed (Direct) | you | ✅ LAN and tailnet |
| Browser entry, probe reply received | the reply's source address | ✅ on LAN |
| Browser entry, no probe reply | EOS | ❌ dials the WAN address |
| Join code | EOS | ❌ dials the WAN address |

### Why the EOS routes fail

The server never tells EOS a reachable address. It binds every interface and
logs:

```
LogRedpointEOSNetworking: User '(dedicated server)' is now listening on Internet address '0.0.0.0:7777'
```

`0.0.0.0` means "all interfaces", so EOS substitutes the address it sees the
server arrive from — the WAN address. Clients then dial that, and with no
port-forward the packets die at the router. A LAN client would need NAT loopback
(hairpin) for it to work even with a forward in place.

Confirmed on both ends:

- **Server side.** During a failed join the client's probes are answered and
  nothing else arrives: no packets to `SERVER_PORT` on any interface, on either
  the LAN link or `tailscale0`.
- **Client side.** The failing browser row sends ~19 unanswered packets to
  `<wan-ip>:7777`, from the LAN interface, never to the server's LAN or tailnet
  address.

This also explains the join code, which resolves through the same EOS session,
and the in-game recent-connections list, which reports say fails the same way.

The address is the server's **outbound** public IP, as EOS sees it at
registration. A community report shows it: a server behind a VPS relay was
advertised with the home WAN address until its egress was switched to a Tailscale
exit node on the VPS *before* EOS registered — after which the browser row carried
the VPS address and joins worked. So there is nothing to configure on the server:
whatever public address its HTTPS leaves from is what gets advertised, and an EOS
route can only work if UDP 7777 on that public address reaches the server.

It is **not** a firewall problem (ufw is inactive, see issue #81), and not the
Docker bridges (issue #75): the probe reply carries no address at all, just an ID
and the client's echoed nonce, so the bridges cannot leak into it.

### The same browser entry resolves differently per client

There is one browser entry. It is listed because the server is associated with
the player's `OwnerId` through EOS, not because anything found it on the LAN.
The LAN only supplies the *address*: while browsing, the client also broadcasts
a probe to UDP 45453 (from its port 45454) and the server replies from its LAN
address. The reply carries no address, so a client that receives it
can only use the reply's source — correct by construction — and dials the LAN
address. A client that does not receive it falls back to the EOS address.

Two clients on the same LAN, joining the same entry:

| Client | Firewall | Tailscale | Result |
| --- | --- | --- | --- |
| Handheld on Wi-Fi | none | no | ✅ reaches the LAN address ~1 s after the probe |
| Desktop on Ethernet | ufw, deny incoming | yes | ❌ dials the WAN address |

The server sent its replies to both; the server-side capture shows them leaving
the LAN interface. The difference is the **client's firewall**, not Tailscale.
The desktop runs ufw with default-deny incoming, and its kernel log shows every
reply dropped, the last one two seconds before the client dialled the WAN
address:

```
[UFW BLOCK] IN=<lan-iface> SRC=<server-lan-ip> DST=<client-ip> PROTO=UDP SPT=45453 DPT=45454
```

The probe goes to a broadcast address and the reply comes back from a unicast
one. Linux connection tracking cannot match those as a pair, so a stateful
firewall treats the reply as unsolicited and drops it. The handheld has no
active firewall, so it accepts the reply.

The fix goes on the **client**. Allow probe replies from the LAN and nothing
else:

```bash
sudo ufw allow proto udp from <lan-cidr> port 45453 to any port 45454 comment 'Dragonwilds LAN discovery replies'
```

Scoping to the subnet rather than the server's address keeps the rule valid if
the server is renumbered. `to any port 45454` matters: a source port is the
sender's choice, so without it anything on the LAN could reach every UDP port on
the client just by sending from 45453. The client probed from 45454 in every
capture.

Verified: with the rule in place, the desktop joins from the browser entry, and
the entry resolves to the LAN address with nothing typed. The probe broadcasts
do not cross the tailnet, so away from home the entry falls back to the EOS
address and it is still the typed tailnet address.

**Untested:** whether a join code works from a client running Tailscale. Every
code attempt so far predates the ufw fix, so it is also untested whether a code
resolves through the probe reply the way the browser entry does. The captures
point the other way: a code resolves through the EOS session, whose address is
the WAN address, and nothing on the tailnet routes that. Consoles cannot run
Tailscale or change a firewall, so none of this applies to them.

### Options for avoiding a typed address

| Option | Typing | Tailnet | Consoles | Exposure |
| --- | --- | --- | --- | --- |
| Browser entry, reply received | none | no (LAN only) | yes | none |
| Client-side redirect | none | kept | no | none |
| Typed address | every join | kept | yes | none |
| Router port-forward | none | kept | yes | **public** |
| VPS relay + exit-node egress | none | kept | yes | **public** (VPS) |

- **Client-side redirect** — on a Linux client, rewrite the dead WAN address to
  the tailnet address, so the browser row and the join code both work from that
  machine and keep working away from home:

  ```bash
  sudo iptables -t nat -A OUTPUT -p udp -d <wan-ip> --dport 7777 \
    -j DNAT --to-destination <server-tailnet-ip>:7777
  ```

  The WAN address is dynamic, so the rule goes stale when the ISP changes it.
  Per-machine, and no help to consoles.

- **VPS relay** — the community fix above: forward UDP 7777 on a VPS back over
  Tailscale, and route this host's egress through the VPS as an exit node once
  steamcmd has finished (the reporter's container hung updating through it), so
  EOS registers the VPS address. It works for every client including consoles,
  but it is a public endpoint like a port-forward, just on someone else's IP.

- **Not `-MULTIHOME`.** It is the only address option in the binary (`MULTIHOME`
  appears in UTF-16, which an ASCII `strings` scan misses; `PUBLICIP`,
  `AdvertisedAddress` and `ExternalAddress` are all absent), but it only chooses
  the bind address. EOS advertises the observed egress address regardless, and
  binding one interface would cost tailnet access for nothing.

- **Router** — ruled out on the Orbi RBR750 in use here. Its loopback applies
  only to traffic matching an existing port-forward rule, there is no LAN-only
  redirect, and owners report loopback not working on that model regardless.

With no public endpoint, the EOS routes cannot be made to work for anyone, so
the choice is between the zero-exposure options. Direct connect remains the
recommendation: it needs nothing configured anywhere and works on LAN, tailnet
and remote. The client rejects hostnames (pain point 10) and does not save Direct
entries, so it is a typed address every time; at home the browser entry avoids
that on any client that receives the probe reply.

### Diagnosing a failed join

Check the client's firewall first. On a Linux client with ufw logging on, the
dropped probe replies are already in the kernel log:

```bash
sudo journalctl -k --since today | grep 'UFW BLOCK' | grep 'SPT=45453'
```

Any hits mean the fix above. Otherwise, on the server, watch what arrives while
a client tries to join:

```bash
sudo tcpdump -ni any -l "udp and host <client-ip> and not port 45453 and not port 45454"
```

Nothing arriving means the client is dialling elsewhere, and only a client-side
capture shows where:

```bash
sudo tcpdump -ni <lan-iface> -l "udp and not port 41641 and not port 5353"
```

Exclude Tailscale's own port (41641) and mDNS (5353) or the output is unreadable.
The destination of the packets that appear when Join is pressed is the whole
answer: the WAN address means this issue, the server's LAN or tailnet address
means look further.

The probe exchange can be watched from the server:

```bash
sudo tcpdump -ni <lan-iface> -X udp port 45453
```

Note for whenever ufw is enabled (#81): only `SERVER_PORT` is opened today.
Joining works without 45453, but the browser entry resolving to the LAN address —
the one route that needs no typed address — does not, so it would need its own
LAN-scoped rule.

## Why the game server is not a container

Everything else under `linux-server/` is a Docker service; this one deliberately
is not. The server is a ~5.5 GB Unreal build that steamcmd installs and updates
in place, and it wants a UDP socket of its own. Containerising it would mean
either `network_mode: host` (a container that buys nothing) or a NAT hop in front
of a latency-sensitive UDP game port, plus a bind mount back to the host for the
game data anyway.

| Piece | Runs as | Why |
| --- | --- | --- |
| Game server | `dragonwilds.service` (native) | Direct UDP 7777, no NAT hop, steamcmd updates in place |
| Status endpoint | `dragonwilds-status` container (~5 MB nginx) | Same pattern as `linux-server/backup`; gives homepage a card |

## Install

```bash
cp .env.example .env    # set DRAGONWILDS_INSTALL_DIR and SERVICE_USER
```

```bash
sudo apt install steamcmd            # if missing
/usr/games/steamcmd +force_install_dir ~/games/dragonwilds \
  +login anonymous +app_update 4019830 validate +quit
```

~1.7 GB download, ~5.5 GB on disk. Game data stays outside this repo.

```bash
sudo bash setup.sh --dry-run         # preview
sudo bash setup.sh
```

`setup.sh` renders the units from templates, enables the service (starting it
only once the game is installed, so the first download never runs inside the
start job) and its timers, installs the auto-updater's polkit rule, opens UDP
7777 to the LAN and tailnet, and brings up the status container.
It reads `.env`, as do the status, update-check and auto-update scripts. The file
is sourced with `set -a`, so a key present in `.env` **overrides** the same
variable in the environment — to override from the environment instead, comment
the key out of `.env`. (Same pattern as `forgejo/runner-status.sh`.)

Paths interpolated into the unit templates are validated against a conservative
charset first, since the rendered units are installed as root.

## Configure

```
<install dir>/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
```

See [`DedicatedServer.ini.example`](DedicatedServer.ini.example) for the keys.

```bash
sudo systemctl stop dragonwilds.service
$EDITOR <install dir>/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
sudo systemctl start dragonwilds.service
```

The guide mentions an admin password, but no such key is generated in the config
— only `WorldPassword`.

### Port

`DedicatedServer.ini` has no port key. The port is `SERVER_PORT` in `.env`
(default 7777), which `setup.sh` renders into the unit as `-port=<n>` and also
uses for the ufw rules, the port health checks in the status and auto-update
scripts, and the connect addresses on the card. Change it in `.env` and re-run
`sudo bash setup.sh`; editing the unit alone leaves the firewall and the checks
on the old port. The homepage card's `description` hardcodes 7777 as well.

`-port=` is Unreal's standard flag and the launcher passes its arguments
straight through; verified on build 25387240 (`SERVER_PORT=7778` bound 7778).
Re-running `setup.sh` does not restart a running server, so restart it to pick
up a change, then confirm the bind — expect `SERVER_PORT` plus the two fixed
ports below:

```bash
sudo ss -ulnp | grep RSDragonwilds
```

The server does **not** fall back to the next free port: a port conflict makes it
exit cleanly (pain point 7).

It also binds two more UDP ports that `-port` does not move:

| Port | Log line | Purpose |
|---|---|---|
| 8888 | `LogDomGameMode: World settings beacon listening on port 8888` | World-settings beacon (`BeaconNetDriver`) |
| 45453 | `LogDomLanProbe: SERVER : Socket setup OK [0.0.0.0:45453]` | LAN probe; its reply supplies a listed entry's LAN address |

Only `SERVER_PORT` is opened in ufw. Joining by typed address works without the
other two, so the beacon evidently is not needed to connect. The LAN probe is a
lead for pain point 11. Both being fixed is why a second server on this host is
not just a matter of a different `SERVER_PORT`.

## Operate

```bash
systemctl status dragonwilds.service
journalctl -u dragonwilds.service -f
sudo systemctl restart dragonwilds.service
```

The unit runs `steamcmd +app_update` as an `ExecStartPre` on every start, so a
restart picks up the current build. Its leading `-` means a Steam outage leaves
the server starting on whatever is already on disk rather than failing to boot.

Shutdown sends SIGTERM and waits up to 120 s: the server flushes its world on
that signal, so cutting it short can lose recent progress.

## Importing a world

See pain points 3–6 above for why each step matters.

```bash
sudo systemctl stop dragonwilds.service
./read-save-info.sh <save>.sav                   # prints the world name to use
cp <save>.sav <install dir>/RSDragonwilds/Saved/SaveGames/<world name>.sav
# set DefaultWorldName=<world name> in DedicatedServer.ini
sudo systemctl start dragonwilds.service
journalctl -u dragonwilds.service | grep -E 'LoadGameFromSaveGame|NewGame'
```

`LoadGameFromSaveGame()` means it worked. `NewGame()` means the name did not
match and a fresh world was created instead.

## Backups

`linux-server/backup` picks up `Saved/SaveGames` (worlds) and `Saved/Config`
(settings, including `OwnerId`) automatically, resolving the install directory
from this folder's `.env` — the same way it handles a relocated Forgejo data dir.
This folder's `.env` is captured too. The game install itself is excluded;
steamcmd re-downloads it.

A `.sav` has no online-snapshot equivalent to sqlite's `.backup`, so a save
written exactly as the 03:30 run reads it could be captured torn. The previous
nightly snapshot is the fallback; stop the service first for a guaranteed-clean
copy.

## Status card

`dragonwilds-status.timer` runs `dragonwilds-status.sh` every minute, writing
`status/dragonwilds-status.json` (gitignored). The nginx container serves it on
`127.0.0.1:8096`, and homepage — host-networked — reads it via a `customapi`
widget, the same arrangement as `linux-server/backup` on `:8099`.

```bash
curl -s localhost:8096/dragonwilds-status.json | jq
bash dragonwilds-status.sh        # regenerate by hand
```

Fields: `status` (`running` / `starting` / `stopped` / `failed` / `unknown`),
`server_name`, `world`, `join_code`, `players`, `players_max`, `player_names`,
`connect_lan`, `connect_tailnet`, `memory_bytes`, `save_bytes`,
`disk_free_bytes`, `uptime_seconds`, `listening`, `owner_configured`,
`world_password`, `build`, `latest_build`, `update_status`, `update_checked`,
`last_save`, `updated`.

### Update checking

`dragonwilds-update-check.timer` runs every two hours on even hours, asking Steam
for the current public build and writing it to `status/.latest-build`. The status
script compares that against the installed build from the app manifest and
publishes `update_status` (`up to date` / `update available (<build>)` /
`unknown`). The query takes about 4 seconds.

It is a separate timer because it is the only part of this that touches the
network — the status script runs every minute and must stay local. The check
never modifies the install.

### Applying updates automatically

`dragonwilds-auto-update.timer` runs every 15 minutes and restarts the server
onto a pending build **only when nobody is playing**. The build download itself
still happens in the service's `ExecStartPre`; this timer only decides when that
restart is allowed. The 15-minute cadence means an update found mid-session lands
shortly after the last player logs off rather than hours later.

It runs as the service user, not root. The checkout and its `.env` are writable
by that same account — and so by a compromised game process — so a root timer
executing them would be a path to root. The one privileged action it needs is
granted narrowly instead: `setup.sh` installs
`/etc/polkit-1/rules.d/50-dragonwilds-restart.rules`, which lets that user
`restart` `dragonwilds.service` and nothing else. Network work stays in
`dragonwilds-update-check.sh`.

The player count comes from `dragonwilds-players.sh` at decision time, not from
the cached status JSON, so nobody is kicked by a count that went stale between
timer ticks. It fails closed: if the journal cannot be read (the user needs the
`adm` or `systemd-journal` group — `setup.sh` warns), the restart is deferred
rather than treating an unknown count as zero.

On restart it confirms the server is back on UDP 7777 **and** on the new build.
Because `ExecStartPre`'s `-` lets a failed download start the old build, "the port
came back" alone is not success. Any failure — the start job failing, the old
build coming back, or the port never binding — alerts at high priority and
records the build in `status/.failed-build`, so it is not retried every 15
minutes. It is retried when a newer build appears, or on any manual restart. The
unit's `TimeoutStartSec=30min` leaves room for the download inside the start job.

Set `AUTO_UPDATE_RESTART=false` in `.env` to be notified but apply updates
yourself:

```bash
sudo systemctl restart dragonwilds.service
```

ntfy alerts fire for "update available" (once per build, not once per tick),
"updated", and a failed restart. Leave `NTFY_URL` empty to disable them —
everything else still works.

Both that `ExecStartPre` and the checker take a `flock` on
`<install dir>/.steamcmd.lock`, since two steamcmd instances sharing `~/.steam`
can trip over each other.

`connect_lan` is derived from the default route rather than the first global
address on the host — on a box with 20-odd Docker bridges, "first" is almost
never the one you can reach (pain point 11). `player_names` falls back to an em
dash so an empty row reads as "nobody" rather than a broken widget.

The document is assembled with `jq -n` (`--arg` for strings, `--argjson` for
numbers and booleans) rather than a heredoc. `ServerName` and `DefaultWorldName`
are operator-editable free text, and the hand-rolled escaper this replaced handled
only `\` and `"` — a tab in `ServerName` was enough to emit invalid JSON and blank
the card. jq is already a hard dependency of `../backup/backup.sh`, and starts
faster than a Python interpreter for something running every minute.

The card's Docker container field tracks only the status nginx — the game server
is a host unit, so its real state is the `status` field.

### Player count

The server publishes no query port, and its EOS session attributes (`key[pc]` and
friends) are written once when the session is created and never updated on join or
leave — so they cannot be used for a live count. The count instead comes from the
connection log for the current run:

```
AddClientConnection: Added client connection: ... RemoteAddr: <ip>:<port>
LogNet: Join succeeded: <name>
UNetDriver::RemoveClientConnection - Removed address <ip>:<port>
```

Add/Remove pairs are authoritative — `Remove` fires on a timeout as well as on a
clean quit, so a crashed client does not leave a phantom player behind.

`player_names` is best-effort: `Join succeeded` carries no address, so the name is
attributed to the connection added immediately before it. With two players joining
in the same instant the names could swap; `players` stays exact regardless, since
it is derived from addresses alone.

## Notes

- 64-bit only. Budget ~2 GB RAM plus ~1 GB per player; the cap is 6 players.
- Networking runs over Epic Online Services (`RedpointEOSNetDriver` in the log),
  so the server needs outbound HTTPS as well as inbound UDP 7777.
- A second server on the same host is not supported: beyond its own
  `SERVER_PORT` it would collide on the fixed beacon (8888) and LAN probe (45453)
  ports — see [Port](#port) — and these scripts assume a single
  `dragonwilds.service`.
- Steam app IDs: **4019830** dedicated server (Linux depot 3501791), **1374490**
  game client (Windows only).
- [Official setup guide](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)
  · [Wiki: Dedicated Servers](https://dragonwilds.runescape.wiki/w/Dedicated_Servers)
