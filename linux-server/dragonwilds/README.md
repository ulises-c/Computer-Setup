# RuneScape: Dragonwilds dedicated server

Native Linux dedicated server (Steam app **4019830**), run by `dragonwilds.service`
and surfaced on the homepage dashboard through a loopback status endpoint.

Listens on **UDP 7777**, allowed from the LAN and the tailnet only — no public
exposure, no router port-forward. Join by IP literal (`192.168.x.y:7777` or
`100.x.y.z:7777`); the client does not resolve hostnames — see pain point 10.

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

### 11. LAN auto-discovery advertises the wrong address on a multi-homed host

The server answers LAN discovery probes, so it shows up in the browser by name —
but joining that entry fails with "Connection Lost / Network connection was
interrupted", while typing the address by hand works. The log shows probe replies
going out and **no** matching `NotifyAcceptedConnection`, so the client never
reaches the server at all: it is dialling an address that is not the one you can
reach it on.

This box carries 23 IPv4 addresses, 21 of them Docker bridges. Unreal's discovery
embeds a local address it selects itself, and on a multi-homed host that is
frequently a bridge (`172.17.0.1` and friends) rather than the LAN address. Not
proven here — the probe payload is not logged and capturing it needs root — but it
matches the symptom exactly, and the host is about as multi-homed as they come.

`-MULTIHOME=<ip>` would pin the address (the build does support it — the option
string is there, in UTF-16, which an ASCII `strings` scan misses). It is the wrong
trade here: it binds the socket to that one address, so pinning the LAN IP drops
tailnet access and vice versa. Direct connect works on LAN, tailnet, and remote
with no such compromise, so that is the recommendation.

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

`setup.sh` renders the units from templates, enables the service and the status
timer, opens UDP 7777 to the LAN and tailnet, and brings up the status container.
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

It runs as root because it calls `systemctl`, which is exactly why it never
invokes steamcmd — the network work stays unprivileged in
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
- A second server on the same host would use 7778, a third 7779, and so on.
- Steam app IDs: **4019830** dedicated server (Linux depot 3501791), **1374490**
  game client (Windows only).
- [Official setup guide](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)
  · [Wiki: Dedicated Servers](https://dragonwilds.runescape.wiki/w/Dedicated_Servers)
