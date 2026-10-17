#!/usr/bin/env python3
"""Forward every ntfy message to a Discord webhook chosen by topic prefix.

server-* topics go to DISCORD_WEBHOOK_SERVER, game-* to DISCORD_WEBHOOK_GAME,
pi-* to DISCORD_WEBHOOK_PI, nas-* to DISCORD_WEBHOOK_NAS, mac-* to
DISCORD_WEBHOOK_MAC; anything else to DISCORD_WEBHOOK_DEFAULT if set.

ntfy has no wildcard subscription, so a topic missing from RELAY_TOPICS never
reaches Discord. When RELAY_CACHE_DB points at ntfy's message cache, a daily
audit compares the topics ntfy actually received against RELAY_TOPICS and posts
one warning (to the server channel) whenever a new unrelayed topic appears.
"""
from __future__ import annotations

import http.client
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

ROUTE_PREFIXES = ("server", "game", "pi", "nas", "mac")
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
DELIVERY_BUDGET_SECONDS = 60
# A 429 body is a small JSON object; never read an unbounded one.
RATE_LIMIT_BODY_LIMIT = 4096
CHILD_REAP_SECONDS = 5
AUDIT_INTERVAL_SECONDS = 24 * 3600
# Let the stream connect first; the audit is not urgent.
AUDIT_FIRST_DELAY_SECONDS = 60


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
        "cache_db": env.get("RELAY_CACHE_DB", "").strip(),
        "audit_state_file": Path(env.get("RELAY_AUDIT_STATE_FILE", "/state/unrelayed-topics")),
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


def retry_after_seconds(body: bytes) -> float:
    """Discord's rate-limit delay; anything unusable falls back to one second."""
    try:
        value = float(json.loads(body or b"{}").get("retry_after", 1))
    except (ValueError, TypeError, AttributeError, OverflowError):
        return 1.0
    return value if math.isfinite(value) and value >= 0 else 1.0


def attempt_post(url: str, body: bytes, timeout: float) -> tuple[int, float]:
    """One in-process POST as (HTTP status, 429 retry_after); transport errors raise."""
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout):
            return 200, 0.0
    except urllib.error.HTTPError as error:
        with error:
            limited = error.read(RATE_LIMIT_BODY_LIMIT) if error.code == 429 else b""
        return error.code, retry_after_seconds(limited)


def post_child() -> int:
    """`relay.py --post`: one attempt for post_once; request on stdin, result on stdout."""
    job = json.loads(sys.stdin.read())
    try:
        status, retry_after = attempt_post(job["url"], job["body"].encode(), job["timeout"])
        result: dict[str, Any] = {"status": status, "retry_after": retry_after}
    except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
        result = {"error": repr(error)}
    sys.stdout.write(json.dumps(result))
    return 0


