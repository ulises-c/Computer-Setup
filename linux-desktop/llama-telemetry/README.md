# Historical llama-swap telemetry (inference desktop)

The source of truth is llama-swap's Activity SQLite database. `push.py` sends only selected numeric request metrics and model names to the always-on server over the existing SSH connection once a minute. The server and shared schema live in [`../../linux-server/llama-telemetry`](../../linux-server/llama-telemetry). The supplied systemd unit expects the whole checkout at `~/github/Computer-Setup`; adjust its `WorkingDirectory` and `ExecStart` if you place the checkout elsewhere. Clients continue to use llama-swap directly—llama-dash is not in the inference path.

## Enable source storage

In llama-swap's `config.yaml` add `store.path` pointing to a private absolute path, for example `/home/<username>/.local/share/llama-swap/activity.sqlite`, and create its parent at mode 0700. In the hardened `llama-swap.service`, add that parent to `ReadWritePaths=` when `ProtectHome=read-only` or `ProtectSystem=strict` is set; use `UMask=0077` so the SQLite file and WAL stay private. Run `llama-swap -config <config-path> -validate` in the same environment as the service (which supplies its API key). Restarting llama-swap activates the store but interrupts inference and clears old in-memory Activity. Validate a real request after restart; rates require the upstream to supply response timings.

## Install sender

Install [`llama-telemetry-push.service`](llama-telemetry-push.service) and [`llama-telemetry-push.timer`](llama-telemetry-push.timer) in `~/.config/systemd/user/`. Set `TELEMETRY_SSH_HOST` to your configured server SSH alias in `~/.config/llama-telemetry/push.env` (mode 0600); use [`push.env.example`](push.env.example) as a template. BatchMode and strict host-key checking require a preconfigured non-interactive key for the alias. The receiver lives at `~/apps/llama-telemetry/ingest.py` on that server, as documented in the server README.

```sh
systemctl --user daemon-reload
systemctl --user enable --now llama-telemetry-push.timer
systemctl --user start llama-telemetry-push.service
systemctl --user status llama-telemetry-push.service
```

The unit skips cleanly until the source database exists. A failed SSH transfer leaves the source untouched and is retried; remote inserts are idempotent. The sender assumes llama-swap's file-backed Activity is append-only. It compares the first archived row and the remote cursor row before syncing, and rotates to a private `.llama-telemetry-source.json` generation if either differs or disappears. This is **not** a full audit of older rows: an in-place edit of an interior row can go unnoticed. Do not rewrite the source Activity table; after a restore or manual rebuild, reconcile history before trusting exact totals (automatic generation rotation may duplicate restored rows). If the desktop sleeps, the remote dashboard retains prior data; the timer catches up when it wakes. The server's historical database has no automatic pruning.

## Verify

```sh
python3 -m unittest discover -s tests -v
systemd-analyze verify llama-telemetry-push.service llama-telemetry-push.timer
systemctl --user list-timers llama-telemetry-push.timer
```

After an actual request, inspect `activity` locally with `sqlite3 'file:<activity-db>?mode=ro' 'select count(*) from activity'`, then compare to the server's `activity` count. No API key or login is stored in this repository.
