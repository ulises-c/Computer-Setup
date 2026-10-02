# Ubuntu game server

A focused Ubuntu Server x86_64 deployment: the shared shell/dotfiles base
(zsh, tmux, fastfetch on SSH login), Docker, host Tailscale, Homepage, Glances,
Portainer, Watchtower, Cockpit, and the native RuneScape:
Dragonwilds server.
The initial target is Ubuntu Server 26.04 LTS.

This is a separate service deployment entrypoint, not a fifth packages.json
platform. Package selection and dotfile deployment reuse `lib/core.sh`; Docker
address-pool setup and Antidote pre-cloning reuse `platforms/server.sh`.

Files that are 1:1 with the NAS host are symlinks into `../linux-server`: the
Dragonwilds unit templates, timers, status/update/player scripts,
`read-save-info.sh`, the status container, and `docker/daemon.json`. A fix to one
of those applies to both hosts, so change them only when the change is right for
the NAS host too. Anything that differs on this host is a real file here instead
of an edit under `linux-server/`: `dragonwilds/setup.sh` (it also opens the LAN
discovery port), the Dragonwilds guide, and the maintenance, activation, install
and backup helpers. `tests/test_isolation.py` checks that every symlink resolves
into `linux-server/` and that no game-specific file references it.

It does not install the NAS server's DNS resolver, storage services, NUT, reverse
proxy, or entire container fleet. Do not run the root `setup.sh --profile server`
on this host: that starts the existing home-server service set.

## Bootstrap

Run as your normal SSH/login user, not as root. It requests sudo when needed.

```sh
bash linux-game-server/setup.sh --dry-run
bash linux-game-server/setup.sh
```

The shared manifest's high-priority apt base and medium-priority `terminal`
packages are installed. Deployment prerequisites come from Ubuntu's archive;
no old Ubuntu PPA or unsupported Docker convenience-script distro fallback is
needed. SteamCMD comes from Valve's official distribution because a fresh
26.04 installation need not have the `steamcmd` multiverse/i386 package enabled.
SteamCMD and the game run as the login user, never as root. The script downloads
and validates app 4019830 but deliberately does not start it or create a world.
Bootstrap first enters persistent maintenance on a fresh/stopped host. A rerun
fails before provisioning if the game is active, activating or deactivating;
it never implicitly stops a running game. For an intentional update, explicitly
run `bash linux-game-server/dragonwilds/maintenance.sh enter` first. Validation
requires the guard and stopped game/update jobs, holds the maintenance lock for
the whole operation, and rechecks after acquiring the SteamCMD lock. It leaves
the guard in place, including on failure.

`linux-game-server/dragonwilds/.env` is the deployment edit point. `MAX_PLAYERS=6`
is rendered into the native systemd unit and reused by the Homepage status
producer; leave it at 6 for the supported configuration. The dedicated-server
README records the evidence and the procedure for any deliberate higher-capacity
experiment.

Authenticate the host's own Tailscale node:

```sh
sudo tailscale up --operator="$USER"
bash linux-game-server/serve.sh
```

