# Mac mini — pre-reinstall inventory

A snapshot of the always-on Mac mini as it runs today (October 2026), taken
before it is wiped and reinstalled as a dedicated server. It records what is
there, what the reinstall should keep, and what is broken now. The nightly
backup also stores a machine-readable copy (`inventory/` in each snapshot:
`Brewfile`, `launchctl list`, `pmset`, `sw_vers`, model sizes), so this file
only needs updating for decisions, not package churn.

## Hardware and OS

| | |
| --- | --- |
| Model | Mac mini (2024), `Mac16,10` |
| SoC | Apple M4: 10 CPU cores (4 performance + 6 efficiency), 10-core GPU, Metal 4 |
| Memory | 16 GB unified (about 11.4 GB in use with the current desktop workload) |
| Storage | 512 GB internal SSD (APFS); about 70 GB free (85% used) |
| OS | macOS 26.5 (Tahoe), Darwin 25.5 |
| Network | Ethernet `en0`, 1 GbE; Tailscale (standalone app, MagicDNS name `<mac-hostname>.<tailnet>.ts.net`) |
| Display | One external 1080p monitor (not needed once headless) |
| Security | FileVault on; no automatic login |

## Server role today

| Service | How it runs | Where | Notes |
| --- | --- | --- | --- |
| Forgejo Actions runner | LaunchAgent `net.forgejo.runner`, built from source | [`forgejo-runner/`](forgejo-runner/README.md) | `macos-latest:host` label, global scope, monitored from the main server |
| Hermes gateway | LaunchAgent `ai.hermes.gateway` | `~/.hermes` | Messaging gateway; running |
| Hermes WebUI | LaunchAgent (user-named label, see `status/.env`) | `~/.hermes/webui-launch.sh`, port 8787 | **Crash-looping**: "Python environment cannot import both WebUI dependencies and Hermes Agent". Binds `0.0.0.0` |
| Local inference | `mlx_lm.server` LaunchAgent `net.computer-setup.mlx-server`, off by default | [`inference/`](README.md#local-inference) | Models under `~/.models` (below) |
| Glances | LaunchAgent `net.computer-setup.glances` | [`glances/`](glances/) | Native, loopback; served at `/glances` |
| Homepage, Portainer, Watchtower, status nginx | OrbStack containers | [`homepage/`](homepage/) etc. | Published by `serve.sh` |
| Backups | LaunchAgent `net.computer-setup.mac-backup`, 03:00 | [`backup/`](README.md#backups) | restic → main server over SFTP |
| codeburn refresh | LaunchAgent `com.codeburn.refresh` | | Desktop tooling |
| Screen Sharing | macOS (ARD agent listening) | | Remote GUI access |

Other always-on helpers that are desktop, not server, workload: Caffeine (keeps
the Mac awake until `power/power.sh` is applied), Rectangle, Mac Mouse Fix,
Logi Options+, Google Drive, Amazon Photos, Bitwarden, Obsidian, Stats, Zoom,
Cisco Secure Client, EXO (`io.exo.networksetup` LaunchDaemon).

## Models (`~/.models`, about 62 GB)

| Model | Size | Format |
| --- | --- | --- |
| `mlx-community--Qwen3.5-9B-4bit` | 5.6 GB | MLX (inference default) |
| `mlx-community--GLM-4.7-Flash-5bit` | 2.2 GB | MLX |
| `mlx-community--Qwen3.6-27B-4bit` | 15 GB | MLX |
| `unsloth/Qwen3.6-27B-UD-MLX-4bit` | 24 GB | MLX |
| `mlx-community/` (hub cache) | 15 GB | MLX |

The 27B models do not fit beside the desktop workload in 16 GB; they are the
first candidates to delete if disk runs short.

## Packages

Homebrew leaves worth keeping on the server: `glances`, `restic`, `mlx-lm`,
`llama.cpp`, `bash`, `jq`, `go` (runner build), `gh`, `tmux`, `eza`, `fzf`,
`fd`, `bat`, `zoxide`, `micro`, `htop`, `mactop`, `fastfetch`, `uv`, `pyenv`,
`shellcheck`, `antidote`, `opencode`. Casks: `orbstack`, `tailscale`
(standalone), `ghostty`. Testing leftovers already listed for removal in
[`docs/TODO.md`](../docs/TODO.md): `forgejo`, `tea`, `python@3.12`, the zsh
plugin formulae.

`~/.local/bin`: `forgejo-runner` (built from source), the Hermes CLIs, `agy`,
`claude`, `codex`, and the `wake-*` Wake-on-LAN helpers.

## Power (before `power/power.sh`)

`sleep 1` (kept awake only by Caffeine), `disksleep 10`, `displaysleep 10`,
`autorestart 0`, `womp 1`, `standby 0`, `powernap 1`, `tcpkeepalive 1`.

## Known issues and decisions for the reinstall

- **Power loss leaves the Mac offline.** `autorestart` brings the Mac back on,
  but FileVault stops at the pre-boot unlock screen and every service here is a
  LaunchAgent that needs a logged-in user: no Tailscale, SSH, runner or
  dashboard until someone unlocks it at the keyboard. Decide at reinstall:
  FileVault off with automatic login for a dedicated server, or keep FileVault
  and accept manual unlock (check first whether this macOS release can unlock
  FileVault remotely). Planned restarts can use `sudo fdesetup authrestart`.
- **Hermes WebUI crash loop** (above): fix the Python environment
  (`HERMES_WEBUI_PYTHON`) separately; until then its card shows down and launchd
  restarts it every few seconds. It also binds `0.0.0.0`; `127.0.0.1` is enough
  behind `tailscale serve`.
- **Disk at 85%**: the models are most of it.
- **Desktop apps compete for 16 GB**, which is why local inference is off by
  default. A dedicated install frees about 6 GB for a resident model.
- No DNS replica: Docker on macOS cannot serve LAN port 53; a native AdGuard
  replica is a reinstall-time option.
