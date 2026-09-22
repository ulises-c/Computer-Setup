# RuneScape: Dragonwilds dedicated server

Native Linux dedicated server (Steam app **4019830**), run by `dragonwilds.service`
and surfaced on the homepage dashboard through a loopback status endpoint.

Listens on **UDP 7777**, allowed from the LAN and the tailnet only — no public
exposure, no router port-forward.

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

### 10. "Running" does not mean joinable

Roughly 30 seconds of asset loading separate process start from the UDP socket
opening. The status card reports `starting` until the port is actually bound
rather than claiming the server is up.

---

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
It reads `.env`; every value there can also be passed as an environment variable.

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
`server_name`, `world`, `uptime_seconds`, `listening`, `owner_configured`,
`world_password`, `build`, `last_save`, `updated`.

The card's Docker container field tracks only the status nginx — the game server
is a host unit, so its real state is the `status` field.

There is no player count: the server exposes no query port, and the log lines for
joins were not verifiable without a live player. Worth revisiting once someone has
connected.

## Notes

- 64-bit only. Budget ~2 GB RAM plus ~1 GB per player; the cap is 6 players.
- Networking runs over Epic Online Services (`RedpointEOSNetDriver` in the log),
  so the server needs outbound HTTPS as well as inbound UDP 7777.
- A second server on the same host would use 7778, a third 7779, and so on.
- Steam app IDs: **4019830** dedicated server (Linux depot 3501791), **1374490**
  game client (Windows only).
- [Official setup guide](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)
  · [Wiki: Dedicated Servers](https://dragonwilds.runescape.wiki/w/Dedicated_Servers)