Complete the login URL Tailscale prints. Serve may ask to enable HTTPS in the
admin console. `serve.sh` starts every container and publishes each web UI with
`tailscale serve --bg` (tailnet only, never Funnel), following the one-node-per-
host layout from [#86](https://github.com/ulises-c/Computer-Setup/issues/86):
this host is a single tailnet node and services live under its name, so it claims
no `homepage`, `glances` or similar name that the NAS host already owns.

| Service | Listens on | Tailnet URL (`https://<game-host>.<tailnet>.ts.net…`) |
| --- | --- | --- |
| Homepage | `127.0.0.1:3000` | `/` |
| Glances | `127.0.0.1:61208` | `/glances/` |
| Cockpit (host service) | `127.0.0.1:9090` | `/cockpit/` |
| Portainer | `127.0.0.1:9000` | `:9443` (fallback) |
| Watchtower | no listener | updates images daily at 03:00 |

`serve --set-path` strips the mount path before proxying. Glances' web UI uses
relative URLs, so it works stripped (keep the trailing `/` in links). Cockpit
needs its prefix, so `serve.sh` sets `UrlRoot = /cockpit` and proxies to a target
ending in `/cockpit`, which re-adds it. Portainer uses #86's documented
fallback, a dedicated HTTPS port on the same name, because its `--base-url`
misses some assets
([portainer#12615](https://github.com/portainer/portainer/issues/12615)).

There is no Uptime Kuma here. It has no base-path support
([uptime-kuma#147](https://github.com/louislam/uptime-kuma/issues/147)), and a
monitor on the host it watches cannot report that host down, so the NAS host's
instance monitors this server.

Everything binds loopback because Docker-published ports bypass ufw. Cockpit is
installed without recommends (its recommends pull NetworkManager onto a
networkd host); `serve.sh` moves its socket to loopback with a drop-in and
writes `UrlRoot` and the tailnet origin to `/etc/cockpit/cockpit.conf`. `scaffold.py`
writes this host's tailnet name to `homepage/.env` and `glances/.env`; the
Servers and Shared services cards need the other hosts' domains added to
`homepage/.env` by hand (see `homepage/.env.example`).

The Homepage **Shared services** group links to single-instance services on the
NAS host (its Uptime Kuma, ntfy, Forgejo, AdGuard, Immich, Syncthing).
For a local fallback, use `ssh -L 3000:127.0.0.1:3000 <game-server>` and visit
`http://localhost:3000`. Host checks remain enabled.
Homepage mounts the Docker socket read-only for container status badges; a
read-only mount still grants full Docker API access, so keep Homepage
tailnet-only. The native game's real state comes from the status JSON, not from
whether the small nginx status container is running.

## Migrate a running Dragonwilds world

Do not copy an actively written `.sav` or run both hosts against the same world.
Perform the cutover while nobody is playing. Preserve a rollback copy before
starting the destination.

1. Prepare the destination with the bootstrap above, and authenticate Tailscale.
2. Deploy this standalone `maintenance.sh` helper on the source as well (it can
   run without the new bootstrap or any shared-template changes). On the source,
   explicitly enter maintenance. Keep the source install and all saves.

   ```sh
   bash linux-game-server/dragonwilds/maintenance.sh enter
   bash linux-game-server/dragonwilds/maintenance.sh check
   ss -uln
   ```

   The helper creates a root-owned `/var/lib/dragonwilds-maintenance/blocked`
   marker and persistent `ConditionPathExists=!` systemd drop-ins for the game,
   both update timers and both update services, then reloads systemd. Only after
   starts are blocked does it stop timers, their in-flight services, and finally
   the game (allowing SIGTERM to flush saves). It verifies inactive/failed states,
   zero game/update process IDs, protected files and the loaded conditions. A
   reboot cannot bypass the guard. Stopping timers alone does not stop running
   update services; those can request a game restart through the existing polkit
   grant. Runtime masks are not used, and the existing `/etc` service file is
   never renamed or deleted. Do not proceed if `enter` or `check` fails; the guard
   remains for investigation. Confirm no manually launched game process remains.

3. Recheck maintenance on both hosts before copying. With the source confirmed
   quiescent, securely copy its `RSDragonwilds/Saved/Config`
   and `RSDragonwilds/Saved/SaveGames` to the corresponding destination directory
   under `~/games/dragonwilds/RSDragonwilds/Saved/`. Preserve the config containing
   `OwnerId`, `DefaultWorldName`, server identity and any password. These remain
   outside the public repository. Never print or commit them. Compare SHA-256
   hashes of every transferred file on both hosts.
4. Validate that `DefaultWorldName` equals both the name inside the `.sav` and
   its filename. `dragonwilds/read-save-info.sh` inspects the header. A
   mismatch silently creates a fresh world and risks overwriting the import.
5. Keep an additional stopped-world archive outside both Git checkouts. Restrict
   copied config and archive permissions to the login user.
6. Set the source hostname and paths in no tracked file. The destination's
   `dragonwilds/.env` is generated with local paths and is ignored. Automatic
   restarts default off until migration and a backup/restore path are verified.
7. Before any destination startup, preserve the actual SSH listener and enable
   UFW with default deny incoming. Check other needed listeners before enabling
   it; for a fresh host whose actual SSH port is 22:

   ```sh
   sudo ufw allow 22/tcp
   sudo ufw default deny incoming
   sudo ufw enable
   sudo ufw status verbose
   ```

   Substitute your actual port, not necessarily 22. Firewall rules saved while
   UFW is inactive are not protection. Do not release either maintenance guard
   to enable UFW. Activation opens the game port and LAN-only UDP 45453 (browser
   discovery); without the latter, LAN clients cannot resolve the browser entry.

8. Only after the stopped-world copy, hash checks and rollback archive are ready,
   activate the destination as the login/game user:

   ```sh
   bash linux-game-server/dragonwilds/maintenance.sh check
   SSH_PORT=22 bash linux-game-server/dragonwilds/activate.sh
   ```

   Set `SSH_PORT` to the actual listener; an SSH session can supply it through
   `SSH_CONNECTION` instead. Activation requires confirmed maintenance, validates
   nonempty OwnerId/server identity and a matching config/world filename/save
   header, requires active UFW with default deny/reject incoming, and installs
   and confirms an SSH-preserving rule. It then installs the Dragonwilds units
   **while guarded**: their `enable --now` cannot start the game or update jobs.
   It rechecks the guard, world and firewall before deliberately removing the
   marker and explicitly starting the game, then the update timers. Startup
   failure re-enters maintenance. Do not bypass this wrapper by running
   `dragonwilds/setup.sh` unguarded. Keep the source guarded throughout cutover.

   `dragonwilds/setup.sh` allows the game's configured UDP port and UDP 45453
   from the LAN, and the game port on `tailscale0`. No public router port-forward is configured. Tailscale ACLs
   remain the access policy for tailnet clients. UDP 8888 is the game's beacon;
   it is not opened by default. Do not assume browser entries or join codes
   work remotely: see [the Dragonwilds guide](dragonwilds/README.md#network-connectivity).

9. Confirm world loading, not just an active process:

   ```sh
   systemctl status dragonwilds.service
   journalctl -u dragonwilds.service --since '5 minutes ago'
   bash linux-game-server/dragonwilds/dragonwilds-status.sh
   curl -fsS http://127.0.0.1:8096/dragonwilds-status.json
   ```

   Expect `LoadGameFromSaveGame()`, no unexpected `NewGame()`, and UDP 7777.
   Join via the LAN or Tailscale IP literal shown on Homepage. An actual player
   connection is a separate acceptance check, not proven by a socket being open.

## Joining on the LAN

Unlike the NAS host, this host runs ufw with default-deny incoming, so LAN
joins depend on its rules. `activate.sh` (through `dragonwilds/setup.sh`)
allows, from `LAN_CIDR` only, UDP `SERVER_PORT` and UDP 45453, plus
`SERVER_PORT` on `tailscale0`.

| Route | Works on LAN | Requires |
| --- | --- | --- |
| Direct connect `<server-lan-ip>:7777` | ✅ | server UDP 7777 rule |
| Browser entry (Worlds → search `ServerName`) | ✅ | server UDP 45453 rule, and a client that accepts the probe reply |
| Join code | ❌ | resolves to the WAN address; the router has no NAT loopback |

- **Use an IP literal** for Direct connect: the LAN address, or the tailnet
  `100.x` address from a Tailscale client. The Homepage card shows both. They
  change with a migration; players must use the new host's addresses.
- **Browser entry not resolving:** check the server rule first, since ufw drops
  the broadcast probe without logging it:

  ```sh
  sudo ufw status verbose | grep -E '7777|45453'
  ```

  A host activated before the 45453 rule was added to the installer needs it
  once:

  ```sh
  sudo ufw allow proto udp from <lan-cidr> to any port 45453 comment 'dragonwilds LAN discovery'
  ```

  Then **refresh the Worlds browser** on the client. An entry loaded before the
  rule existed keeps the WAN address and still fails with "Connection Lost /
  Network connection was interrupted"; a refreshed entry joins within a second
  of the probe reply. A Linux desktop with ufw also needs the reply rule in the
  [Dragonwilds guide](dragonwilds/README.md#the-same-browser-entry-resolves-differently-per-client).
  A Steam Deck has no active firewall, so it needs only the server rule.
- **Join codes** change on every restart and do not work on this LAN; see the
  [Dragonwilds guide](dragonwilds/README.md#network-connectivity). Consoles, which cannot type an IP, therefore need the browser
  entry.

## Rollback and backups

The helper scripts are tracked here and may be copied to an older source host
without running this machine's bootstrap:

- `dragonwilds/maintenance.sh` — block starts and quiesce game/update units;
  check the guard, or explicitly release it without starting anything.
- `dragonwilds/activate.sh` — validate the imported world and firewall before
  releasing destination maintenance and starting the game.
- `dragonwilds/backup-save.py` — copy the configured world to `~/Downloads`
  with a timestamp, mode 600, save-header checks and a SHA-256 sidecar.

```sh
python3 linux-game-server/dragonwilds/backup-save.py
python3 linux-game-server/dragonwilds/backup-save.py \
  --install-dir "$HOME/games/dragonwilds" --output-dir "$HOME/Downloads"
```

The backup helper never stops or modifies the game. It retries if the source
changes and verifies the written copy, but those checks do not prove a live
save is application-consistent. For a migration snapshot, enter and verify
maintenance first and preserve `Saved/Config` as well. Restore a copied save
under its original world name, not under the timestamped backup filename;
`DefaultWorldName`, the filename and the name inside the save must agree.

Enter and check maintenance on the destination first, quiescing in-flight update
services as well as timers and the game. Keep both hosts guarded while restoring.
If the destination has never accepted players, retain the source's original
stopped world. If players made progress, securely copy the destination's final
flushed saves/config back with hash and world-name verification before releasing
the source guard; otherwise rollback loses progress. Preserve a separate archive.
Verify the source firewall/SSH access and original units before restarting it.

```sh
# Destination first:
bash linux-game-server/dragonwilds/maintenance.sh enter
bash linux-game-server/dragonwilds/maintenance.sh check
# Source only, after restoration/checks:
bash linux-game-server/dragonwilds/maintenance.sh leave
sudo systemctl start dragonwilds.service
sudo systemctl start dragonwilds-auto-update.timer dragonwilds-update-check.timer
```

`leave` waits for any validation holding the maintenance lock, confirms quiescence
and removes only the marker. It starts nothing, removes no unit and does not
change existing enablement; future boots follow that enablement once the guard
is released. Never leave maintenance on the non-selected host. The persistent
drop-ins remain inert without the marker and are reused next time. Never run
both hosts at once. The helper controls these systemd units, not manually started
game/SteamCMD processes, and does not prevent an administrator removing the guard.

The NAS host's backup job does not cover this machine. Keep automatic game restarts off and arrange an off-host backup of
`Saved/Config`, `Saved/SaveGames`, and the private deployment `.env`. Test a
restore before treating this host as covered. The stopped migration archive is
a rollback point, not recurring backup coverage.

## Scope left for later

- Scheduled off-host backups and a restore test.
- A dedicated game-only Unix account (the game runs as the login user; a
  compromised game can access that user's files).
- Full integration with root setup/verify profiles if another game platform
  justifies changing the shared platform schema.

See [the Dragonwilds guide](dragonwilds/README.md) for native-server
operation, world import pitfalls, updates, and networking limitations. Do not
edit installed units by hand: edit the templates in `dragonwilds/`, then enter
maintenance and re-run `sudo bash linux-game-server/dragonwilds/setup.sh`.
