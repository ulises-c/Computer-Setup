# ntfy

Push notifications for the server's own alerting — backups, the Forgejo runner,
the UPS, and the Dragonwilds game server all publish here. Fronted by a Tailscale
sidecar at `https://ntfy.<tailnet>.ts.net`; see [../HTTPS.md](../HTTPS.md).

## Topics

ntfy has no topic registry — a topic exists as soon as something publishes to it,
and there is no API to list them. The authoritative list is what the services are
configured to use:

```bash
grep -h '^NTFY_TOPIC=' ../*/.env | sort -u
```

| Topic | Published by |
| --- | --- |
| `server-backup` | `../backup` |
| `server-runner` | `../forgejo` (Mac mini Actions runner) |
| `server-ups` | `../ups` |
| `server-dragonwilds` | `../dragonwilds` |

Subscriptions are per-client, held in the browser or phone app — not on the
server. An empty web UI means this browser has not subscribed yet, not that
nothing is publishing. Subscribe by visiting
`https://ntfy.<tailnet>.ts.net/<topic>`.

Since messages are now cached on disk, topics with recent traffic can also be
read back directly:

```bash
sudo sqlite3 cache/cache.db \
  'SELECT topic, COUNT(*), datetime(MAX(time),"unixepoch") FROM messages GROUP BY topic;'
```

## Message cache

`NTFY_CACHE_FILE` must be set explicitly. Without it ntfy keeps messages **in
memory only** — the `./cache` mount does nothing and every message is lost
whenever the container restarts, which watchtower does on its own schedule. An
alert that fired overnight would be gone before it was ever read.

```yaml
- NTFY_CACHE_FILE=/var/cache/ntfy/cache.db
- NTFY_CACHE_DURATION=30d
```

Retention defaults to 12h, which loses exactly the alert nobody was awake for. A
month keeps enough history to correlate an incident after the fact; messages are
plain text and attachments are off, so the database stays small.

ntfy validates the duration at startup and refuses to run on a bad value
(`invalid cache duration: ...`), so a healthy container means the setting took.
Cache persistence was verified by publishing a message, restarting the container,
and reading it back.

## Auth

The server is unauthenticated: anyone on the tailnet can publish to or subscribe
to any topic, and no `NTFY_AUTH_FILE` is configured. That is the deliberate
trade for a tailnet-only service, but it does mean topic names are the only thing
standing between a tailnet device and these alerts.
