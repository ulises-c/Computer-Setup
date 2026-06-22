# Forgejo Actions runner (Mac mini)

The Mac mini (`m4-mini`) is a self-hosted [Forgejo Actions](https://forgejo.org/docs/next/user/actions/)
runner. It executes CI jobs **directly on the host** (label `macos-latest:host`,
no Docker) for repos on the home Forgejo server, reaching it over Tailscale.

```
┌──────────────────────┐        Tailscale         ┌──────────────────────────────┐
│  Mac mini (m4-mini)  │  ───────────────────────▶│  Forgejo server              │
│  forgejo-runner      │   http://forgejo          │  forgejo.<tailnet>.ts.net    │
│  (LaunchAgent)       │   .<tailnet>.ts.net:3000  │  :3000  (see linux-server/)  │
└──────────────────────┘                          └──────────────────────────────┘
```

The server side lives in [`../../linux-server/forgejo/`](../../linux-server/forgejo/).

## Files on the Mac mini

| Path | What |
| --- | --- |
| `~/.local/bin/forgejo-runner` | the runner binary (built from source — see below) |
| `~/forgejo-runner-config.yml` | config; the `server.connections` block holds the instance URL + token |
| `~/Library/LaunchAgents/net.forgejo.runner.plist` | LaunchAgent: `RunAtLoad` + `KeepAlive`, starts at login and restarts on crash |
| `~/Library/Logs/forgejo-runner.log` | combined stdout/stderr |

## Why there is no prebuilt binary

Forgejo publishes **Linux-only** runner binaries — there is no macOS build. So
on the Mac mini the runner is compiled from source with Go (hence the
`git describe` version string like `v12.10.2+20-g22ebc7d1`). `install.sh`
handles the build.

## Reproduce from scratch

```bash
# 1. Build, register, and load the LaunchAgent (prompts for a registration token).
bash install.sh

# 2. Confirm it's healthy.
bash verify.sh
```

`install.sh` will:
1. Build `forgejo-runner` from source (`brew install go` first if needed) and
   install it to `~/.local/bin/`.
2. Generate the base config (`generate-config`) if none exists.
3. Register the runner against the Forgejo instance — get a token from
   **Forgejo → Settings → Actions → Runners → Create new runner** (site, org, or
   repo scope).
4. Render `net.forgejo.runner.plist` from the template and `launchctl bootstrap`
   it so it runs at login.

Useful overrides:

```bash
RUNNER_VERSION=v12.12.0 bash install.sh
FORGEJO_INSTANCE_URL=http://forgejo.<tailnet>.ts.net:3000 bash install.sh
bash install.sh --skip-build        # reuse the existing binary
bash install.sh --skip-register     # leave server.connections untouched
```

Find your tailnet suffix with `tailscale status --json | jq -r '.MagicDNSSuffix'`.

## Day-to-day

```bash
bash run.sh status     # launchd state + last log lines
bash run.sh restart    # after editing the config
bash run.sh tail       # follow the log
bash run.sh stop|start
```

## Troubleshooting

**`connection refused` / `fail to invoke Declare` in the log — the most common
failure.** The runner host is fine; the configured instance URL no longer points
at where Forgejo listens. This is exactly what happened when the server moved
from `ollie-server:3300` to its own Tailscale node `forgejo.<tailnet>.ts.net:3000`
— the runner kept dialing the old `:3300` and `KeepAlive` restarted it in a loop.

1. `bash verify.sh` — the instance-reachable check pinpoints it.
2. Confirm where Forgejo actually answers:
   `curl -s http://forgejo.<tailnet>.ts.net:3000/api/v1/version`
   (must return JSON, not a "Host validation failed" error — the host in the URL
   has to match the server's `ROOT_URL`).
3. Fix the `url:` under `server.connections` in `~/forgejo-runner-config.yml`.
4. `bash run.sh restart`.

**Daemon not running (`LastExitStatus` non-zero, no PID).** Check the log; it
restarts every ~10s via `KeepAlive`, so the tail shows the live error.

**Reboot didn't bring it back.** It should (`RunAtLoad`). Verify Tailscale came
up (`tailscale status`) and the LaunchAgent is loaded (`bash run.sh status`).
