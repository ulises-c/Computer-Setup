# Historical llama-swap telemetry (server)

This is a new, small read-only dashboard, **not** a third-party project or part of llama-dash. It receives per-request metadata over SSH from an inference host and keeps a persistent SQLite history on the always-on server. Browsers use Tailscale Serve HTTPS; the app itself listens only on loopback. The sender and tests are in [`../../linux-desktop/llama-telemetry`](../../linux-desktop/llama-telemetry).

Charts: requests, output tokens per wall-clock second, per-request generation (TG) and prompt-processing (PP) speed, by model, over 1 day / 1 week / 30 days / 365 days. Unknown PP/TG rates are excluded and sample coverage is displayed. No prompts, responses, headers, session IDs, or API keys are copied.

## Deploy

From a checkout on the server, copy `store.py`, `ingest.py`, `server.py`, and `static/` to `~/apps/llama-telemetry/` (the runtime copy); install `llama-telemetry-server.service` as `~/.config/systemd/user/llama-telemetry-server.service`. The SSH receiver's script must remain at `~/apps/llama-telemetry/ingest.py` for the sender's configured remote path. **Upgrade this receiver before the desktop sender**: the sender requires the receiver's first-row fingerprint in its cursor reply. Keep the runtime directory owner-writable only. Set `TELEMETRY_ALLOWED_LOGIN` in `~/.config/llama-telemetry/server.env` (mode 0600) using [`server.env.example`](server.env.example) as a template. Obtain the intended login name from `tailscale status --json` rather than guessing it.

```sh
systemctl --user daemon-reload
systemctl --user enable --now llama-telemetry-server.service
# Check existing Serve config first; do not replace unrelated listeners.
tailscale serve status --json
```

Choose **one** Serve command after inspecting the existing configuration. If HTTPS 443 has no existing root handler:

```sh
tailscale serve --bg 17483
```

If the root is occupied, use a free supported HTTPS port rather than replacing it:

```sh
tailscale serve --bg --https=8443 17483
```

The first command publishes `https://<server>.<tailnet>.ts.net/`; the second publishes `https://<server>.<tailnet>.ts.net:8443/`. Confirm the selected port is free and permitted by your tailnet policy. **Do not enable Funnel.** Serve strips client-supplied identity headers and injects the verified Tailscale user's login. The app refuses the page and API without the configured login (403). It trusts local loopback processes, so never bind it to a LAN address; local callers can spoof that header. Tailnet access does not work from tagged devices lacking user identity headers.

The database is `~/.local/share/llama-telemetry/activity.sqlite` with a 0700 directory and 0600 file. Back it up using SQLite's online backup API (include WAL state); the dashboard has no deletion policy. A populated chart only begins after the inference host has enabled persistent llama-swap Activity and sent real requests. While the host is off, already-pushed data remains available. The remote receiver has no public write endpoint—ingestion is through authenticated SSH only.

## Verify

```sh
python3 -m unittest discover -s tests -v
node --check static/app.js
systemd-analyze verify llama-telemetry-server.service
systemctl --user is-active llama-telemetry-server.service
tailscale serve status --json
```

The local `/health` responds 200; `/` and `/api/series` respond 403 without a Serve identity header. An authorized tailnet browser should load the dashboard and its 1-year range. Check remote row count with `sqlite3 ~/.local/share/llama-telemetry/activity.sqlite 'select count(*) from activity'` after a real model request and a successful desktop timer run.