def post_once(url: str, body: bytes, remaining: float) -> tuple[int, float]:
    """attempt_post in a child process that is killed once `remaining` seconds pass.

    Socket timeouts bound each read, not the whole exchange, and a thread blocked
    in DNS or a trickling response cannot be cancelled; a process can, and the
    kill releases its socket. The webhook URL travels on stdin, never argv.
    """
    job = json.dumps({"url": url, "body": body.decode(), "timeout": max(0.1, min(15, remaining))})
    child = subprocess.Popen(
        [sys.executable, "-I", str(Path(__file__).resolve()), "--post"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    try:
        out, _ = child.communicate(job, timeout=remaining)
    except subprocess.TimeoutExpired:
        child.kill()
        try:
            child.communicate(timeout=CHILD_REAP_SECONDS)
        except subprocess.TimeoutExpired:
            log(f"warning: delivery helper {child.pid} did not exit after SIGKILL")
        raise TimeoutError("no complete response within the delivery budget") from None
    try:
        result = json.loads(out)
    except ValueError:
        raise OSError(f"delivery helper exited {child.returncode} without a result") from None
    if "error" in result:
        raise OSError(result["error"])
    return int(result["status"]), float(result["retry_after"])


def deliver(url: str, payload: dict[str, Any], sleep: Callable[[float], None] = time.sleep) -> bool:
    body = json.dumps(payload).encode()
    deadline = time.monotonic() + DELIVERY_BUDGET_SECONDS
    for attempt in range(DELIVERY_ATTEMPTS):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        delay = min(2 ** attempt, 30)
        try:
            status, retry_after = post_once(url, body, remaining)
        except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
            log(f"warning: Discord delivery failed: {error!r}")
        else:
            if status < 400:
                return True
            if status == 429:
                delay = max(retry_after, 0.5)
            elif status < 500:
                log(f"error: Discord rejected the message (HTTP {status}); dropping it")
                return False
        if attempt == DELIVERY_ATTEMPTS - 1:
            break
        if delay >= deadline - time.monotonic():
            log(f"error: next retry ({delay:g}s) would exceed the {DELIVERY_BUDGET_SECONDS}s delivery budget")
            break
        sleep(delay)
    log("error: Discord delivery failed after retries or delivery budget; dropping the message")
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
    on_position: Callable[[str], None] | None = None,
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
        if on_position is not None:
            on_position(since)
        write_state(config["state_file"], since)
    return since


def run_once(config: dict[str, Any], since: str | None,
             on_position: Callable[[str], None] | None = None) -> str | None:
    headers = {"User-Agent": USER_AGENT}
    if config["token"]:
        headers["Authorization"] = f"Bearer {config['token']}"
    request = urllib.request.Request(stream_url(config, since), headers=headers)
    with urllib.request.urlopen(request, timeout=STREAM_TIMEOUT_SECONDS) as response:
        return relay_events(response, config, since, on_position=on_position)


def cached_topics(db_path: str) -> dict[str, tuple[int, int]]:
    """{topic: (message count, last message time)} from ntfy's cache, read-only."""
    uri = "file:" + urllib.parse.quote(db_path) + "?mode=ro"
    with sqlite3.connect(uri, uri=True, timeout=10) as db:
        rows = db.execute("SELECT topic, COUNT(*), MAX(time) FROM messages GROUP BY topic").fetchall()
    return {str(topic): (int(count), int(last or 0)) for topic, count, last in rows if TOPIC_RE.match(str(topic))}


def audit_findings(config: dict[str, Any], seen: dict[str, tuple[int, int]]) -> dict[str, str]:
    """Topics whose messages cannot reach Discord, with the reason."""
    findings = {}
    for topic in sorted(seen):
        if topic not in config["topics"]:
            findings[topic] = "not in RELAY_TOPICS"
    for topic in config["topics"]:
        if webhook_for(topic, config["webhooks"]) is None:
            findings[topic] = "in RELAY_TOPICS but no webhook matches its prefix"
    return findings


def audit_payloads(findings: dict[str, str], seen: dict[str, tuple[int, int]]) -> list[dict[str, Any]]:
    instruction = ("Add the topic to RELAY_TOPICS (and a matching DISCORD_WEBHOOK_*) in "
                   "linux-server/ntfy-discord/.env on the main server, then `docker compose up -d`.")
    messages = []
    lines = []
    for topic, reason in findings.items():
        count, last = seen.get(topic, (0, 0))
        when = f", last <t:{last}:R>" if last else ""
        line = f"`{topic}`: {reason} ({count} message{'s' if count != 1 else ''} in the ntfy cache{when})"
        if lines and len("\n".join([*lines, line, "", instruction])) > 4000:
            messages.append("\n".join([*lines, "", instruction]))
            lines = []
        lines.append(line)
    messages.append("\n".join([*lines, "", instruction]))
    return [discord_payload({
        "topic": "ntfy-discord-audit",
        "title": "ntfy topics not reaching Discord",
        "message": message,
        "priority": 4,
        "time": int(time.time()),
    }) for message in messages]


def run_audit(config: dict[str, Any], send: Callable[[str, dict[str, Any]], bool] = deliver) -> dict[str, str]:
    """Check once; alert only when the set of problem topics gains a new entry."""
    seen = cached_topics(config["cache_db"])
    findings = audit_findings(config, seen)
    path = config["audit_state_file"]
    try:
        known = set(path.read_text().split())
    except OSError:
        known = set()
    new = set(findings) - known
    if findings:
        log("audit: not relayed: " + ", ".join(f"{t} ({r})" for t, r in findings.items()))
    url = config["webhooks"].get("server") or config["webhooks"].get("default") or next(iter(config["webhooks"].values()))
    if new:
        for payload in audit_payloads(findings, seen):
            if not send(url, payload):
                return findings
    try:
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_text("".join(f"{t}\n" for t in sorted(findings)))
        os.replace(tmp, path)
    except OSError as error:
        log(f"warning: cannot save audit state to {path}: {error}")
    return findings


def audit_loop(config: dict[str, Any]) -> None:
    time.sleep(AUDIT_FIRST_DELAY_SECONDS)
    while True:
        try:
            run_audit(config)
        except (sqlite3.Error, OSError) as error:
            log(f"warning: topic audit failed: {error}")
        time.sleep(AUDIT_INTERVAL_SECONDS)


def main() -> int:
    config = load_config(dict(os.environ))
    since = read_state(config["state_file"])

    def update_position(message_id: str) -> None:
        nonlocal since
        since = message_id

    log(f"relaying {len(config['topics'])} ntfy topics to Discord"
        + (f", resuming after {since}" if since else ""))
    if config["cache_db"]:
        threading.Thread(target=audit_loop, args=(config,), daemon=True).start()
    backoff = 5
    while True:
        try:
            since = run_once(config, since, on_position=update_position)
            backoff = 5
        except (urllib.error.URLError, OSError, http.client.HTTPException) as error:
            log(f"warning: ntfy stream dropped: {error!r}; reconnecting in {backoff}s")
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    raise SystemExit(post_child() if sys.argv[1:] == ["--post"] else main())
