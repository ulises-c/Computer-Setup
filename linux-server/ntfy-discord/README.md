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
| `nas-*`      | `DISCORD_WEBHOOK_NAS`    | NAS                   |
| `mac-*`      | `DISCORD_WEBHOOK_MAC`    | Mac mini              |
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

- Starts with new messages only. After a restart it requests replay from the last
  processed id in `state/last-id`; messages older than 24 hours are skipped.
  The in-process cursor advances after each processed message, including explicit
  skips and delivery failures, even if the stream then disconnects. Checkpoint
  write failures are logged: reconnects in that process retain the cursor, but
  a restart can replay messages from an older checkpoint or start fresh if none
  exists. This is not an exactly-once or guaranteed-delivery channel.
- Each message gets a 60-second delivery budget and at most five attempts. The
  budget is wall-clock: it covers each request and response read, not only the
  waits between them, so a slow or stalled Discord response cannot hold the
  stream. Rate limits (HTTP 429) wait the requested `retry_after` (at least
  0.5 seconds; an invalid value counts as one second) and never retry early.
  When that wait would run past the budget, the message is dropped and logged
  instead. Network errors, truncated responses and 5xx also retry within the
  budget; other 4xx drop the message at once. A dropped message is not retried
  later: the cursor moves on so the next message is delivered. Each attempt
  runs in a short-lived helper process that is killed at the deadline, so a
  stalled Discord connection cannot pile up threads or sockets. A killed
  attempt may still have reached Discord, so a dropped message can
  occasionally appear there after all.
- ntfy has no wildcard subscription: when a script starts using a new topic,
  add it to `RELAY_TOPICS` and `docker compose up -d`. A daily audit catches the
  ones that are forgotten: it reads ntfy's message cache (mounted read-only) and,
  when a topic that ntfy received is missing from `RELAY_TOPICS`, or a listed
  topic has no matching webhook, posts one "ntfy topics not reaching Discord"
  warning to the server channel, split into complete reports when the list is
  too long for one embed. Topics are acknowledged only after every report chunk
  succeeds; partial delivery retries the entire report on the next daily check,
  so previously delivered chunks can repeat. Audit-state write failures are
  logged and can likewise cause repeat reports. It warns again when a new topic joins
  the list (`state/unrelayed-topics`); the container log names every unrelayed
  topic on each check.
- Replay still uses one global message-id cursor for the multi-topic subscription.
  Whether ntfy replays every topic correctly from that cursor remains unverified;
  the reconnect tests do not validate live ntfy replay semantics. No per-topic
  cursor workaround is implemented without a supported reproduction.
- If ntfy or this server is down, nothing reaches Discord either; the relay is a
  convenience path, not a second alerting channel.
- Messages leave the tailnet for Discord. They are the same text ntfy already
  shows (backup results, service failures, update notices).
