# ntfy → Discord relay

Every server already posts its alerts to ntfy on the main server. This container
subscribes to those topics and forwards each message to a Discord channel, so
alerts reach Discord without installing ntfy in each browser and without
touching any server's scripts.

| Topic prefix | Webhook                  | Source                |
|--------------|--------------------------|-----------------------|
| `server-*`   | `DISCORD_WEBHOOK_SERVER` | main server           |
| `game-*`     | `DISCORD_WEBHOOK_GAME`   | game server           |
| `pi-*`       | `DISCORD_WEBHOOK_PI`     | Raspberry Pi          |
| other        | `DISCORD_WEBHOOK_DEFAULT`| dropped when unset    |

Messages arrive as embeds: the ntfy title, the message body, a colour from the
ntfy priority (grey low, blue default, orange high, red urgent), the topic in the
footer, and the send time, which Discord shows in each viewer's local time zone.
Mentions are disabled, so message text can never ping anyone.

## Setup

1. In each Discord channel: Settings → Integrations → Webhooks → New Webhook →
   Copy Webhook URL.
2. On the main server:
   ```sh
   cd linux-server/ntfy-discord
   cp .env.example .env   # fill NTFY_URL and the webhook URLs
   chmod 600 .env
   mkdir -p state
   docker compose up -d
   docker logs -f ntfy-discord
   ```
3. Test one route: `curl -d "relay test" -H "Title: Relay test" "$NTFY_URL/game-dragonwilds"`.

## Behaviour

- Starts with new messages only. After a restart it resumes from the last
  relayed id in `state/last-id`, so nothing sent while it was down is lost, but
  messages older than 24 hours are skipped instead of replayed.
- Discord rate limits (HTTP 429) are honoured; network and 5xx errors are
  retried five times, then the message is dropped and logged.
- ntfy has no wildcard subscription: when a script starts using a new topic,
  add it to `RELAY_TOPICS` and `docker compose up -d`.
- If ntfy or this server is down, nothing reaches Discord either; the relay is a
  convenience path, not a second alerting channel.
- Messages leave the tailnet for Discord. They are the same text ntfy already
  shows (backup results, service failures, update notices).
