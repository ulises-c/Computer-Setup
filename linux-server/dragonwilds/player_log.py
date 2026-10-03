#!/usr/bin/env python3
"""Build a compact Dragonwilds player index from the system journal.

The journal is the source of truth. This script stores a bounded JSONL event
projection plus an atomically rewritten one-record-per-player summary.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import selectors
import stat
import subprocess
import sys
import time
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterable

SCHEMA = 1
PLAYER_ID_RE = re.compile(
    r"\b(?:PlayerId|Player ID|ProductUserId|Product User ID|UniqueNetId)"
    r"\s*(?:=|:|\[)\s*([A-Za-z0-9._:-]+)"
)
PLAYER_METADATA_RE = re.compile(
    r"(?:\s*[\[\(\{]\s*(?:PlayerId|Player ID|ProductUserId|Product User ID|"
    r"UniqueNetId|JoinCode|Password|WorldPassword)\s*(?:=|:)\s*[^\]\)\}]*[\]\)\}])"
    r"|(?:\s+(?:PlayerId|Player ID|ProductUserId|Product User ID|UniqueNetId|"
    r"JoinCode|Password|WorldPassword)\s*(?:=|:)\s*.*$)",
    re.IGNORECASE,
)
PLAYER_SECRET_MARKER_RE = re.compile(
    r"(?:join\s*[_-]*\s*code|world\s*[_-]*\s*password|password|secret|token|"
    r"api\s*[_-]*\s*key|credential|passphrase|private\s*[_-]*\s*key|"
    r"access\s*[_-]*\s*key|auth(?:entication)?\s*[_-]*\s*(?:key|token|secret|code))",
    re.IGNORECASE,
)
IDENTIFIER_RE = re.compile(r"[A-Za-z0-9_.:=+;,@%/-]{1,512}\Z")
SESSION_ID_RE = re.compile(r"(?:session:[0-9a-f]{32}|run:[0-9a-f]{32})\Z")
SERVER_BUILD_RE = re.compile(r"[0-9]{1,128}\Z")
REMOTE_RE = re.compile(
    r"(?:RemoteAddr:\s*|address\s+)"
    r"(?P<address>\[[^\]]+\]|[0-9A-Fa-f:.]+):(?P<port>[0-9]+)"
)
JOIN_RE = re.compile(r"Join succeeded:\s*(?P<name>.+?)\s*$")
MAX_COUNT = 10**12
# Stays under the unit's TimeoutStartSec so a nightly backup skips a run instead of failing it.
LOCK_WAIT_SECONDS = 20
MAX_FUTURE_TIMESTAMP_SKEW_US = 7 * 24 * 60 * 60 * 1_000_000
MAX_JOURNAL_RECORDS = 8192
MAX_JOURNAL_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_COMMAND_ERROR_BYTES = 1 * 1024 * 1024
MAX_SYSTEMD_PROPERTY_BYTES = 64 * 1024
MAX_STORED_EVENTS = 100000
MAX_EVENT_FILE_BYTES = 64 * 1024 * 1024
MAX_SUMMARY_FILE_BYTES = 16 * 1024 * 1024
MAX_STATE_FILE_BYTES = 8 * 1024 * 1024
MAX_MANIFEST_BYTES = 1 * 1024 * 1024
MAX_PLAYERS = 10000
MAX_NAMES_PER_PLAYER = 256
MAX_IPS_PER_PLAYER = 256
MAX_PORTS_PER_IP = 1024
MAX_ACTIVE_CONNECTIONS = 2048
MAX_TRANSACTION_MARKER_BYTES = 1 * 1024 * 1024
MAX_RETENTION_DAYS = 3650


def _regular_exists(path: Path) -> bool:
    try:
        file_stat = os.lstat(path)
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(file_stat.st_mode):
        raise RuntimeError(f"player-log path is not a regular file: {path}")
    return True


def _open_regular(path: Path, flags: int, mode: int = 0o600):
    fd = os.open(
        path,
        flags | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
        mode,
    )
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError(f"player-log path is not a regular file: {path}")
        return fd
    except BaseException:
        os.close(fd)
        raise


def _read_regular_text(path: Path, limit: int) -> str | None:
    if not _regular_exists(path):
        return None
    fd = _open_regular(path, os.O_RDONLY)
    with os.fdopen(fd, "rb") as handle:
        if os.fstat(handle.fileno()).st_size > limit:
            raise RuntimeError(f"player-log file is too large: {path}")
        content = handle.read(limit + 1)
        if len(content) > limit:
            raise RuntimeError(f"player-log file grew beyond its limit: {path}")
        try:
            return content.decode("utf-8")
        except UnicodeDecodeError as error:
            raise RuntimeError(f"player-log file is not valid UTF-8: {path}") from error


def _chmod_regular(path: Path, mode: int) -> None:
    fd = _open_regular(path, os.O_RDONLY)
    try:
        os.fchmod(fd, mode)
    finally:
        os.close(fd)


def _timestamp(record: dict[str, Any]) -> str:
    raw = _record_timestamp_us(record)
    try:
        if raw is None:
            raise ValueError("missing journal timestamp")
        value = datetime.fromtimestamp(raw / 1_000_000, timezone.utc)
    except (TypeError, ValueError, OSError):
        value = datetime.now(timezone.utc)
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _record_timestamp_us(record: dict[str, Any]) -> int | None:
    raw = record.get("__REALTIME_TIMESTAMP")
    if raw is None:
        return None
    try:
        value = int(raw)
    except (AttributeError, TypeError, ValueError):
        return None
    now_us = int(datetime.now(timezone.utc).timestamp() * 1_000_000)
    return value if 0 <= value <= now_us + MAX_FUTURE_TIMESTAMP_SKEW_US else None


def _remote_endpoint(message: str) -> tuple[str, int | None] | None:
    match = REMOTE_RE.search(message)
    if not match:
        return None
    address = match.group("address").strip("[]")
    address = _clean_remote_addr(address)
    port = _clean_remote_port(match.group("port"))
    return (address, port) if address is not None and port is not None else None


def _endpoint_key(endpoint: tuple[str, int | None]) -> str:
    address, port = endpoint
    return f"{address}:{port}" if port is not None else address


def _player_id(record: dict[str, Any], message: str) -> str | None:
    for key in (
        "PLAYER_ID",
        "PlayerId",
        "Player ID",
        "EOS_PRODUCT_USER_ID",
        "ProductUserId",
        "UniqueNetId",
    ):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    match = PLAYER_ID_RE.search(message)
    return match.group(1) if match else None


def _clean_player_name(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    name = PLAYER_METADATA_RE.sub("", value)
    name = re.sub(r"\s*[\[\(\{][^\]\)\}]*[\]\)\}]", "", name).strip(" []").strip()
    if (
        not name
        or len(name) > 128
        or any(ord(character) < 32 for character in name)
        or PLAYER_SECRET_MARKER_RE.search(name)
    ):
        return None
    return name


def _player_name(message: str) -> str | None:
    match = JOIN_RE.search(message)
    return _clean_player_name(match.group("name")) if match else None


def _identity_key(player_id: str | None, player_name: str | None) -> str | None:
    if player_id:
        return f"id:{player_id}"
    if player_name:
        return f"name:{player_name.casefold()}"
    return None


def _remember_cursor(state: dict[str, Any], cursor: str) -> None:
    state["last_cursor"] = cursor
    processed_cursors = list(state.get("processed_cursors", []))
    if cursor not in processed_cursors:
        processed_cursors.append(cursor)
    state["processed_cursors"] = processed_cursors[-8192:]


def _clean_identifier(value: Any) -> str | None:
    if not isinstance(value, str) or not IDENTIFIER_RE.fullmatch(value):
        return None
    if PLAYER_SECRET_MARKER_RE.search(value):
        return None
    return value


def _clean_session_id(value: Any) -> str | None:
    return value if isinstance(value, str) and SESSION_ID_RE.fullmatch(value) else None


def _clean_server_build(value: Any) -> str | None:
    return value if isinstance(value, str) and SERVER_BUILD_RE.fullmatch(value) else None


def _clean_remote_addr(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return None
    return value


def _clean_remote_port(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        port = value
    elif isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        if len(value) > 5:
            return None
        port = int(value)
    else:
        return None
    return port if port is not None and 1 <= port <= 65535 else None


def _event(
    record: dict[str, Any],
    event_type: str,
    session_id: str | None,
    server_build: str | None,
    *,
    player_id: str | None = None,
    player_name: str | None = None,
    remote_addr: str | None = None,
    remote_port: int | None = None,
) -> dict[str, Any]:
    cursor = _clean_identifier(record.get("__CURSOR"))
    player_id = _clean_identifier(player_id)
    if player_id is not None and len(player_id) > 256:
        player_id = None
    player_name = _clean_player_name(player_name)
    remote_addr = _clean_remote_addr(remote_addr)
    remote_port = _clean_remote_port(remote_port)
    session_id = _clean_session_id(session_id)
    server_build = _clean_server_build(server_build)
    identity_source = "player_id" if player_id else ("name" if player_name else None)
    return {
        "schema": SCHEMA,
        "event_id": f"{cursor}:{event_type}" if cursor else None,
        "event": event_type,
        "timestamp": _timestamp(record),
        "session_id": session_id,
        "player_id": player_id,
        "identity_source": identity_source,
        "player_name": player_name,
        "remote_addr": remote_addr,
        "remote_port": remote_port,
        "server_build": server_build or None,
        "source_cursor": cursor,
    }


def parse_journal_records(
    records: Iterable[dict[str, Any]],
    state: dict[str, Any],
    *,
    session_id: str,
    server_build: str = "",
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Parse only the small set of connection messages we understand."""
    next_state = _sanitize_state(state)
    safe_session_id = _clean_session_id(session_id)
    if safe_session_id is None:
        raise RuntimeError("invalid or unstable player-log session identity")
    safe_server_build = _clean_server_build(server_build)
    if next_state.get("session_id") != safe_session_id:
        next_state["active_connections"] = {}
        next_state["pending_connections"] = []
        next_state.pop("last_realtime_timestamp_us", None)
        next_state["processed_cursors"] = []
    next_state["session_id"] = safe_session_id
    next_state["initialized"] = True
    active = dict(next_state.get("active_connections", {}))
    pending = []
    for item in next_state.get("pending_connections", next_state.get("pending_addresses", [])):
        address = _clean_remote_addr(item.get("address")) if isinstance(item, dict) else None
        port = _clean_remote_port(item.get("port")) if isinstance(item, dict) else None
        timestamp = _canonical_timestamp(item.get("timestamp")) if isinstance(item, dict) else None
        if (
            isinstance(item, dict)
            and timestamp is not None
            and address is not None
        ):
            pending.append({
                "address": address,
                "port": port,
                "timestamp": timestamp,
            })
    events: list[dict[str, Any]] = []

    for record_index, record in enumerate(records):
        if record_index >= MAX_JOURNAL_RECORDS:
            raise RuntimeError("journal record limit exceeded")
        if not isinstance(record, dict):
            continue
        cursor = _clean_identifier(record.get("__CURSOR"))
        if not cursor:
            continue
        timestamp_us = _record_timestamp_us(record)
        if timestamp_us is None:
            _remember_cursor(next_state, cursor)
            continue
        record_timestamp = _timestamp(record)
        current_time = _parse_timestamp(record_timestamp)
        if current_time is not None:
            pending = [
                item for item in pending
                if not item.get("timestamp")
                or (
                    current_time - (_parse_timestamp(item["timestamp"]) or current_time)
                ).total_seconds() <= 120
            ]
        message = record.get("MESSAGE", "")
        if not isinstance(message, str):
            _remember_cursor(next_state, cursor)
            continue
        relevant_record = False

        if "AddClientConnection: Added client connection" in message:
            relevant_record = True
            endpoint = _remote_endpoint(message)
            if endpoint:
                address, port = endpoint
                pending.append({"address": address, "port": port, "timestamp": record_timestamp})
                pending = pending[-32:]

        join = JOIN_RE.search(message)
        if join:
            relevant_record = True
            join_endpoint = _remote_endpoint(message)
            if join_endpoint:
                pending_item = next(
                    (
                        item for item in pending
                        if _endpoint_key((item["address"], item.get("port")))
                        == _endpoint_key(join_endpoint)
                    ),
                    None,
                )
                if pending_item is None:
                    pending_item = {"address": join_endpoint[0], "port": join_endpoint[1]}
            else:
                candidates = [
                    item for item in pending
                    if _endpoint_key((item["address"], item.get("port"))) not in active
                ]
                pending_item = candidates[0] if len(candidates) == 1 else None
            address = pending_item["address"] if pending_item else None
            port = pending_item.get("port") if pending_item else None
            if pending_item in pending:
                pending.remove(pending_item)
            player_id = _player_id(record, message)
            player_name = _player_name(message)
            event = _event(
                record,
                "player_joined",
                safe_session_id,
                safe_server_build,
                player_id=player_id,
                player_name=player_name,
                remote_addr=address,
                remote_port=port,
            )
            clean_event = _sanitize_event(event, require_key=True)
            if clean_event is not None:
                events.append(clean_event)
            if address and clean_event is not None:
                endpoint_key = _endpoint_key((address, port))
                if endpoint_key not in active and len(active) >= MAX_ACTIVE_CONNECTIONS:
                    active.pop(next(iter(active)))
                active[endpoint_key] = {
                    "player_id": clean_event.get("player_id"),
                    "player_name": clean_event.get("player_name"),
                    "remote_addr": clean_event.get("remote_addr"),
                    "remote_port": clean_event.get("remote_port"),
                    "identity_key": _identity_key(
                        clean_event.get("player_id"), clean_event.get("player_name")
                    ),
                }

        if "RemoveClientConnection" in message or "Removed address" in message:
            relevant_record = True
            endpoint = _remote_endpoint(message)
            address = endpoint[0] if endpoint else None
            port = endpoint[1] if endpoint else None
            if endpoint:
                pending = [
                    item for item in pending
                    if _endpoint_key((item["address"], item.get("port")))
                    != _endpoint_key(endpoint)
                ]
            previous = active.pop(_endpoint_key(endpoint), {}) if endpoint else {}
            if not previous and address:
                matches = [key for key, value in active.items() if value.get("remote_addr") == address]
                if len(matches) == 1:
                    previous = active.pop(matches[0])
            clean_event = _sanitize_event(
                _event(
                    record,
                    "player_left",
                    safe_session_id,
                    safe_server_build,
                    player_id=previous.get("player_id"),
                    player_name=previous.get("player_name"),
                    remote_addr=address,
                    remote_port=previous.get("remote_port", port),
                ),
                require_key=True,
            )
            if clean_event is not None:
                events.append(clean_event)

        if relevant_record:
            previous_timestamp = int(next_state.get("last_realtime_timestamp_us", 0) or 0)
            if previous_timestamp and timestamp_us < previous_timestamp:
                raise RuntimeError("journal timestamp moved backwards during parsing")
            next_state["last_realtime_timestamp_us"] = max(
                previous_timestamp,
                timestamp_us,
            )
        _remember_cursor(next_state, cursor)
    next_state["active_connections"] = active
    next_state["pending_connections"] = pending
    next_state.pop("pending_addresses", None)
    return events, next_state


