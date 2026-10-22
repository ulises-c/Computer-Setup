#!/usr/bin/env python3
"""Upload only the botting files used by wiki curation."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile


OBSERVATIONS = {f"observations/{name}.tsv" for name in
                ("items", "locs", "npcs", "ground-items", "shops")}


@contextmanager
def directory(path, create=False):
    path = Path(path).expanduser().absolute()
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:]:
            if part == "..":
                raise ValueError("parent traversal is not allowed")
            if create:
                try:
                    os.mkdir(part, mode=0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    finally:
        os.close(fd)


def pack(root, output):
    count = 0
    total = 0

    def add(archive, info, source=None):
        nonlocal count, total
        count += 1
        total += info.size
        if count > MAX_COUNT or total > MAX_TOTAL:
            raise ValueError("source snapshot limit exceeded")
        archive.addfile(info, source)

    def add_directory(archive, name):
        info = tarfile.TarInfo(name)
        info.type = tarfile.DIRTYPE
        info.mode = 0o700
        add(archive, info)

    def add_file(archive, fd, name, relative):
        opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        with os.fdopen(opened, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError("source is not a regular file")
            if metadata.st_size > MAX_FILE:
                raise ValueError("source file size limit exceeded")
            info = tarfile.TarInfo(relative)
            info.size = metadata.st_size
            info.mtime = metadata.st_mtime
            info.mode = 0o600
            add(archive, info, source)

    def walk(archive, fd, prefix):
        for name in sorted(os.listdir(fd)):
            metadata = os.stat(name, dir_fd=fd, follow_symlinks=False)
            relative = prefix + "/" + name
            if stat.S_ISDIR(metadata.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    add_directory(archive, relative)
                    walk(archive, child, relative)
                finally:
                    os.close(child)
            elif not stat.S_ISREG(metadata.st_mode):
                raise ValueError("nonregular source entry")
            elif name.endswith(".md"):
                add_file(archive, fd, name, relative)

    with directory(root) as root_fd:
        observations = os.open("observations", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            learnings = os.open("learnings", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            try:
                with tarfile.open(fileobj=output, mode="w|", format=tarfile.PAX_FORMAT) as archive:
                    add_directory(archive, "observations")
                    add_directory(archive, "learnings")
                    for name in sorted(OBSERVATIONS):
                        leaf = name.split("/")[1]
                        try:
                            os.stat(leaf, dir_fd=observations, follow_symlinks=False)
                        except FileNotFoundError:
                            continue
                        add_file(archive, observations, leaf, name)
                    walk(archive, learnings, "learnings")
            finally:
                os.close(learnings)
        finally:
            os.close(observations)


MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MAX_COUNT = 10000
MAX_ARCHIVE = 96 * 1024 * 1024


def extract(stream, stage):
    seen = set()
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            name = member.name
            parts = name.split("/")
            if any(part in ("", ".", "..") for part in parts):
                raise ValueError("unsafe member path")
            if name in seen or len(seen) >= MAX_COUNT:
                raise ValueError("duplicate member or too many members")
            seen.add(name)
            allowed_dir = name in ("observations", "learnings") or name.startswith("learnings/")
            allowed_file = name in OBSERVATIONS or name == "manifest.json" or (
                name.startswith("learnings/") and name.endswith(".md"))
            if not ((member.isdir() and allowed_dir) or (member.isreg() and allowed_file)):
                raise ValueError("member is not allowlisted")
            if member.size < 0 or member.size > MAX_FILE or member.sparse is not None:
                raise ValueError("invalid member size or sparse member")
            total += member.size
            if total > MAX_TOTAL or (member.isdir() and member.size):
                raise ValueError("archive payload limit exceeded")
            path = stage / name
            if member.isdir():
                path.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with archive.extractfile(member) as source, path.open("xb") as dest:
                    os.chmod(path, 0o600)
                    remaining = member.size
                    while remaining:
                        chunk = source.read(min(65536, remaining))
                        if not chunk:
                            raise ValueError("truncated member")
                        dest.write(chunk)
                        remaining -= len(chunk)
                os.utime(path, (member.mtime, member.mtime))
        stream.seek(archive.offset)
        if stream.read(1024) != b"\0" * 1024:
            raise ValueError("missing archive terminator after members")
    if not {"observations", "learnings"} <= seen:
        raise ValueError("required directories missing")
    if not all((stage / name).is_dir() for name in ("observations", "learnings")):
        raise ValueError("invalid required directories")


def receive(stream, target):
    target = Path(target).expanduser().absolute()
    with directory(target, create=True) as fd:
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK
        try:
            lock = os.open(".lock", flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=fd)
        except FileExistsError:
            lock = os.open(".lock", flags, dir_fd=fd)
        with os.fdopen(lock, "r+b") as held:
            if not stat.S_ISREG(os.fstat(held.fileno()).st_mode):
                raise ValueError("invalid lock file")
            fcntl.flock(held, fcntl.LOCK_EX)
            publish(stream, target)


def publish(stream, target):
    stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=target))
    link = target / (stage.name + ".current")
    try:
        with tempfile.TemporaryFile() as incoming:
            size = 0
            while True:
                chunk = stream.read(min(65536, MAX_ARCHIVE + 1 - size))
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_ARCHIVE:
                    raise ValueError("archive wire limit exceeded")
                incoming.write(chunk)
            if size < 1024 or size % 512:
                raise ValueError("truncated archive")
            incoming.seek(-1024, os.SEEK_END)
            if incoming.read() != b"\0" * 1024:
                raise ValueError("missing archive terminator")
            incoming.seek(0)
            extract(incoming, stage)
        digest = hashlib.sha256()
        for path in sorted(stage.rglob("*")):
            digest.update(str(path.relative_to(stage)).encode() + b"\0")
            digest.update(b"d" if path.is_dir() else b"f")
            if path.is_file():
                data = path.read_bytes()
                digest.update(len(data).to_bytes(8, "big"))
                digest.update(data)
        generation = target / ("generation-" + digest.hexdigest())
        if generation.is_symlink() or (generation.exists() and not generation.is_dir()):
            raise ValueError("invalid existing generation")
        if not generation.exists():
            stage.rename(generation)
        link.symlink_to(generation.name)
        os.replace(link, target / "current")
    finally:
        link.unlink(missing_ok=True)
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    push = commands.add_parser("push")
    push.add_argument("--host", required=True, help="SSH config alias")
    push.add_argument("--botting-root", default="~/forgejo/2004Scape-Botting")
    push.add_argument("--receiver", default="github/Computer-Setup/linux-game-server/rs-sdk/wiki/inputs.py")
    receiver = commands.add_parser("receive")
    receiver.add_argument("--target", default="~/.local/share/rs-sdk-wiki/inputs")
    args = parser.parse_args()
    try:
        if args.command == "receive":
            receive(sys.stdin.buffer, args.target)
        else:
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.host):
                raise ValueError("host must be an SSH config alias")
            remote_path = args.receiver
            if remote_path.startswith("~/"):
                remote_path = remote_path[2:]
            remote = shlex.quote(remote_path)
            if not remote_path.startswith("/"):
                remote = '"$HOME"/' + remote
            with tempfile.TemporaryFile() as outgoing:
                pack(args.botting_root, outgoing)
                outgoing.seek(0)
                subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", args.host,
                                "python3 " + remote + " receive"],
                               stdin=outgoing, check=True)
    except (OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
