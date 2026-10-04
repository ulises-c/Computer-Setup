#!/usr/bin/env python3
"""Forward every ntfy message to a Discord webhook chosen by topic prefix.

server-* topics go to DISCORD_WEBHOOK_SERVER, game-* to DISCORD_WEBHOOK_GAME,
pi-* to DISCORD_WEBHOOK_PI; anything else to DISCORD_WEBHOOK_DEFAULT if set.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

ROUTE_PREFIXES = ("server", "game", "pi")
TOPIC_RE = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
MESSAGE_ID_RE = re.compile(r"[A-Za-z0-9]{1,64}\Z")
WEBHOOK_RE = re.compile(r"https://(?:discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+\Z")
COLORS = {1: 0x95A5A6, 2: 0x95A5A6, 3: 0x3498DB, 4: 0xE67E22, 5: 0xE74C3C}
USER_AGENT = "ntfy-discord-relay/1"
# ntfy sends a keepalive every 45s; a silent minute and a half means the stream is dead.
STREAM_TIMEOUT_SECONDS = 90
# After a long outage, resuming from the last id would replay up to the ntfy cache
# (30 days); anything older than this is stale and skipped rather than flooding Discord.
MAX_MESSAGE_AGE_SECONDS = 24 * 3600
DELIVERY_ATTEMPTS = 5


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def load_config(env: dict[str, str]) -> dict[str, Any]:
    base = env.get("NTFY_URL", "").rstrip("/")
    if not base.startswith(("https://", "http://")):
        raise SystemExit("error: NTFY_URL must be an http(s) URL")
    topics = [topic.strip() for topic in env.get("RELAY_TOPICS", "").split(",") if topic.strip()]
    if not topics or not all(TOPIC_RE.match(topic) for topic in topics):
        raise SystemExit("error: RELAY_TOPICS must be a comma-separated list of ntfy topics")
    webhooks = {}
    for name in (*ROUTE_PREFIXES, "default"):
        url = env.get(f"DISCORD_WEBHOOK_{name.upper()}", "").strip()
        if url and not WEBHOOK_RE.match(url):
            raise SystemExit(f"error: DISCORD_WEBHOOK_{name.upper()} is not a Discord webhook URL")
        if url:
            webhooks[name] = url
    if not webhooks:
        raise SystemExit("error: set at least one DISCORD_WEBHOOK_* URL")
    return {
        "base": base,
        "topics": topics,
        "webhooks": webhooks,
        "token": env.get("NTFY_TOKEN", ""),
        "state_file": Path(env.get("RELAY_STATE_FILE", "/state/last-id")),
    }


def webhook_for(topic: str, webhooks: dict[str, str]) -> str | None:
    prefix = topic.split("-", 1)[0]
    return webhooks.get(prefix) or webhooks.get("default")


def discord_payload(message: dict[str, Any]) -> dict[str, Any]:
    topic = str(message.get("topic", ""))
    priority = message.get("priority", 3)
    embed: dict[str, Any] = {
        "title": str(message.get("title") or topic)[:256],
        "description": str(message.get("message", ""))[:4000],
        "color": COLORS.get(priority if isinstance(priority, int) else 3, COLORS[3]),
        "footer": {"text": topic},
    }
    if isinstance(message.get("time"), int):
        embed["timestamp"] = datetime.fromtimestamp(message["time"], timezone.utc).isoformat()
    # Message text comes from scripts on every server; never let it ping anyone.
    return {"username": "ntfy", "embeds": [embed], "allowed_mentions": {"parse": []}}


def deliver(url: str, payload: dict[str, Any], sleep: Callable[[float], None] = time.sleep) -> bool:
    body = json.dumps(payload).encode()
    for attempt in range(DELIVERY_ATTEMPTS):
        request = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=15):
                return True
        except urllib.error.HTTPError as error:
            if error.code == 429:
                try:
                    retry_after = float(json.loads(error.read() or b"{}").get("retry_after", 1))
                except (ValueError, AttributeError):
                    retry_after = 1.0
                sleep(min(max(retry_after, 0.5), 60))
                continue
            if error.code < 500:
                log(f"error: Discord rejected the message (HTTP {error.code}); dropping it")
                return False
        except (urllib.error.URLError, OSError) as error:
            log(f"warning: Discord delivery failed: {error}")
        sleep(min(2 ** attempt, 30))
    log("error: Discord delivery failed after retries; dropping the message")
    return False


def read_state(path: Path) -> str | None:
    try:
        value = path.read_text().strip()
    except OSError:
        return None
    return value if MESSAGE_ID_RE.match(value) else None


def write_state(path: Path, message_id: str) -> None:
    try:
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text(message_id + "\n")
        os.replace(tmp, path)
    except OSError as error:
        log(f"warning: cannot save relay position to {path}: {error}")


def stream_url(config: dict[str, Any], since: str | None) -> str:
    url = f"{config['base']}/{','.join(config['topics'])}/json"
    return url + ("?" + urllib.parse.urlencode({"since": since}) if since else "")


def relay_events(
    lines: Iterable[bytes],
    config: dict[str, Any],
    since: str | None,
    send: Callable[[str, dict[str, Any]], bool] = deliver,
    now: Callable[[], float] = time.time,
) -> str | None:
    for raw in lines:
        try:
            event = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(event, dict) or event.get("event") != "message":
            continue
        message_id = event.get("id")
        if not isinstance(message_id, str) or not MESSAGE_ID_RE.match(message_id):
            continue
        topic = str(event.get("topic", ""))
        url = webhook_for(topic, config["webhooks"])
        sent_at = event.get("time")
        if isinstance(sent_at, int) and now() - sent_at > MAX_MESSAGE_AGE_SECONDS:
            log(f"skipping stale message {message_id} on {topic}")
        elif url is None:
            log(f"no Discord webhook for topic {topic}; skipping")
        else:
            send(url, discord_payload(event))
        since = message_id
        write_state(config["state_file"], since)
    return since


def run_once(config: dict[str, Any], since: str | None) -> str | None:
    headers = {"User-Agent": USER_AGENT}
    if config["token"]:
        headers["Authorization"] = f"Bearer {config['token']}"
    request = urllib.request.Request(stream_url(config, since), headers=headers)
    with urllib.request.urlopen(request, timeout=STREAM_TIMEOUT_SECONDS) as response:
        return relay_events(response, config, since)


def main() -> int:
    config = load_config(dict(os.environ))
    since = read_state(config["state_file"])
    log(f"relaying {len(config['topics'])} ntfy topics to Discord"
        + (f", resuming after {since}" if since else ""))
    backoff = 5
    while True:
        try:
            since = run_once(config, since)
            backoff = 5
        except (urllib.error.URLError, OSError, TimeoutError) as error:
            log(f"warning: ntfy stream dropped: {error}; reconnecting in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    raise SystemExit(main())
