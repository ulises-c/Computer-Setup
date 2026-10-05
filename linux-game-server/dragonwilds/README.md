# RuneScape: Dragonwilds dedicated server

Native Linux dedicated server (Steam app **4019830**), run by `dragonwilds.service`
and surfaced on the homepage dashboard through a loopback status endpoint.

Listens on **UDP 7777**, with ufw rules allowing it from the LAN and the tailnet
only — no public exposure, no router port-forward. This host runs ufw active with
default-deny incoming; `activate.sh` refuses to start the game otherwise.

Join by IP literal (`192.168.x.y:7777` or `100.x.y.z:7777`); the client does not
resolve hostnames — see pain point 10.

Bootstrap, migration and activation live in [the game-server guide](../README.md).
This file explains how the server behaves and where the official guide is wrong.

## Session snapshot — October 2, 2026

The server was configured as follows during the rename and Homepage work:

- Server display name: `Ollie-GS` (shortened to stay within the documented community
  name-length guidance).
- World name: `1` (`DefaultWorldName=1`, `SaveGames/1.sav`). A hand rename to
  `Main` (editing the save header and filename) failed: the game logged
  "Skipping save game (Main) as cannot be loaded in current version" and created
  an empty `Main` world instead, which ran from 2026-10-02 to 2026-10-03 until
  `1.sav` was restored. A byte-level header edit leaves the chunk lengths and
  offset tables stale; the only supported route is
  [Renaming a world offline](#renaming-a-world-offline). The empty world is archived
  in `Saved/SaveGames-archive/`.
- A world join password is configured in the private `DedicatedServer.ini`; it is
  shown as **Join pass** below **Join code** on the tailnet-only Homepage card. The
  password value is not stored in Git or this documentation.
- The card exposes `online_capacity` as `online/capacity`, plus the session join
  code. The code is minted per server session, appears after the server finishes
  loading, refreshes about once per minute, and is blank while the service is stopped.
- The status timer may remain active while the game is stopped; the game and
  auto-update jobs should remain stopped during maintenance.

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

To change the name stored inside a save, see
[Renaming a world offline](#renaming-a-world-offline).

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

### 14. Capacity is an Unreal launch override, not a normal INI setting

The current official dedicated-server guide documents a six-player limit, and the
live build logged:

```text
Maximum allowed player number by this build is 6.
```

There is no ordinary `MaxPlayers` key in the live `DedicatedServer.ini`. The
official server repository supports passing extra arguments to the launcher, and
community server templates use this Unreal override:

```text
-ini:Game:[/Script/Engine.GameSession]:MaxPlayers=10
```

This repo now exposes the same override as `MAX_PLAYERS` in the private `.env`,
with a committed example value of `6`. Both setup scripts render it into
`dragonwilds.service`, and the status producer reads the same value so Homepage
does not drift from the launch command. Changing it requires stopping the game,
editing `.env`, and rerunning the installer or otherwise reinstalling the rendered
unit; do not edit only the Homepage card.

The evidence is mixed: 10-player operation has community reports using the
override, while third-party hosting listings advertise 20-player plans. Neither
is an official guarantee, and this host has not completed a reproducible 7+ player
join test. Keep `MAX_PLAYERS=6` for normal operation; treat 10 or 20 as an
unsupported experiment requiring a fresh backup, a stopped-world change, log
verification, and real client joins.

References:

- [Jagex dedicated-server guide](https://runescapedragonwilds.help.jagex.com/hc/en-gb/articles/45365343055249-Dedicated-Servers-How-to-Guide)
- [Official dedicated-server repository](https://github.com/runescape/rsdw-dedicated)
- [Community `MaxPlayers` report](https://www.reddit.com/r/RSDragonwilds/comments/1iwxj0y/anyone_know_how_to_change_max_players_on_a/)

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

With ufw active the server must also accept the probe; see
[Server firewall](#server-firewall). It is not the Docker bridges: the probe
reply carries no address at all, just an ID and the client's echoed nonce, so
the bridges cannot leak into it.

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

### Server firewall

With ufw active and default-deny incoming (this host), the server
needs **two** LAN-scoped inbound UDP rules, not one:

| Port | Purpose | Without it |
| --- | --- | --- |
| `SERVER_PORT` (7777) | the game connection | nothing connects |
| 45453 | the browser's LAN discovery probe | the browser entry falls back to the EOS (WAN) address |

`setup.sh` adds both, from `LAN_CIDR` (auto-detected from the default route when
empty). A host installed before the 45453 rule existed needs it added once:

```bash
sudo ufw allow proto udp from <lan-cidr> to any port 45453 comment 'dragonwilds LAN discovery'
```

The probe is a broadcast, and ufw drops unmatched broadcasts **without
logging** them, so a missing rule leaves no `[UFW BLOCK]` line on the server.
Its symptom is on the client: the entry is listed (EOS lists it by `OwnerId`),
but joining it dials the WAN address. Typed Direct connect is unaffected, since
it only needs `SERVER_PORT`.

After adding the rule, **refresh the Worlds browser** on the client (or restart
the game). An entry fetched while the probe was being dropped keeps the EOS
address, and joining it still fails with "Connection Lost / Network connection
was interrupted" even though the server now answers. This was observed on a
Steam Deck during the migration: the stale entry failed, a refreshed one joined
within a second of the probe reply.

Server and client rules are independent; LAN browser joins need both sides
to pass the exchange. The server must accept the probe (above); a client with a
default-deny firewall must accept the reply (previous section). A Steam Deck or
console has no active firewall, so only the server side applies to it. UDP 8888
(the world-settings beacon) is not opened; whether any client feature needs it
is untested.

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

## Why the game server is not a container

Homepage and the status endpoint are Docker services; the game deliberately
is not. The server is a ~5.5 GB Unreal build that steamcmd installs and updates
in place, and it wants a UDP socket of its own. Containerising it would mean
either `network_mode: host` (a container that buys nothing) or a NAT hop in front
of a latency-sensitive UDP game port, plus a bind mount back to the host for the
game data anyway.

| Piece | Runs as | Why |
| --- | --- | --- |
| Game server | `dragonwilds.service` (native) | Direct UDP 7777, no NAT hop, steamcmd updates in place |
| Status endpoint | `dragonwilds-status` container (~5 MB nginx) | Loopback-only; gives homepage a card |

## Install

Do not follow a generic `setup.sh` install here. The bootstrap
bootstrap (`linux-game-server/setup.sh`) downloads the game through `install.sh` while the
maintenance guard blocks every start, and `activate.sh` renders the units, the
polkit rule and the ufw rules through `setup.sh` in this directory before it
deliberately starts the game. See [the game-server guide](../README.md).

On an existing world, `install.sh` resolves the install path from the rendered
`dragonwilds.service` and runs the root-owned pre-update backup gate before
SteamCMD. Do not replace it with a direct `steamcmd +app_update`; configure and
install the backup unit first.

To apply a template change later, enter maintenance, re-run
`sudo bash linux-game-server/dragonwilds/setup.sh`, check, then leave and start
the service explicitly. Paths interpolated into the unit templates are validated
against a conservative charset first, since the rendered units are installed as
root. `setup.sh` reads `.env` with `set -a`, as do the status, update-check and
auto-update scripts, so a key present in `.env` **overrides** the same variable
in the environment.

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

`SERVER_PORT` and 45453 are opened from `LAN_CIDR`; 8888 is not. Joining by
typed address works without the beacon, so it evidently is not needed to
connect. Both fixed ports are why a second server on this host is not just a
matter of a different `SERVER_PORT`.

## Operate

```bash
systemctl status dragonwilds.service
journalctl -u dragonwilds.service -f
sudo systemctl restart dragonwilds.service
```

The unit first starts `dragonwilds-pre-update-backup.service` as root. After the
old process has stopped and flushed its world, that gate waits for the configured
`game-backup.service` to finish. Only then does the unit run
`steamcmd +app_update` as an `ExecStartPre`, so every restart that can apply a
patch has a fresh off-host backup first. The Steam command's leading `-` means a
Steam outage leaves the server starting on whatever is already on disk rather than
failing to boot.

The backup gate is skipped on a fresh install until a `.sav` exists. Once a save
exists, a missing or malformed config, missing backup unit, failed backup, or
timeout fails the game start and blocks the update. The gate restarts the backup
unit rather than merely attaching to an already-running nightly job, so the copy
is taken after this game's shutdown. The backup service allows two hours; the
gate allows two and a half, and the game start job allows five hours because an
update has taken a little over two hours on an empty server.

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

## Renaming a world offline

The server keys a world by the name stored inside its save (pain point 4), so a
rename has to rewrite that name, not only the filename and config. A hand edit of
the header fails: the strings are length-prefixed, so growing one shifts chunk
lengths and offset tables behind it. `dragonwilds/spud_world_rename.py` rewrites
the name through the save's own schema, recomputes every dependent length and
offset, and writes a verified copy. It leaves its input untouched, refuses to write
into a `SaveGames` directory, and never starts or stops anything.

Jagex documents no supported way to rename a world. The tool makes the file
change exact and checkable; whether the game then accepts the renamed save is
proven only by the load log after a deliberate restart (see below).

### What the tool changes

A `.sav` is a tree of chunks (4-byte tag, `uint32` length, body):
`SAVE` holds `INFO`, `GLOB` and `LVLS`. The world name is stored three times and is
found by schema, not by searching for text:

| Where | Field |
| --- | --- |
| `INFO` > `CINF` (a property-name list, an offset table, then the data) | `WorldName` |
| `GLOB` > `GOBS` > `NOBJ` > `PROP` | `WorldSaveSettings/WorldName` and `WorldSaveSettings/WorldSlotName`, located through `META`'s class definition (storage type 30, string) and property-name index |

Renaming to a name that is `n` characters longer grows the file by `3n` bytes and
rewrites the lengths of `SAVE`, `INFO`, `CINF`, `GLOB`, `GOBS`, `NOBJ` and `PROP`,
the two data-size fields, and the offset of every property stored after a changed
string. The world GUID (stored as four `uint32` in `CINF` and as 16 bytes in
`PROP`), every other property, `META`, `GLAI` and the level data in `LVLS` are
copied byte for byte.

The tool refuses, and writes nothing, when:

- the save does not parse exactly (chunk lengths, offset tables, string encoding,
  class definitions, a single object defining the world identity);
- the three name fields do not all hold the `--from` name, the two GUID copies
  differ, or the old name's string also appears anywhere the schema did not select;
- the new name is not 1-32 characters of `A-Z a-z 0-9 _ -`, equals the old one, or
  the output already exists, sits in a `SaveGames` directory, or is the input.

### Use

Work on a copy taken while the game is stopped and maintenance is entered (see the
guide's maintenance section; the stopped-state backup includes `Config`,
`SaveGames` and `SpudCache`):

```bash
cd linux-game-server/dragonwilds
python3 spud_world_rename.py inspect ~/backups/1.sav
python3 spud_world_rename.py rename --input ~/backups/1.sav \
  --output ~/backups/<new name>.sav --from 1 --to <new name>
python3 spud_world_rename.py verify --original ~/backups/1.sav \
  --candidate ~/backups/<new name>.sav --from 1 --to <new name>
```

`rename` checks its own result before writing: the candidate parses, differs from
the original only in the three name fields, equals a fresh rename of the original,
and renaming it back reproduces the original byte for byte. It then writes the
file mode 600, without overwriting, and prints both SHA-256 hashes and the
unchanged world GUID. Keep saves, archives and candidates outside Git;
`tests/test_spud_world_rename.py` builds synthetic saves and contains no real
data. Set `DRAGONWILDS_PRIVATE_SAVE` to a private copy to run the same round-trip
and rename checks against it.

### Installing a candidate

Only after a stopped-state backup and an explicit decision to restart:

1. Enter maintenance and confirm it; keep the backup and its hash.
2. Copy the candidate to `SaveGames/<new name>.sav` (mode 600, same owner) and
   check its SHA-256 against the `rename` output.
3. Move `<old>.sav` and `<old>.sav.backup` out of `SaveGames/` into an archive
   directory. Community reports say the game deduplicates worlds by GUID, so
   leaving both can hide one.
4. Set `DefaultWorldName=<new name>` in `DedicatedServer.ini` (edit it while the
   server is stopped; it is rewritten on shutdown).
5. Leave maintenance, start the server and read the log: `LoadGameFromSaveGame`,
   `World load SUCCEEDED` with the same world GUID as before the change, the new
   name, and no `NewGame(`. Then join with a real client.

Rollback: stop the game, remove `<new name>.sav`, move the archived `<old>.sav`
files back (or extract `SaveGames` from the stopped-state backup), set
`DefaultWorldName=<old>`, and start. Leave `SpudCache` as it is unless the log
shows a cache problem; it is part of the backup.

## Backups

The nightly `game-backup.service` sends this host's encrypted restic snapshot to
the main server. `sudo bash linux-game-server/backup/setup.sh` installs a
root-owned executor bundle under `/usr/local/libexec/`; the systemd unit does not
execute the user-writable checkout as root. Re-run that setup after changing
`backup/.env`, `dragonwilds/.env`, or the backup source code; the install path is
captured into the root-owned unit. The status JSON is written under
`/var/lib/computer-setup-backup/game-backup/` and served read-only to Homepage.
The pre-update gate invokes the same service after the game has flushed and
stopped, so it protects both automatic and manual updates. The standalone helper
remains useful for an additional local copy:

```bash
python3 linux-game-server/dragonwilds/backup-save.py --output-dir ~/backups
```

A `.sav` has no online-snapshot equivalent to sqlite's `.backup`, so a live copy
is not application-consistent. Enter maintenance first for a guaranteed-clean
copy, and keep `Saved/Config` (which holds `OwnerId`) and this folder's `.env`
alongside it.

## Status card

`dragonwilds-status.timer` targets `dragonwilds-status.sh` every five seconds, writing
`status/dragonwilds-status.json` (gitignored). The nginx container serves it on
`127.0.0.1:8096`, and homepage — host-networked — reads it via a `customapi`
widget.

The private Homepage card also displays `join_password` below the join code. Keep
Homepage and port 8096 restricted to the tailnet; this field is intentionally
secret-bearing.

```bash
curl -s localhost:8096/dragonwilds-status.json | jq
bash dragonwilds-status.sh        # regenerate by hand
```

Fields: `status` (`running` / `starting` / `stopped` / `failed` / `unknown`),
`server_name`, `world`, `join_code`, `join_password`, `players`, `players_max`,
`online_capacity`,
`player_names`,
`connect_lan`, `connect_tailnet`, `memory_bytes`, `save_bytes`,
`install_bytes`, `installation_footprint`, `uptime_seconds`, `listening`, `owner_configured`,
`world_password`, `build`, `latest_build`, `update_status`, `update_checked`,
`last_save`, `updated`.

### Software/process and active-world cards

The primary **RuneScape: Dragonwilds** card reports the native game service,
not the nginx container. Compact rows group current / rolling-24h average / sampled
maximum CPU and memory, version with Steam build, tasks with automatic restarts,
world count with save names, and update health with automatic-update mode. All
underlying numeric and individual text fields remain in the status JSON.
**Uptime** uses days, hours, minutes and seconds (`uptime_display`), not
Homepage's rounded duration formatter. **Running version** comes from `LogNetVersion: Set
ProjectVersion` in the journal filtered by the current systemd `InvocationID`;
it is `unknown` when unavailable, stopped, or a restart races the refresh.
**Steam build** remains the installed manifest build ID, a separate value (not
proof that a running process loaded a subsequently modified installation).
Tasks/threads (`TasksCurrent`) and automatic service restarts (`NRestarts`) are
cheap service-specific counters; restarts do not count manual restarts or lifetime
crashes. **Installation on disk** is allocated bytes from `du -s -B1` over the
entire game installation, including `Saved`, not disk free space or download size.
An incomplete/failed size scan is unknown. World-save count and names are also
reported. Player counts, online names and last-join details belong only to the
**Active world** card, alongside save identity/size/time and join information.
The join password intentionally stays visible on this private dashboard.

The game host's `dragonwilds-status.sh` is deliberately a regular host-specific
file rather than its former shared symlink. The main server's producer and all
other files under the main-server tree remain unchanged.

### Rolling 24-hour resources

`status_metrics.py` retains the previous **86400 seconds** in at most **1441
one-minute buckets**, atomically persisted in `.metrics/history.json` beside the producer
(mode 0600 in a 0700 directory, gitignored and outside nginx's served directory).
The timer starts building real history immediately; pulling this change
does not create any past samples. A lower sample count/span on the card is
expected during warm-up or after missing/corrupt history. Invalid or oversized
history resets with a warning and a visible reset marker on that refresh.

- **CPU current** is the average since the preceding valid sample, as percent of
  one core (100% = one fully used core; values above 100% are valid).
- CPU deltas require matching boot and invocation IDs, nondecreasing CPU counters,
  forward monotonic/wall clocks that agree within 5 seconds, and a sampling gap
  no longer than 180 seconds. The first sample, restart, unavailable counter or
  larger gap is unknown, never zero. The next valid same-invocation sample warms
  it up again. Historical valid samples from prior invocations remain in-window.
- **CPU average** is weighted by observed interval duration, clipped at the 24h
  boundary (the partial boundary bucket assumes uniform CPU within that minute);
  **CPU maximum** is the highest sampled interval average, not an
  instantaneous peak. No downtime or missing intervals are imputed as zero.
- **Memory current** is systemd `MemoryCurrent` for the whole service cgroup,
  not just the wrapper PID. Average and maximum use available point samples,
  not interpolation or a lifetime peak. Unavailable/inactive gauges are null in
  the JSON and `unknown` on the card.
- **Sample coverage** shows the elapsed sample span, actual CPU interval hours
  observed out of the requested 24h, and memory sample count. Span is not coverage
  across gaps; memory point samples do not prove continuous memory observation.
- Buckets preserve CPU interval-duration totals and maximum, and memory sum,
  sample count and maximum. Five-second sampling retains an entire day rather
  than truncating it to four hours with the old 2880-point cap. Memory counts,
  maxima and sample span can include up to 59 seconds before the exact cutoff
  in the boundary bucket; this is minute-resolution retention, not a claim of
  exact sub-minute historical expiry. Existing schema-1 minute samples migrate
  without losing their valid measurements.

The endpoint retains numeric `cpu_percent`, `cpu_avg_percent`,
`cpu_max_percent`, `memory_bytes`, `memory_avg_bytes`, `memory_max_bytes`,
`cpu_coverage_seconds`, `history_span_seconds`, and `memory_samples` for consumers.
Homepage uses grouped text fields (`cpu_summary`, `memory_summary`,
`sample_window`) with explicit now / avg / max labels so unavailable values cannot be
formatted as misleading zeros. No metrics network calls or new privileged
exporters are needed. Timer/manual refreshes serialize with a private lock.

### Fast metrics, slower metadata and applying the cadence

The shell entrypoint loads the private `.env` and executes `fast_status.py`.
Every tick reads service counters and UDP socket readiness, samples resources,
and atomically publishes JSON. `du`, world/config/manifest inventory, backup and
update metadata, whole-invocation journal parsing, last join and online players
are cached for **60 seconds** in private `.metrics/metadata.json` (mode 0600).
A changed invocation or an expired cache forces a refresh; a failed slow refresh
fails the tick rather than claiming newly refreshed metadata. Thus players and
joining/save/update details can lag by about a minute even with fast metrics.
`metadata_age_seconds` exposes the actual age; a cold/expired-cache tick is slower.
No Steam/network query is added. The full producer is never scheduled at 1/5s
without this cache. Private locks serialize manual and timer runs.

Homepage polls both cards every **5000 ms**. The host-specific timer is now a
regular file, not a shared symlink, and targets `OnUnitActiveSec=5s` with
`AccuracySec=1s`. Timer scheduling and an occasional ~2s cache refresh mean this
is a five-second target, not a guaranteed real-time heartbeat. Pulling the code
updates the installed user-owned ExecStart, but **does not change an already
installed one-minute timer**. Install only this timer, without restarting the game:

```bash
cd ~/github/Computer-Setup
sudo install -m 644 linux-game-server/dragonwilds/dragonwilds-status.timer /etc/systemd/system/dragonwilds-status.timer
sudo systemctl daemon-reload
sudo systemctl restart dragonwilds-status.timer
sudo systemctl start dragonwilds-status.service
systemctl show dragonwilds-status.timer -p TimersMonotonic -p AccuracyUSec -p LastTriggerUSec
```

Verify successive endpoint `updated` timestamps/`uptime_seconds` over at least
three timer firings. On October 5, 2026, noninteractive sudo was unavailable:
the live installed timer was still configured for **60s** with **10s accuracy**
(observed endpoint gaps of **71s and 70s**), while three bounded manual fast runs
proved second-level uptime changed after five-second waits. Do not replace the
system timer with an unprivileged background loop as a workaround.

Regenerate via `python3 server-base/homepage/generate.py` and verify its
`--check` mode; do not hand-edit `homepage/config/services.yaml`. Only the game
host's generated output changes. Reload Homepage with `/api/revalidate`.

### Measured polling cost (October 5, 2026)

Three real runs on the live game host, without restarting the game:

| Producer path | Wall seconds/run | CPU seconds/run (children included) |
| --- | --- | --- |
| Original full producer | 2.044 / 2.069 / 2.075 | 2.213 / 2.239 / 2.243 |
| New cold metadata cache | 2.157 | 2.328 |
| New warm fast path | 0.090 / 0.091 / 0.092 | 0.087 / 0.089 / 0.090 |
| New warm path, synthetic full-day 1441-bucket history (544427 bytes) | 0.115 / 0.114 / 0.115 | 0.113 / 0.112 / 0.113 |

The full-day benchmark is explicitly synthetic history used for workload sizing,
not invented live historical observations. CPU accounting includes subprocess
CPU, but not systemd/journald daemon work or Homepage/browser overhead. Few warm
runs are not a sustained load test; journal cost can grow during a long session.
Estimated average utilization of **one logical core**, using measured mean fast
cost plus one incremental metadata refresh per minute:

| Target cadence | Original full scan every tick (unsafe model) | Split fast/60s metadata estimate |
| --- | --- | --- |
| 1s | 223.19% (wall time also exceeds interval) | 15.01% |
| 5s | 44.64% | 5.99% |
| 60s | 3.72% | 3.92% |

These are estimates, not measured sustained host percentages. **Recommend 5s**:
visible seconds and responsive metrics without paying the 1s interpreter/history
cost. Slower journal/disk refreshes can be split further if profiling later shows
this producer is material. No one-second mode is enabled.

### Player history

`dragonwilds-player-log.timer` runs a root-owned parser every minute. It reads
only new records from the Dragonwilds journal, at most 2000 per run
(`journalctl --lines=+N`, so systemd 255 or newer), and stores its private output
outside the checkout and outside the public status directory:

```text
/var/lib/dragonwilds/player-log/players.json  # one aggregate record per identity
/var/lib/dragonwilds/player-log/events.jsonl  # bounded join/leave audit history
/var/lib/dragonwilds/player-log/state.json    # journal cursor and correlation state
```

`players.json` keeps a stable player ID when the journal exposes one, otherwise
uses an explicit normalized-name fallback. It records names seen, first/last
seen, join count, and IP history as moderation evidence; IP is never used as
the primary identity. `events.jsonl` retains sanitized join/leave events for 90
days by default and never stores raw journal messages, passwords, or join codes.
The aggregate summary is retained independently of event expiry and is included
in the encrypted backup source list. Treat this directory as sensitive:
restrict access to root and the standard `adm` administrator group, and do not publish it through
nginx or Homepage.
The parser applies bounded journal, event, player, name, IP, and port limits. If
the durable cursor state is missing while an aggregate summary remains, it fails
closed rather than replaying the journal and risking duplicate joins; restore the
directory from backup before restarting the timer. The summary, event history,
cursor state, and transaction files are treated as one generation; a missing
event file or malformed nested summary also fails closed rather than silently
recreating history.

Restore player history only while the host is in maintenance. The backup/parser
lock is shared: the parser takes it exclusively, and restic takes it shared while
reading the source. A parser run that cannot get the lock within 20 seconds
skips and catches up from its journal cursor on the next tick. A backup with no
player-log directory on disk skips coordination; once the directory exists, a
missing or non-root `0600` lock fails the backup, which also blocks the
pre-update backup gate and therefore game starts. Restore only the player-log
path into a root-only staging directory, then copy while the exclusive lock is
held, preserving the live lock inode. Run from `linux-game-server/dragonwilds/`:

```bash
bash maintenance.sh enter
restore="$(sudo mktemp -d /root/player-log-restore.XXXXXX)"
sudo bash -c 'set -a; source ../backup/.env; set +a
  restic restore latest --host "$(hostname)" \
    --include /var/lib/dragonwilds/player-log --target "$1"' bash "$restore"
sudo flock -x /var/lib/dragonwilds/player-log/.backup.lock \
  rsync -a --delete --numeric-ids --exclude=.backup.lock \
  "$restore/var/lib/dragonwilds/player-log/" /var/lib/dragonwilds/player-log/
sudo rm -rf "$restore"
sudo chown -R root:adm /var/lib/dragonwilds/player-log
sudo chmod 2750 /var/lib/dragonwilds/player-log
sudo chmod 640 /var/lib/dragonwilds/player-log/events.jsonl /var/lib/dragonwilds/player-log/players.json
sudo chmod 600 /var/lib/dragonwilds/player-log/state.json /var/lib/dragonwilds/player-log/.backup.lock
bash maintenance.sh check
bash maintenance.sh leave
sudo systemctl start dragonwilds.service dragonwilds-auto-update.timer \
  dragonwilds-update-check.timer dragonwilds-player-log.timer
```

`maintenance.sh leave` starts nothing, hence the explicit start. History from
before a host move lives under the old host's snapshots; pass that hostname to
`--host`. A host that was already in maintenance before pulling the player-log
units must run `maintenance.sh enter` again so those units get their guards.

Do not restore directly over the live directory, replace `.backup.lock`, or
restart the player-log timer until `maintenance.sh check` succeeds.

Useful checks:

```bash
sudo systemctl status dragonwilds-player-log.timer
sudo journalctl -u dragonwilds-player-log.service
sudo jq . /var/lib/dragonwilds/player-log/players.json
sudo tail -n 20 /var/lib/dragonwilds/player-log/events.jsonl
```

A failed parser run triggers `dragonwilds-player-log-failure.service`, which
sends one high-priority ntfy alert with the last `error:` line to the
`NTFY_URL`/`NTFY_TOPIC` in `dragonwilds/.env`, then stays quiet for 6 hours
while the failure continues (`status/.player-log-alerted`). Runs skipped for a
backup exit 0 and never alert.

### Update checking

`dragonwilds-update-check.timer` runs every 15 minutes, asking Steam
for the current public build and writing it to `status/.latest-build`. The status
script compares that against the installed build from the app manifest and
publishes `update_status` (`up to date` / `update available (<build>)` /
`unknown`). The query takes about 4 seconds.

It is a separate timer because it is the only part of this that touches the
network — fast status ticks remain local and metadata refreshes every minute. The check
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
unit's `TimeoutStartSec=5h` leaves room for the backup and the long download inside the start job.

Set `AUTO_UPDATE_RESTART=false` in `.env` to be notified but apply updates
yourself. The manual restart still passes through the pre-update backup gate:

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
the card. jq is already installed by the bootstrap; this JSON construction belongs to the
cached slow path, not each fast tick.

Neither game card keys health off the status nginx container — the game server
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

---

Gist: https://gist.github.com/ulises-c/add4c146891d551a43dcf69e51b95ead

Repo: https://github.com/ulises-c/Computer-Setup/tree/main/linux-game-server/dragonwilds
