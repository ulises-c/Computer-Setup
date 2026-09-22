# RuneScape: Dragonwilds dedicated server

Native Linux dedicated server (Steam app **4019830**), run by `dragonwilds.service`
and surfaced on the homepage dashboard through a loopback status endpoint.

Listens on **UDP 7777**, allowed from the LAN and the tailnet only — no public
exposure, no router port-forward.

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

Configure first:

```bash
cp .env.example .env    # set DRAGONWILDS_INSTALL_DIR and SERVICE_USER
```

Install the game with steamcmd (~1.7 GB download, ~5.5 GB on disk). Game data
stays outside this repo:

```bash
sudo apt install steamcmd            # if missing
/usr/games/steamcmd +force_install_dir ~/games/dragonwilds \
  +login anonymous +app_update 4019830 validate +quit
```

Then wire up the units, firewall rules, and status card:

```bash
sudo bash setup.sh --dry-run         # preview
sudo bash setup.sh
```

`setup.sh` reads `.env`; every value there can also be passed as an environment
variable.

## Configure the server

The server generates its config on first start:

```
<install dir>/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
```

Note that path is `LinuxServer`, not the `Linux` the official guide shows. See
[`DedicatedServer.ini.example`](DedicatedServer.ini.example) for the keys.

**`OwnerId` is mandatory** — it is your player ID from the in-game Settings menu.
Left empty, the server boots, logs

```
The [OwnerId] for this server is empty.
An OwnerId is required for normal Server operation.
```

and never creates a world. Set it along with `ServerName` and `DefaultWorldName`:

```bash
sudo systemctl stop dragonwilds.service
$EDITOR <install dir>/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
sudo systemctl start dragonwilds.service
```

Edit only while stopped — the server rewrites this file on shutdown and will
overwrite changes made underneath a running process.

## Operate

```bash
systemctl status dragonwilds.service
journalctl -u dragonwilds.service -f
sudo systemctl restart dragonwilds.service
```

The unit runs `steamcmd +app_update` as an `ExecStartPre` on every start, so a
restart picks up the current build. Its leading `-` means a Steam outage leaves
the server starting on whatever is already on disk rather than failing to boot.

Startup takes roughly 30 seconds of asset loading before the UDP socket opens.

Shutdown sends SIGTERM and waits up to 120 s: the server flushes its world to
`RSDragonwilds/Saved/Savegames/*.sav` on that signal, so cutting it short can
lose recent progress. On startup it loads the newest `.sav` it finds.

Saves are numbered slots (`1.sav`), not named after the world — `DefaultWorldName`
is recorded inside the file, not in its filename. So importing an existing world
means emptying `Savegames/` first: a world the server generated on an earlier
start carries the same name and can win the "newest" comparison.

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

`status` reports `starting` while the unit is active but has not yet bound UDP
7777, so the card does not claim the server is joinable during asset loading.

There is no player count — the server exposes no query port, and the log lines
for joins were not verifiable without a live player. Worth revisiting once
someone has connected.

## Notes

- 64-bit only. Budget ~2 GB RAM plus ~1 GB per player; the cap is 6 players.
- Networking runs over Epic Online Services (`RedpointEOSNetDriver` in the log),
  so the server needs outbound HTTPS as well as inbound UDP 7777.
- A second server on the same host would use 7778, a third 7779, and so on.
- [Official setup guide](https://dragonwilds.runescape.com/news/how-to-dedicated-servers)
