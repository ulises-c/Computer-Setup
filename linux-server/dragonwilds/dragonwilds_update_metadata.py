#!/usr/bin/env python3
"""Read Dragonwilds Steam build and Linux-depot manifest metadata."""

import re
import sys
from pathlib import Path
from typing import Any, Optional

APP_ID = "4019830"
LINUX_DEPOT_ID = "3501791"
_ID = re.compile(r"^[0-9]+$")
_TOKEN = re.compile(r'//[^\r\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]|[^\s{}"]+', re.S)


def _decode(token: str) -> str:
    # Steam VDF strings are not guaranteed to use JSON-compatible escapes.
    # The fields we key on contain no escapes, and retaining raw string contents
    # avoids rejecting unrelated Windows paths or descriptions in app metadata.
    return token[1:-1] if token.startswith('"') else token


def _object(tokens: list[str], opening: int) -> tuple[dict[str, Any], int]:
    if tokens[opening] != "{":
        raise ValueError("expected VDF object")
    result: dict[str, Any] = {}
    index = opening + 1
    while index < len(tokens) and tokens[index] != "}":
        key = _decode(tokens[index])
        index += 1
        if index >= len(tokens) or tokens[index] == "}":
            raise ValueError("missing VDF value")
        if tokens[index] == "{":
            value, index = _object(tokens, index)
            result[key] = value
        else:
            result[key] = _decode(tokens[index])
            index += 1
    if index >= len(tokens):
        raise ValueError("unterminated VDF object")
    return result, index + 1


def _tokens(text: str) -> list[str]:
    without_block_comments = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    if "/*" in without_block_comments:
        raise ValueError("unterminated VDF comment")
    return [token for token in _TOKEN.findall(without_block_comments)
            if not token.startswith("//")]


def _named_object(text: str, name: str) -> dict[str, Any]:
    tokens = _tokens(text)
    for index in range(len(tokens) - 1):
        if _decode(tokens[index]) == name and tokens[index + 1] == "{":
            value, _ = _object(tokens, index + 1)
            return value
    raise ValueError(f"VDF object {name!r} not found")


def _valid_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError(f"missing or invalid {field}")
    return value


def public_build_info(text: str, app_id: str = APP_ID,
                      depot_id: str = LINUX_DEPOT_ID) -> tuple[str, str]:
    """Return (public app BuildID, public Linux depot manifest GID)."""
    app = _named_object(text, app_id)
    build = _valid_id(app["branches"]["public"]["buildid"], "public branch buildid")
    manifest = _valid_id(
        app["depots"][depot_id]["manifests"]["public"]["gid"],
        f"public depot {depot_id} manifest GID",
    )
    return build, manifest


def installed_build_info(text: str, depot_id: str = LINUX_DEPOT_ID) -> tuple[str, str]:
    """Return (installed app BuildID, installed Linux depot manifest GID)."""
    app = _named_object(text, "AppState")
    build = _valid_id(app["buildid"], "installed app buildid")
    manifest = _valid_id(
        app["InstalledDepots"][depot_id]["manifest"],
        f"installed depot {depot_id} manifest GID",
    )
    return build, manifest


def needs_update(installed_manifest: str, latest_manifest: str) -> Optional[bool]:
    """Return depot-content drift; None means insufficient data, fail closed."""
    if not _ID.fullmatch(installed_manifest or "") or not _ID.fullmatch(latest_manifest or ""):
        return None
    return installed_manifest != latest_manifest


def update_status(installed_manifest: str, latest_manifest: str, app_build: str) -> str:
    pending = needs_update(installed_manifest, latest_manifest)
    if pending is None:
        return "unknown"
    if not pending:
        return "up to date"
    if not _ID.fullmatch(app_build or ""):
        return "unknown"
    return f"update available ({app_build})"


def main(argv: list[str]) -> int:
    try:
        if argv == ["steam"]:
            print(*public_build_info(sys.stdin.read()))
        elif len(argv) == 2 and argv[0] == "installed":
            print(*installed_build_info(Path(argv[1]).read_text()))
        elif len(argv) == 4 and argv[0] == "status":
            print(update_status(argv[1], argv[2], argv[3]))
        elif len(argv) == 3 and argv[0] == "needs-update":
            result = needs_update(argv[1], argv[2])
            print("unknown" if result is None else ("yes" if result else "no"))
        else:
            print(
                "usage: dragonwilds_update_metadata.py steam|installed FILE|status INSTALLED_GID LATEST_GID APP_BUILD|needs-update INSTALLED_GID LATEST_GID",
                file=sys.stderr,
            )
            return 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
