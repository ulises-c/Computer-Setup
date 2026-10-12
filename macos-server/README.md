# macos-server — the always-on Mac mini

The Mac mini (Apple M4, 16 GB) runs 24/7 beside the Linux servers. It is still
a desktop too; [INVENTORY.md](INVENTORY.md) records its current state ahead of a
planned wipe and reinstall as a dedicated server. Roles today:

- **CI worker**: the Forgejo Actions runner ([`forgejo-runner/`](forgejo-runner/README.md)).
- **Agent host**: Hermes gateway and WebUI.
- **Local inference**: `mlx_lm.server`, installed but off by default.
- **Fleet member**: its own cross-linked Homepage, native Glances, nightly
  restic backup to the main server, server power settings.

It follows [`server-base`](../server-base/README.md) where macOS allows and
departs from it where it does not:

| Base piece | Linux servers | Mac mini | Why |
| --- | --- | --- | --- |
| Containers | Docker Engine | OrbStack (no sudo) | Docker on macOS runs in a VM; OrbStack's host networking shares the Mac's `localhost` both ways, so the base Homepage service works unchanged |
| Glances | container | native, LaunchAgent | a container would report the VM, not the Mac |
| Cockpit | `/cockpit` | none | Linux only; macOS Screen Sharing covers remote admin |
| Backups | root systemd units | login-user LaunchAgent | the state worth keeping is the user's (`~/.hermes`, runner config) |
| Unit manager | systemd | launchd (`agents.sh`) | |

## URLs

One tailnet node, services under its name (issue #86):
`https://<mac-hostname>.<tailnet>.ts.net/…`

| Path / port | Service |
| --- | --- |
| `/` | Homepage |
| `/glances/` | Glances |
| `:9443` | Portainer (no reliable base path, portainer#12615) |
| `:8787` | Hermes WebUI (it owned `/` before Homepage and is not built for a sub-path) |

Local inference (`127.0.0.1:8080`) is deliberately not published.

## Bring-up

```sh
bash macos-server/setup.sh --dry-run
bash macos-server/setup.sh
```

`setup.sh` installs the host packages (`bash`, `jq`, `restic`, `glances`,
`mlx-lm`, OrbStack), writes `server-base/timezone.env`, creates the private
`.env` files (`scaffold.py`), installs the LaunchAgents (`agents.sh install`),
checks the compose files and the power settings, and publishes everything with
`serve.sh`. The first OrbStack launch needs its onboarding finished in the GUI
before `docker` exists. The shared tool set (zsh, tmux, …) comes from the root
`setup.sh --platform macos`.

Re-run `bash macos-server/serve.sh` after changing routes or compose files, and
`bash macos-server/agents.sh install` after changing an agent template.
`bash macos-server/agents.sh status` lists every repo-managed agent.

## LaunchAgents

| Label | What | Schedule |
| --- | --- | --- |
| `net.computer-setup.glances` | Glances on `127.0.0.1:61208` (`glances/glances.conf`, rendered with the tailnet name as an allowed host) | always, restarts on exit |
| `net.computer-setup.host-status` | `status/agents-status.sh` → `status/www/agents.json` | every 60 s |
| `net.computer-setup.mac-backup` | `backup/run.sh` | 03:00 |
| `net.computer-setup.mlx-server` | `mlx_lm.server` | never on its own |
| `net.forgejo.runner` | Forgejo runner ([its README](forgejo-runner/README.md)) | always |

Templates sit next to each service and are rendered with absolute paths into
`~/Library/LaunchAgents`; logs go to `~/Library/Logs/computer-setup/`. The
`host-status` nginx container serves `status/www/` (agent states and the backup
status JSON) on `127.0.0.1:8099` for the Homepage cards. Which agents the cards
show is `AGENTS` in `status/.env` (Hermes WebUI's label embeds a username, so
it lives there).

## Local inference

`mlx_lm.server` with `~/.models/mlx-community--Qwen3.5-9B-4bit` (about 5.6 GB
resident), OpenAI-compatible, loopback only. It keeps the model in memory while
it runs and has no idle unload, so the agent never starts on its own:

```sh
bash macos-server/inference/run.sh start    # loads the model, waits for /v1/models
bash macos-server/inference/run.sh status
bash macos-server/inference/run.sh stop
```

Pick another model or port in `inference/.env` (from `.env.example`), then
`agents.sh install`. Exposing it on the tailnet needs an explicit ACL first
(#94).

## Power

```sh
bash macos-server/power/power.sh --check   # no sudo; exit 1 on drift
sudo -v && bash macos-server/power/power.sh
```

Never sleep (`sleep 0`, `disksleep 0`, `standby 0`), restart after a power cut
(`autorestart 1`) and after a freeze, wake on LAN (`womp 1`); the display still
sleeps after 10 minutes. This replaces Caffeine. See "Known issues" in
[INVENTORY.md](INVENTORY.md): with FileVault on, a restart still waits at the
unlock screen.

## Backups

Same layout as the Pi and the game server: restic over SFTP to the main
server, primary on its 1 TB drive and a copy on the 14 TB drive, through a
chrooted `restic-mac` account. The shared engine (`backup/backup.sh`, a
symlink into `server-base/backup/`) runs as the login user from a LaunchAgent at
03:00; `backup/run.sh` calls its failure notifier, since launchd has no
`OnFailure`. Homebrew's bash runs it (the engine needs bash 4+).

What goes in (`backup/sources.sh`): the Homepage config, the runner config,
`~/Library/LaunchAgents`, `~/.ssh/config`, Hermes' configuration, credentials,
memories, skills and cron jobs, SQLite snapshots of Hermes' databases, every
service `.env`, and an install inventory (Brewfile, `launchctl list`, `pmset`,
`sw_vers`, model sizes). Left out: models, apps and the Hermes install, which
come back from their sources.

Provisioning (once):

```sh
bash macos-server/backup/connect.sh key                       # on the Mac: key + public half
sudo bash server-base/backup/sftp-target.sh mac /tmp/mac-backup.pub   # on the main server
bash macos-server/backup/connect.sh connect <main-lan-ip> <SHA256:fingerprint>
bash macos-server/agents.sh install                           # adds the backup agent
launchctl kickstart gui/$(id -u)/net.computer-setup.mac-backup   # first run now
```

`connect` pins the main server's ed25519 key, writes the `mac-backup-target`
alias to `~/.ssh/config`, creates `backup/.env` with a new restic password (save
it in the password manager) and initializes both repositories. Copy `NTFY_URL`
from another host's backup `.env` for alerts. Logs:
`~/Library/Logs/computer-setup/mac-backup.log`.

## Homepage

Generated like every host's (`server-base/homepage/generate.py` from
`server-base/fleet.json` plus `homepage/services.local.yaml` and
`settings.local.yaml`). Groups: **Servers** (the shared cross-links), **Mac
server** (Glances, Portainer, Watchtower, backups, LaunchAgents), **Mac
services** (Forgejo runner, Hermes WebUI and gateway, local inference) and
**Shared services**. The top bar has no temperatures: Glances cannot read Apple
silicon sensors without root.