def _filter_recovered_records(
    records: Iterable[dict[str, Any]],
    state: dict[str, Any],
    session_id: str | None = None,
) -> list[dict[str, Any]]:
    safe_state = _sanitize_state(state)
    same_session = session_id is not None and safe_state.get("session_id") == session_id
    if session_id is not None and safe_state.get("session_id") != session_id:
        safe_state.pop("last_realtime_timestamp_us", None)
        safe_state["processed_cursors"] = []
    last_timestamp = int(safe_state.get("last_realtime_timestamp_us", 0) or 0)
    processed_cursors = set(safe_state.get("processed_cursors", []))
    filtered = []
    for record in records:
        cursor = record.get("__CURSOR")
        if cursor in processed_cursors:
            continue
        timestamp = _record_timestamp_us(record)
        if same_session and last_timestamp and timestamp is not None and timestamp < last_timestamp:
            raise RuntimeError("journal timestamp moved backwards during cursor recovery")
        if last_timestamp and timestamp is not None and timestamp < last_timestamp:
            continue
        filtered.append(record)
    return filtered


def _merge_records(left: dict[str, Any], right: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(left)
    left_last = _parse_timestamp(left.get("last_seen"))
    right_last = _parse_timestamp(right.get("last_seen"))
    merged["player_id"] = merged.get("player_id") or right.get("player_id")
    merged["identity_source"] = "player_id" if merged.get("player_id") else "name"
    merged["join_count"] = min(
        MAX_COUNT,
        int(merged.get("join_count", 0)) + int(right.get("join_count", 0)),
    )
    merged["first_seen"] = _choose_timestamp(
        merged.get("first_seen"), right.get("first_seen"), earliest=True
    )
    merged["last_seen"] = _choose_timestamp(
        merged.get("last_seen"), right.get("last_seen"), earliest=False
    )
    for name in right.get("names_seen", []):
        if name not in merged.setdefault("names_seen", []) and len(merged["names_seen"]) < MAX_NAMES_PER_PLAYER:
            merged["names_seen"].append(name)
    if right_last is not None and (left_last is None or right_last >= left_last):
        if right.get("last_ip") is not None:
            merged["last_ip"] = right["last_ip"]
        if right.get("last_port") is not None:
            merged["last_port"] = right["last_port"]
    history = merged.setdefault("ip_history", {})
    for ip, info in right.get("ip_history", {}).items():
        if ip not in history:
            if len(history) >= MAX_IPS_PER_PLAYER:
                continue
            history[ip] = copy.deepcopy(info)
        else:
            history[ip]["first_seen"] = _choose_timestamp(
                history[ip]["first_seen"], info["first_seen"], earliest=True
            )
            history[ip]["last_seen"] = _choose_timestamp(
                history[ip]["last_seen"], info["last_seen"], earliest=False
            )
            history[ip]["join_count"] = min(
                MAX_COUNT,
                history[ip]["join_count"] + info["join_count"],
            )
            ports = history[ip].setdefault("ports", {})
            for port, count in info.get("ports", {}).items():
                if port in ports or len(ports) < MAX_PORTS_PER_IP:
                    ports[port] = min(MAX_COUNT, ports.get(port, 0) + count)
    return merged


def _sanitize_event(event: Any, *, require_key: bool = False) -> dict[str, Any] | None:
    if not isinstance(event, dict):
        return None
    event_type = event.get("event")
    timestamp = _canonical_timestamp(event.get("timestamp"))
    if event_type not in {"player_joined", "player_left"}:
        return None
    if timestamp is None:
        return None

    player_id = _clean_identifier(event.get("player_id"))
    if player_id is not None and len(player_id) > 256:
        player_id = None
    player_name = _clean_player_name(event.get("player_name"))
    remote_addr = _clean_remote_addr(event.get("remote_addr"))
    remote_port = _clean_remote_port(event.get("remote_port"))
    event_id = _clean_identifier(event.get("event_id"))
    source_cursor = _clean_identifier(event.get("source_cursor"))
    if require_key and event_id is None and source_cursor is None:
        return None
    session_id = _clean_session_id(event.get("session_id"))
    server_build = event.get("server_build")
    if not isinstance(server_build, str) or not re.fullmatch(r"[0-9]{1,128}", server_build):
        server_build = None

    sanitized = {
        "schema": SCHEMA,
        "event_id": event_id,
        "event": event_type,
        "timestamp": timestamp,
        "session_id": session_id,
        "player_id": player_id,
        "identity_source": "player_id" if player_id else ("name" if player_name else None),
        "player_name": player_name,
        "remote_addr": remote_addr,
        "remote_port": remote_port,
        "server_build": server_build,
        "source_cursor": source_cursor,
    }
    return sanitized


def _clean_count(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > MAX_COUNT:
        return None
    return value


def _sanitize_summary(summary: Any) -> dict[str, Any]:
    clean: dict[str, Any] = {
        "schema": SCHEMA,
        "players": {},
        "unidentified_join_count": 0,
    }
    if not isinstance(summary, dict):
        return clean

    unidentified = _clean_count(summary.get("unidentified_join_count"))
    if unidentified is not None:
        clean["unidentified_join_count"] = unidentified
    updated = _canonical_timestamp(summary.get("updated"))
    if updated is not None:
        clean["updated"] = updated

    raw_players = summary.get("players", {})
    if not isinstance(raw_players, dict):
        return clean
    for raw_player in list(raw_players.values())[:MAX_PLAYERS]:
        if not isinstance(raw_player, dict):
            continue
        player_id = _clean_identifier(raw_player.get("player_id"))
        if player_id is not None and len(player_id) > 256:
            player_id = None
        names = []
        raw_names = raw_player.get("names_seen", [])
        if isinstance(raw_names, list):
            for raw_name in raw_names[:MAX_NAMES_PER_PLAYER]:
                name = _clean_player_name(raw_name)
                if name is not None and name not in names:
                    names.append(name)
        key = _identity_key(player_id, names[0] if names else None)
        if key is None:
            continue
        first_seen = raw_player.get("first_seen")
        last_seen = raw_player.get("last_seen")
        first_seen = _canonical_timestamp(first_seen)
        last_seen = _canonical_timestamp(last_seen)
        if (
            first_seen is None
            or last_seen is None
            or not _timestamps_ordered(first_seen, last_seen)
        ):
            continue
        join_count = _clean_count(raw_player.get("join_count"))
        if join_count is None:
            continue
        player = {
            "player_id": player_id,
            "identity_source": "player_id" if player_id else "name",
            "names_seen": names,
            "first_seen": first_seen,
            "last_seen": last_seen,
            "join_count": join_count,
            "last_ip": _clean_remote_addr(raw_player.get("last_ip")),
            "last_port": _clean_remote_port(raw_player.get("last_port")),
            "ip_history": {},
        }
        raw_history = raw_player.get("ip_history", {})
        if isinstance(raw_history, dict):
            for raw_ip, raw_info in list(raw_history.items())[:MAX_IPS_PER_PLAYER]:
                ip = _clean_remote_addr(raw_ip)
                if ip is None or not isinstance(raw_info, dict):
                    continue
                info_first = raw_info.get("first_seen")
                info_last = raw_info.get("last_seen")
                info_first = _canonical_timestamp(info_first)
                info_last = _canonical_timestamp(info_last)
                info_count = _clean_count(raw_info.get("join_count"))
                if (
                    info_first is None
                    or info_last is None
                    or not _timestamps_ordered(info_first, info_last)
                    or info_count is None
                ):
                    continue
                ports = {}
                raw_ports = raw_info.get("ports", {})
                if isinstance(raw_ports, dict):
                    for raw_port, raw_port_count in list(raw_ports.items())[:MAX_PORTS_PER_IP]:
                        port = _clean_remote_port(raw_port)
                        port_count = _clean_count(raw_port_count)
                        if port is not None and port_count is not None:
                            ports[str(port)] = port_count
                player["ip_history"][ip] = {
                    "first_seen": info_first,
                    "last_seen": info_last,
                    "join_count": info_count,
                    "ports": ports,
                }
        if key in clean["players"]:
            clean["players"][key] = _merge_records(clean["players"][key], player)
        else:
            clean["players"][key] = player
    return clean


def aggregate_player_events(
    summary: dict[str, Any] | None,
    events: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    """Return one summary record per stable ID, or explicit name fallback."""
    result = _sanitize_summary(summary)

    for raw_event in events:
        event = _sanitize_event(raw_event)
        if event is None:
            continue
        if event.get("event") != "player_joined":
            continue
        player_id = event.get("player_id")
        player_name = event.get("player_name")
        key = _identity_key(player_id, player_name)
        if key is None:
            result["unidentified_join_count"] = min(
                MAX_COUNT,
                result["unidentified_join_count"] + 1,
            )
            continue

        players = result["players"]
        matching_ids = [
            candidate_key
            for candidate_key, candidate in players.items()
            if candidate_key.startswith("id:")
            and player_name
            and any(
                isinstance(name, str) and name.casefold() == player_name.casefold()
                for name in candidate.get("names_seen", [])
            )
        ]
        if player_id and player_name:
            fallback = f"name:{player_name.casefold()}"
            other_matching_ids = [candidate for candidate in matching_ids if candidate != key]
            if fallback in players and not other_matching_ids:
                fallback_record = players.pop(fallback)
                current_record = players.get(key)
                if current_record is None:
                    current_record = {
                        "player_id": player_id,
                        "join_count": 0,
                        "first_seen": event["timestamp"],
                        "last_seen": event["timestamp"],
                        "names_seen": [],
                        "last_ip": None,
                        "last_port": None,
                        "ip_history": {},
                    }
                players[key] = _merge_records(current_record, fallback_record)
        if not player_id:
            if len(matching_ids) == 1:
                key = matching_ids[0]

        if key not in players and len(players) >= MAX_PLAYERS:
            continue
        player = players.setdefault(
            key,
            {
                "player_id": player_id,
                "identity_source": "player_id" if player_id else "name",
                "names_seen": [],
                "first_seen": event["timestamp"],
                "last_seen": event["timestamp"],
                "join_count": 0,
                "last_ip": None,
                "last_port": None,
                "ip_history": {},
            },
        )
        if player_id:
            player["player_id"] = player_id
            player["identity_source"] = "player_id"
        if (
            player_name
            and player_name not in player["names_seen"]
            and len(player["names_seen"]) < MAX_NAMES_PER_PLAYER
        ):
            player["names_seen"].append(player_name)
        player["first_seen"] = _choose_timestamp(
            player["first_seen"], event["timestamp"], earliest=True
        )
        player["last_seen"] = _choose_timestamp(
            player["last_seen"], event["timestamp"], earliest=False
        )
        player["join_count"] = min(MAX_COUNT, player["join_count"] + 1)
        ip = event.get("remote_addr")
        if ip:
            player["last_ip"] = ip
            player["last_port"] = event.get("remote_port")
            if ip not in player["ip_history"] and len(player["ip_history"]) >= MAX_IPS_PER_PLAYER:
                continue
            info = player["ip_history"].setdefault(
                ip,
                {
                    "first_seen": event["timestamp"],
                    "last_seen": event["timestamp"],
                    "join_count": 0,
                    "ports": {},
                },
            )
            info["first_seen"] = _choose_timestamp(
                info["first_seen"], event["timestamp"], earliest=True
            )
            info["last_seen"] = _choose_timestamp(
                info["last_seen"], event["timestamp"], earliest=False
            )
            info["join_count"] = min(MAX_COUNT, info["join_count"] + 1)
            port = event.get("remote_port")
            if port is not None:
                port_key = str(port)
                ports = info.setdefault("ports", {})
                if port_key in ports or len(ports) < MAX_PORTS_PER_IP:
                    ports[port_key] = min(MAX_COUNT, ports.get(port_key, 0) + 1)

    result["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return result


def _summary_covers_events(summary: dict[str, Any], events: Iterable[dict[str, Any]]) -> bool:
    clean_summary = _sanitize_summary(summary)
    observed = aggregate_player_events({}, events)
    if clean_summary["unidentified_join_count"] < observed["unidentified_join_count"]:
        return False
    for key, observed_player in observed["players"].items():
        stored_player = clean_summary["players"].get(key)
        if not isinstance(stored_player, dict):
            return False
        if stored_player.get("join_count", 0) < observed_player.get("join_count", 0):
            return False
    return True


def _parse_timestamp(value: Any) -> datetime | None:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except (AttributeError, TypeError, ValueError):
        return None


def _canonical_timestamp(value: Any) -> str | None:
    parsed = _parse_timestamp(value)
    if parsed is None or parsed > datetime.now(timezone.utc) + timedelta(microseconds=MAX_FUTURE_TIMESTAMP_SKEW_US):
        return None
    return parsed.isoformat(timespec="seconds").replace("+00:00", "Z")


def _timestamps_ordered(first: str | None, last: str | None) -> bool:
    first_parsed = _parse_timestamp(first)
    last_parsed = _parse_timestamp(last)
    return first_parsed is not None and last_parsed is not None and first_parsed <= last_parsed


def _choose_timestamp(left: Any, right: Any, *, earliest: bool) -> str:
    values = [
        (value, parsed)
        for value in (left, right)
        if (parsed := _parse_timestamp(value)) is not None
    ]
    if not values:
        return ""
    chosen = (min if earliest else max)(values, key=lambda item: item[1])[0]
    return _canonical_timestamp(chosen) or ""


def _event_key(event: dict[str, Any]) -> str | None:
    event_id = event.get("event_id") or event.get("source_cursor")
    return str(event_id) if event_id else None


def _sanitize_state(state: Any) -> dict[str, Any]:
    if not isinstance(state, dict):
        return {}
    clean: dict[str, Any] = {}
    if state.get("initialized") is True:
        clean["initialized"] = True
    for field in ("last_cursor", "session_id"):
        value = _clean_identifier(state.get(field)) if field == "last_cursor" else _clean_session_id(state.get(field))
        if value is not None:
            clean[field] = value

    last_timestamp = state.get("last_realtime_timestamp_us")
    now_us = int(datetime.now(timezone.utc).timestamp() * 1_000_000)
    if (
        isinstance(last_timestamp, int)
        and not isinstance(last_timestamp, bool)
        and 0 <= last_timestamp <= now_us + MAX_FUTURE_TIMESTAMP_SKEW_US
    ):
        clean["last_realtime_timestamp_us"] = last_timestamp

    for field, limit in (("processed_cursors", 8192), ("processed_event_ids", 4096)):
        values = state.get(field, [])
        if not isinstance(values, list):
            continue
        unique = []
        for value in values:
            value = _clean_identifier(value)
            if value is not None and value not in unique:
                unique.append(value)
        clean[field] = unique[-limit:]
    if clean.get("last_cursor") and clean["last_cursor"] not in clean["processed_cursors"]:
        clean["processed_cursors"] = [
            *clean["processed_cursors"][-8191:],
            clean["last_cursor"],
        ]

    active: dict[str, Any] = {}
    raw_active = state.get("active_connections", {})
    if isinstance(raw_active, dict):
        for value in list(raw_active.values())[:MAX_ACTIVE_CONNECTIONS]:
            if not isinstance(value, dict):
                continue
            address = _clean_remote_addr(value.get("remote_addr"))
            if address is None:
                continue
            port = _clean_remote_port(value.get("remote_port"))
            player_id = _clean_identifier(value.get("player_id"))
            if player_id is not None and len(player_id) > 256:
                player_id = None
            player_name = _clean_player_name(value.get("player_name"))
            active[_endpoint_key((address, port))] = {
                "player_id": player_id,
                "player_name": player_name,
                "remote_addr": address,
                "remote_port": port,
                "identity_key": _identity_key(player_id, player_name),
            }
    clean["active_connections"] = active

    pending = []
    raw_pending = state.get("pending_connections", [])
    if isinstance(raw_pending, list):
        for item in raw_pending:
            if not isinstance(item, dict):
                continue
            address = _clean_remote_addr(item.get("address"))
            timestamp = _canonical_timestamp(item.get("timestamp"))
            if address is None or timestamp is None:
                continue
            pending.append({
                "address": address,
                "port": _clean_remote_port(item.get("port")),
                "timestamp": timestamp,
            })
    clean["pending_connections"] = pending[-32:]
    return clean



class BackupInProgress(RuntimeError):
    pass


def _lock_exclusive(fd: int) -> None:
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise BackupInProgress("player-log is locked by a backup; skipping this run") from None
            time.sleep(0.5)

class PlayerLog:
    def __init__(self, root: Path, retention_days: int = 90) -> None:
        if isinstance(retention_days, bool) or not isinstance(retention_days, int):
            raise ValueError("retention_days must be an integer")
        if not 0 <= retention_days <= MAX_RETENTION_DAYS:
            raise ValueError(f"retention_days must be between 0 and {MAX_RETENTION_DAYS}")
        self.root = Path(root)
        self.retention_days = retention_days
        self.events_path = self.root / "events.jsonl"
        self.players_path = self.root / "players.json"
        self.state_path = self.root / "state.json"
        self.transaction_path = self.root / ".transaction.json"
        self.lock_path = self.root / ".backup.lock"
        try:
            root_stat = os.lstat(self.root)
        except FileNotFoundError:
            self.root.mkdir(parents=True, exist_ok=False)
            root_stat = os.lstat(self.root)
        if not stat.S_ISDIR(root_stat.st_mode):
            raise RuntimeError(f"player-log root is not a directory: {self.root}")
        os.chmod(self.root, 0o2750)
        with self._open_lock() as lock:
            _lock_exclusive(lock.fileno())
            try:
                self._recover_transaction()
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def load_state(self) -> dict[str, Any]:
        try:
            serialized = _read_regular_text(self.state_path, MAX_STATE_FILE_BYTES)
            if serialized is None:
                return {}
            value = json.loads(serialized)
            if not isinstance(value, dict):
                raise RuntimeError(f"invalid player-log state: {self.state_path}")
            allowed = {
                "initialized",
                "last_cursor",
                "session_id",
                "last_realtime_timestamp_us",
                "processed_cursors",
                "processed_event_ids",
                "active_connections",
                "pending_connections",
                "pending_addresses",
            }
            clean_state = _sanitize_state(value)
            if not (
                clean_state.get("last_cursor")
                or clean_state.get("processed_cursors")
                or clean_state.get("processed_event_ids")
                or clean_state.get("last_realtime_timestamp_us")
                or clean_state.get("initialized") is True
            ):
                raise RuntimeError(f"incomplete player-log state: {self.state_path}")
            return clean_state
        except FileNotFoundError:
            return {}
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid player-log state: {self.state_path}") from error

    def _load_summary(self) -> dict[str, Any]:
        try:
            serialized = _read_regular_text(self.players_path, MAX_SUMMARY_FILE_BYTES)
            if serialized is None:
                return {}
            value = json.loads(serialized)
        except FileNotFoundError:
            return {}
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid player-log summary: {self.players_path}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"invalid player-log summary: {self.players_path}")
        return value

    def _load_events(self) -> list[dict[str, Any]]:
        if not _regular_exists(self.events_path):
            return []
        events = deque(maxlen=MAX_STORED_EVENTS)
        seen_keys = set()
        fd = _open_regular(self.events_path, os.O_RDONLY)
        with os.fdopen(fd, "r", encoding="utf-8") as handle:
            if os.fstat(handle.fileno()).st_size > MAX_EVENT_FILE_BYTES:
                raise RuntimeError(f"player-log events are too large: {self.events_path}")
            for line in handle:
                if len(line) > MAX_JOURNAL_OUTPUT_BYTES:
                    raise RuntimeError(f"player-log event line is too large: {self.events_path}")
                try:
                    value = json.loads(line)
                except json.JSONDecodeError as error:
                    raise RuntimeError(f"invalid player-log event: {self.events_path}") from error
                clean_value = _sanitize_event(value, require_key=True)
                if clean_value is None:
                    raise RuntimeError(f"invalid player-log event: {self.events_path}")
                key = _event_key(clean_value)
                if key is not None and key in seen_keys:
                    continue
                if key is not None:
                    if len(seen_keys) >= MAX_STORED_EVENTS:
                        seen_keys.clear()
                    seen_keys.add(key)
                events.append(clean_value)
        return list(events)

    def commit(self, events: Iterable[dict[str, Any]], state: dict[str, Any]) -> None:
        with self._open_lock() as lock:
            _lock_exclusive(lock.fileno())
            try:
                self._commit_locked(events, state)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _commit_locked(self, events: Iterable[dict[str, Any]], state: dict[str, Any]) -> None:
        self._recover_transaction()
        prior_state = self.load_state()
        events_exists = _regular_exists(self.events_path)
        existing = self._load_events()
        known = {
            key for key in (_event_key(event) for event in existing)
            if key is not None
        }
        known.update(prior_state.get("processed_event_ids", []))
        combined = existing[:]
        new_events = []
        for event_index, raw_event in enumerate(events):
            if event_index >= MAX_JOURNAL_RECORDS:
                raise RuntimeError("event record limit exceeded")
            event = _sanitize_event(raw_event, require_key=True)
            if event is None:
                continue
            key = _event_key(event)
            if key not in known:
                combined.append(event)
                if key is not None:
                    known.add(key)
                new_events.append(event)

        now = datetime.now(timezone.utc)
        cutoff = now - timedelta(days=self.retention_days)
        combined = [
            event for event in combined
            if (_parse_timestamp(event.get("timestamp")) or now) >= cutoff
        ]
        combined = combined[-MAX_STORED_EVENTS:]
        summary_exists = _regular_exists(self.players_path)
        prior_summary = self._load_summary()
        if summary_exists and not events_exists:
            raise RuntimeError("player-log events are missing; refusing partial history")
        clean_prior_summary = _sanitize_summary(prior_summary)
        summary_is_usable = (
            summary_exists
            and prior_summary == clean_prior_summary
            and prior_summary.get("schema") == SCHEMA
            and isinstance(prior_summary.get("players"), dict)
            and _clean_count(prior_summary.get("unidentified_join_count")) is not None
            and _canonical_timestamp(prior_summary.get("updated")) is not None
        )
        if summary_exists and not summary_is_usable:
            raise RuntimeError("player-log summary is malformed or incomplete")
        if not summary_is_usable and not existing and (
            prior_state.get("last_cursor")
            or prior_state.get("processed_cursors")
            or prior_state.get("processed_event_ids")
            or prior_state.get("last_realtime_timestamp_us")
        ):
            raise RuntimeError("player-log summary and retained events are missing; refusing data loss")
        new_keys = {_event_key(event) for event in new_events}
        retained_existing = [
            event for event in combined if _event_key(event) not in new_keys
        ]
        if summary_is_usable and not _summary_covers_events(prior_summary, retained_existing):
            raise RuntimeError("player-log summary is inconsistent with retained events")
        if summary_is_usable:
            summary = aggregate_player_events(prior_summary, new_events)
        else:
            summary = aggregate_player_events({}, [*retained_existing, *new_events])
        next_state = _sanitize_state(state)
        next_state["initialized"] = True
        processed = list(prior_state.get("processed_event_ids", []))
        processed.extend(
            key for key in (_event_key(event) for event in new_events)
            if key is not None
        )
        next_state["processed_event_ids"] = processed[-4096:]

        temp_files = {
            "events": self.root / ".transaction.events.jsonl.tmp",
            "players": self.root / ".transaction.players.json.tmp",
            "state": self.root / ".transaction.state.json.tmp",
        }
        self._write_lines_temp(temp_files["events"], combined, 0o640)
        self._write_json_temp(temp_files["players"], summary, 0o640)
        self._write_json_temp(temp_files["state"], next_state, 0o600)
        marker_temp = self.root / ".transaction.json.tmp"
        marker = {
            "schema": SCHEMA,
            "files": {
                key: {"sha256": self._file_digest(path)}
                for key, path in temp_files.items()
            },
        }
        self._write_json_temp(marker_temp, marker, 0o600)
        os.replace(str(marker_temp), str(self.transaction_path))
        self._sync_directory()

        for key, target, mode in (
            ("events", self.events_path, 0o640),
            ("players", self.players_path, 0o640),
            ("state", self.state_path, 0o600),
        ):
            os.replace(str(temp_files[key]), str(target))
            _chmod_regular(target, mode)
            self._sync_directory()

        self.transaction_path.unlink()
        self._sync_directory()

    def _open_lock(self):
        fd = _open_regular(self.lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            return os.fdopen(fd, "r+")
        except BaseException:
            os.close(fd)
            raise

    def _recover_transaction(self) -> None:
        if not _regular_exists(self.transaction_path):
            return
        try:
            serialized = _read_regular_text(self.transaction_path, MAX_TRANSACTION_MARKER_BYTES)
            if serialized is None:
                return
            marker = json.loads(serialized)
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"invalid player-log transaction: {self.transaction_path}") from error
        if not isinstance(marker, dict) or marker.get("schema") != SCHEMA:
            raise RuntimeError(f"unsupported player-log transaction: {self.transaction_path}")

        temp_files = {
            "events": (self.root / ".transaction.events.jsonl.tmp", self.events_path, 0o640),
            "players": (self.root / ".transaction.players.json.tmp", self.players_path, 0o640),
            "state": (self.root / ".transaction.state.json.tmp", self.state_path, 0o600),
        }
        file_metadata = marker.get("files")
        if not isinstance(file_metadata, dict) or set(file_metadata) != set(temp_files):
            raise RuntimeError(f"invalid player-log transaction: {self.transaction_path}")

        for key, (temp, target, _) in temp_files.items():
            metadata = file_metadata.get(key)
            if not isinstance(metadata, dict) or set(metadata) != {"sha256"}:
                raise RuntimeError(f"invalid player-log transaction: {self.transaction_path}")
            expected_digest = metadata["sha256"]
            if not isinstance(expected_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
                raise RuntimeError(f"invalid player-log transaction: {self.transaction_path}")
            file_limit = {
                "events": MAX_EVENT_FILE_BYTES,
                "players": MAX_SUMMARY_FILE_BYTES,
                "state": MAX_STATE_FILE_BYTES,
            }[key]
            temp_exists = _regular_exists(temp)
            target_exists = _regular_exists(target)
            if temp_exists:
                if self._file_digest(temp, file_limit) != expected_digest:
                    raise RuntimeError(f"corrupt player-log transaction: {self.transaction_path}")
            elif target_exists and self._file_digest(target, file_limit) == expected_digest:
                continue
            else:
                raise RuntimeError(f"incomplete player-log transaction: {self.transaction_path}")

        for temp, target, mode in temp_files.values():
            if _regular_exists(temp):
                os.replace(str(temp), str(target))
            elif not _regular_exists(target):
                raise RuntimeError(f"incomplete player-log transaction: {self.transaction_path}")
            _chmod_regular(target, mode)
        self.transaction_path.unlink()
        self._sync_directory()

    @staticmethod
    def _write_json_temp(path: Path, value: Any, mode: int) -> None:
        serialized = json.dumps(value, indent=2, sort_keys=True) + "\n"
        if "players" in path.name:
            limit = MAX_SUMMARY_FILE_BYTES
        elif "state" in path.name:
            limit = MAX_STATE_FILE_BYTES
        else:
            limit = 1 * 1024 * 1024
        if len(serialized.encode("utf-8")) > limit:
            raise RuntimeError(f"player-log JSON size limit exceeded: {path}")
        fd = _open_regular(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)

    @staticmethod
    def _write_lines_temp(path: Path, values: Iterable[dict[str, Any]], mode: int) -> None:
        total_bytes = 0
        fd = _open_regular(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            for value in values:
                line = json.dumps(value, sort_keys=True) + "\n"
                total_bytes += len(line.encode("utf-8"))
                if total_bytes > MAX_EVENT_FILE_BYTES:
                    raise RuntimeError("player-log events size limit exceeded")
                handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchmod(handle.fileno(), mode)

    @staticmethod
    def _file_digest(path: Path, limit: int | None = None) -> str:
        digest = hashlib.sha256()
        total_bytes = 0
        fd = _open_regular(path, os.O_RDONLY)
        with os.fdopen(fd, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                total_bytes += len(chunk)
                if limit is not None and total_bytes > limit:
                    raise RuntimeError(f"player-log transaction file is too large: {path}")
                digest.update(chunk)
        return digest.hexdigest()

    def _sync_directory(self) -> None:
        try:
            fd = os.open(
                self.root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
            )
        except OSError as error:
            raise RuntimeError(f"cannot safely sync player-log directory: {self.root}") from error
        try:
            if not stat.S_ISDIR(os.fstat(fd).st_mode):
                raise RuntimeError(f"player-log root is not a directory: {self.root}")
            os.fsync(fd)
        finally:
            os.close(fd)


def _systemd_property(unit: str, property_name: str) -> str:
    try:
        returncode, stdout, _ = _run_capped(
            ["systemctl", "show", unit, f"--property={property_name}", "--value"],
            stdout_limit=MAX_SYSTEMD_PROPERTY_BYTES,
        )
    except (OSError, RuntimeError):
        return ""
    return stdout.strip() if returncode == 0 else ""


def _normalize_active_enter(value: str) -> str:
    normalized = value.strip()
    if not normalized or normalized.lower() in {"n/a", "na", "unknown", "-", "0"}:
        return ""
    if re.search(r"\b1970-01-01 00:00:00(?:\.0+)?\b", normalized):
        return ""
    return normalized


def _normalize_invocation_id(value: str) -> str:
    normalized = value.strip().lower()
    return normalized if re.fullmatch(r"[0-9a-f]{32}", normalized) else ""


def _normalize_boot_id(value: str) -> str:
    normalized = value.strip().lower()
    return (
        normalized
        if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", normalized)
        else ""
    )


def _boot_id() -> str:
    try:
        return _normalize_boot_id(Path("/proc/sys/kernel/random/boot_id").read_text())
    except OSError:
        return ""


def _decode_journal(output: str) -> list[dict[str, Any]]:
    if len(output.encode("utf-8", errors="replace")) > MAX_JOURNAL_OUTPUT_BYTES:
        raise RuntimeError("journal output limit exceeded")
    records = []
    for line_index, line in enumerate(output.splitlines()):
        if line_index >= MAX_JOURNAL_RECORDS:
            raise RuntimeError("journal record limit exceeded")
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid journal JSON at line {line_index + 1}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"invalid journal record at line {line_index + 1}")
        records.append(value)
    return records


def _run_capped(
    command: list[str],
    *,
    stdout_limit: int = MAX_JOURNAL_OUTPUT_BYTES,
    stderr_limit: int = MAX_COMMAND_ERROR_BYTES,
) -> tuple[int, str, str]:
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if process.stdout is None or process.stderr is None:
        process.kill()
        process.wait()
        raise RuntimeError("journal command pipes unavailable")
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    output = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": stdout_limit, "stderr": stderr_limit}
    try:
        while selector.get_map():
            for key, _ in selector.select():
                chunk = os.read(key.fd, 64 * 1024)
                stream = key.data
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output[stream].extend(chunk)
                if len(output[stream]) > limits[stream]:
                    process.kill()
                    process.wait()
                    raise RuntimeError(f"journal {stream} limit exceeded")
    finally:
        selector.close()
    returncode = process.wait()
    return (
        returncode,
        bytes(output["stdout"]).decode("utf-8", errors="replace"),
        bytes(output["stderr"]).decode("utf-8", errors="replace"),
    )


def _journal(unit: str, cursor: str, since: str) -> tuple[list[dict[str, Any]], bool]:
    command = ["journalctl", "-u", unit, "--no-pager", "-o", "json"]
    if cursor:
        command.extend(["--after-cursor", cursor])
    elif since:
        command.extend(["--since", since])
    returncode, stdout, stderr = _run_capped(command)
    if returncode == 0:
        return _decode_journal(stdout), False
    if not cursor:
        raise RuntimeError(stderr.strip() or "journalctl failed")

    recovery_command = ["journalctl", "-u", unit, "--no-pager", "-o", "json"]
    if since:
        recovery_command.extend(["--since", since])
    recovery_code, recovery_stdout, recovery_stderr = _run_capped(recovery_command)
    if recovery_code != 0:
        raise RuntimeError(recovery_stderr.strip() or stderr.strip() or "journalctl failed")
    return _decode_journal(recovery_stdout), True


def _server_build(install_dir: Path) -> str:
    manifest = install_dir / "steamapps" / "appmanifest_4019830.acf"
    try:
        content = _read_regular_text(manifest, MAX_MANIFEST_BYTES)
    except (OSError, RuntimeError, UnicodeDecodeError):
        return ""
    if content is None:
        return ""
    match = re.search(r'"buildid"\s+"([0-9]+)"', content)
    return match.group(1) if match else ""


def _session_id(active_enter: str, invocation_id: str = "", boot_id: str = "") -> str:
    normalized_invocation = _normalize_invocation_id(invocation_id)
    normalized_boot = _normalize_boot_id(boot_id)
    if not normalized_invocation:
        raise RuntimeError("stable systemd invocation identity unavailable")
    parts = [value for value in (active_enter, normalized_invocation, normalized_boot) if value]
    digest = hashlib.sha256("\x00".join(parts).encode("utf-8")).hexdigest()[:32]
    return f"session:{digest}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--unit", default="dragonwilds.service")
    parser.add_argument("--install-dir", required=True)
    parser.add_argument("--data-dir", default="/var/lib/dragonwilds/player-log")
    parser.add_argument("--retention-days", type=int, default=90)
    args = parser.parse_args()

    log = PlayerLog(Path(args.data_dir), retention_days=args.retention_days)
    state_was_missing = not _regular_exists(log.state_path)
    summary_was_present = _regular_exists(log.players_path)
    if state_was_missing and summary_was_present:
        raise RuntimeError("player-log state is missing; refusing unsafe journal replay")
    state = log.load_state()
    active_enter = _normalize_active_enter(_systemd_property(args.unit, "ActiveEnterTimestamp"))
    invocation_id = _systemd_property(args.unit, "InvocationID")
    session_id = _session_id(active_enter, invocation_id, _boot_id())
    records, cursor_recovered = _journal(
        args.unit,
        state.get("last_cursor", ""),
        active_enter or "now",
    )
    if cursor_recovered:
        records = _filter_recovered_records(records, state, session_id)
    events, state = parse_journal_records(
        records,
        state,
        session_id=session_id,
        server_build=_server_build(Path(args.install_dir)),
    )
    log.commit(events, state)
    print(f"player-log: processed {len(records)} journal records, wrote {len(events)} events")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BackupInProgress as error:
        print(f"player-log: {error}")
        raise SystemExit(0)
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
