# Dragonwilds — quick start

Copy-paste path. Full detail and the reasoning behind each step:
[README.md](README.md).

## 1. Get your player ID

In game: **Settings → Player ID**. It is a **32-character hex string** like
`4f8976fb2ed8447d98f32a86d33e69af`.

It is *not* your SteamID. A 17-digit number (`76561198…`) is the wrong ID.

## 2. Install

```bash
sudo apt install steamcmd

/usr/games/steamcmd +force_install_dir ~/games/dragonwilds \
  +login anonymous +app_update 4019830 validate +quit

cd ~/github/Computer-Setup/linux-server/dragonwilds
cp .env.example .env          # set DRAGONWILDS_INSTALL_DIR and SERVICE_USER
sudo bash setup.sh
```

~1.7 GB download, ~5.5 GB on disk. `setup.sh` installs the systemd units, opens
UDP 7777 to the LAN and tailnet, and starts the status card.

## 3. Configure

```bash
sudo systemctl stop dragonwilds
nano ~/games/dragonwilds/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
```

```ini
OwnerId=<your 32-char player ID>     ; required — no world is created without it
ServerName=<name in the server browser>
DefaultWorldName=<world name>
WorldPassword=                        ; empty = open
```

Edit **only while stopped** — the server rewrites this file on shutdown.

```bash
sudo systemctl start dragonwilds
journalctl -u dragonwilds -f
```

Wait ~30 s for asset loading before UDP 7777 opens.

## 4. Import an existing singleplayer world (optional)

On your PC, find the save (the client is Windows-only, so under Linux it lives in
the Proton prefix):

```bash
find ~/.local/share/Steam ~/.var/app/com.valvesoftware.Steam \
  -path '*RSDragonwilds/Saved/SaveGames*' -name '*.sav' 2>/dev/null
```

Read the **world name stored inside it** — this is the step everything hinges on:

```bash
cd ~/github/Computer-Setup/linux-server/dragonwilds
./read-save-info.sh <save>.sav
```

```
world name : 1
map        : L_World
owner      : <owner>

set DefaultWorldName=1 and name the file 1.sav
```

The world name is usually a slot number. Don't use `strings` for this — a
one-character name never shows up, and the owner name looks like the world name.

Copy it across and point the config at it:

```bash
sudo systemctl stop dragonwilds
scp <save>.sav <server>:~/games/dragonwilds/RSDragonwilds/Saved/SaveGames/1.sav
```

```ini
DefaultWorldName=1      ; must equal the name INSIDE the save
```

```bash
sudo systemctl start dragonwilds
journalctl -u dragonwilds | grep LoadGameFromSaveGame
```

Success looks like:

```
LoadGameFromSaveGame() : Starting world load (Slot[1] WorldName[1] ... SaveTime[...])
```

If you see `NewGame()` instead, the name did not match and a fresh world was
created over the top. Stop, fix `DefaultWorldName`, restart.

## Everyday commands

```bash
systemctl status dragonwilds
journalctl -u dragonwilds -f
sudo systemctl restart dragonwilds          # also pulls the latest build
curl -s localhost:8096/dragonwilds-status.json | jq
```

## Connect

Easiest: share the **invite code** (`XXXX-XXXX`), shown on the homepage card or:

```bash
curl -s localhost:8096/dragonwilds-status.json | jq -r .join_code
```

It changes when the service restarts. Console players can only join this way.

Otherwise direct connect to an **IP literal**. The client does not resolve hostnames, so a
MagicDNS name is rejected even though it resolves fine at the OS level.

- LAN: `192.168.x.y:7777`
- Tailnet: `100.x.y.z:7777` — get it with `tailscale ip -4` on the server

Not `<server>.<tailnet>.ts.net:7777`.

The tailnet address works from outside your network too, unchanged. For friends
to join, share this machine from the Tailscale admin console (Machines → host →
Share) rather than inviting them to the whole tailnet.

No public access without a router port-forward — see the README.

## If something is wrong

| Symptom | Cause |
| --- | --- |
| No world, log says `OwnerId ... is empty` | `OwnerId` not set |
| Imported save ignored, `NewGame()` in log | `DefaultWorldName` ≠ name inside the save |
| Save copied but never read | Wrong folder — it is `SaveGames`, capital G |
| Service dead after `start`, exit status 0 | Port 7777 already held; kill the stray process |
| Card says `starting` | Normal for ~30 s while assets load |
