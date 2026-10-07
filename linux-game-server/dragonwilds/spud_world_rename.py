#!/usr/bin/env python3
import argparse
import hashlib
import os
from pathlib import Path
import re
import struct
import sys

MAX_SAVE_BYTES = 256 * 1024 * 1024
MAX_FSTRING_BYTES = 4096
MAX_ENTRIES = 65536

NO_ID = 0xFFFFFFFF
STORAGE_GUID = 23
STORAGE_STRING = 30

WORLD_PREFIX = "WorldSaveSettings"
PROP_WORLD_NAME = WORLD_PREFIX + "/WorldName"
PROP_WORLD_SLOT = WORLD_PREFIX + "/WorldSlotName"
PROP_WORLD_GUID = WORLD_PREFIX + "/WorldSaveGuid"
CINF_GUID_PARTS = ("GUID_A", "GUID_B", "GUID_C", "GUID_D")

NAME_PATTERN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{0,31}")

U16 = struct.Struct("<H")
U32 = struct.Struct("<I")
I32 = struct.Struct("<i")


class SpudFormatError(ValueError):
    pass


def fail(message):
    raise SpudFormatError(message)


def read_chunk_header(data, pos, end):
    if end - pos < 8:
        fail(f"truncated chunk header at offset {pos}")
    raw_tag = bytes(data[pos:pos + 4])
    if not all(0x20 <= c < 0x7F for c in raw_tag):
        fail(f"invalid chunk tag at offset {pos}")
    chunk_end = pos + 8 + read_u32(data, pos + 4, end, "chunk length")
    if chunk_end > end:
        fail(f"chunk {raw_tag.decode('ascii')} at offset {pos} overruns its parent")
    return raw_tag.decode("ascii"), pos + 8, chunk_end


def read_chunks(data, start, end):
    chunks, pos = [], start
    while pos < end:
        if len(chunks) >= MAX_ENTRIES:
            fail("too many child chunks")
        tag, body, chunk_end = read_chunk_header(data, pos, end)
        chunks.append((tag, pos, body, chunk_end))
        pos = chunk_end
    return chunks


def read_u32(data, pos, end, what):
    if end - pos < 4:
        fail(f"{what} is truncated")
    return U32.unpack_from(data, pos)[0]


def read_fstring(data, pos, end):
    if end - pos < 4:
        fail(f"truncated string at offset {pos}")
    length = I32.unpack_from(data, pos)[0]
    if length < 0:
        fail(f"UTF-16 string at offset {pos} is not supported")
    if length > MAX_FSTRING_BYTES or pos + 4 + length > end:
        fail(f"string at offset {pos} overruns its container")
    if length == 0:
        return "", pos + 4
    raw = bytes(data[pos + 4:pos + 4 + length])
    if raw[-1] != 0 or not all(0x20 <= c < 0x7F for c in raw[:-1]):
        fail(f"string at offset {pos} is not NUL-terminated printable ASCII")
    return raw[:-1].decode("ascii"), pos + 4 + length


def encode_fstring(text):
    raw = text.encode("ascii") + b"\0"
    return I32.pack(len(raw)) + raw


def decode_exact_fstring(raw, what):
    text, pos = read_fstring(raw, 0, len(raw))
    if pos != len(raw):
        fail(f"{what} is not exactly one string")
    return text


def read_string_array(data, start, end, what):
    count = read_u32(data, start, end, what)
    pos, values = start + 4, []
    for _ in range(count):
        text, pos = read_fstring(data, pos, end)
        values.append(text)
    if pos != end:
        fail(f"{what} has trailing bytes")
    return values


def read_offset_table(data, pos, end, what):
    count = read_u32(data, pos, end, f"{what} offset table")
    if count > MAX_ENTRIES or pos + 8 + 4 * count > end:
        fail(f"{what} offset table overruns its chunk")
    offsets = [U32.unpack_from(data, pos + 4 + 4 * i)[0] for i in range(count)]
    size_pos = pos + 4 + 4 * count
    size = U32.unpack_from(data, size_pos)[0]
    data_start = size_pos + 4
    if data_start + size != end:
        fail(f"{what} data length does not match its chunk")
    if offsets and offsets[0] != 0:
        fail(f"{what} first property offset is not zero")
    if any(a > b for a, b in zip(offsets, offsets[1:])) or (offsets and offsets[-1] > size):
        fail(f"{what} property offsets are not monotonic")
    bounds = offsets + [size]
    slices = [bytes(data[data_start + bounds[i]:data_start + bounds[i + 1]]) for i in range(count)]
    return slices, [data_start + o for o in offsets]


def build_offset_table(slices):
    offsets, position = [], 0
    for item in slices:
        offsets.append(position)
        position += len(item)
    return (U32.pack(len(slices)) + b"".join(U32.pack(o) for o in offsets)
            + U32.pack(position) + b"".join(slices))


def build_chunk(tag, body):
    if len(body) > 0xFFFFFFFF:
        fail(f"chunk {tag} is too large")
    return tag.encode("ascii") + U32.pack(len(body)) + body


class Raw:
    def __init__(self, data):
        self.data = bytes(data)

    def to_bytes(self):
        return self.data


class Container:
    def __init__(self, tag, prefix, children):
        self.tag = tag
        self.prefix = prefix
        self.children = children

    def to_bytes(self):
        return build_chunk(self.tag, self.prefix + b"".join(child.to_bytes() for child in self.children))


class SlicedChunk:
    def __init__(self, tag, head, slices, starts):
        self.tag = tag
        self.head = head
        self.slices = slices
        self.starts = starts

    def to_bytes(self):
        return build_chunk(self.tag, self.head + build_offset_table(self.slices))


class ClassDef:
    def __init__(self, name, properties):
        self.name = name
        self.properties = properties

    def find(self, path):
        matches = [i for i, (candidate, _) in enumerate(self.properties) if candidate == path]
        if len(matches) > 1:
            fail(f"class {self.name} defines {path} more than once")
        return matches[0] if matches else None


def parse_metadata(data, start, end):
    children = read_chunks(data, start, end)
    wanted = {}
    for tag, pos, body, chunk_end in children:
        if tag in ("CNIX", "CLST", "PNIX"):
            if tag in wanted:
                fail(f"metadata has more than one {tag}")
            wanted[tag] = (pos, body, chunk_end)
    for tag in ("CNIX", "CLST", "PNIX"):
        if tag not in wanted:
            fail(f"metadata has no {tag}")
    class_names = read_string_array(data, wanted["CNIX"][1], wanted["CNIX"][2], "class name index")
    property_names = read_string_array(data, wanted["PNIX"][1], wanted["PNIX"][2], "property name index")
    classes = []
    for tag, pos, body, chunk_end in read_chunks(data, wanted["CLST"][1], wanted["CLST"][2]):
        if tag == "CDVE":
            if body >= chunk_end or data[body] != 0:
                fail("unsupported class definition version")
            body += 1
            tag, body, chunk_end = read_chunk_header(data, body, chunk_end)
        if tag != "CDEF":
            fail(f"unexpected {tag} in class definition list")
        classes.append(parse_class_def(data, body, chunk_end, property_names))
    if len(classes) != len(class_names) or any(c.name != n for c, n in zip(classes, class_names)):
        fail("class definitions do not line up with the class name index")
    return classes


def parse_class_def(data, start, end, property_names):
    name, pos = read_fstring(data, start, end)
    if end - pos < 2:
        fail("truncated class definition")
    count = U16.unpack_from(data, pos)[0]
    pos += 2
    if pos + 10 * count != end:
        fail(f"class definition {name} has the wrong length")
    properties = []
    for i in range(count):
        prop_id, prefix_id, storage = struct.unpack_from("<IIH", data, pos + 10 * i)
        if prop_id >= len(property_names) or (prefix_id != NO_ID and prefix_id >= len(property_names)):
            fail(f"class definition {name} references an unknown property name")
        path = property_names[prop_id]
        if prefix_id != NO_ID:
            path = property_names[prefix_id] + "/" + path
        properties.append((path, storage))
    return ClassDef(name, properties)


class SaveModel:
    def __init__(self, original, root, cinf, cinf_index, prop, prop_index):
        self.original = original
        self.root = root
        self.cinf = cinf
        self.cinf_index = cinf_index
        self.prop = prop
        self.prop_index = prop_index

    def serialize(self):
        return self.root.to_bytes()

    def rename(self, old, new):
        identity = self.identity()
        stored = (identity["cinf_world_name"], identity["prop_world_name"], identity["prop_world_slot_name"])
        if stored != (old, old, old):
            fail("the save does not store the expected world name in all three identity fields")
        if identity["cinf_guid"] != identity["prop_guid"]:
            fail("the two world GUID representations disagree")
        selected = {self.cinf.starts[self.cinf_index["WorldName"]],
                    self.prop.starts[self.prop_index[PROP_WORLD_NAME]],
                    self.prop.starts[self.prop_index[PROP_WORLD_SLOT]]}
        pattern, strays, pos = encode_fstring(old), [], self.original.find(encode_fstring(old))
        while pos >= 0:
            if pos not in selected:
                strays.append(pos)
            pos = self.original.find(pattern, pos + 1)
        if strays:
            fail(f"the old name is also stored at unselected offsets {strays[:5]}; refusing to guess")
        self.cinf.slices[self.cinf_index["WorldName"]] = encode_fstring(new)
        self.prop.slices[self.prop_index[PROP_WORLD_NAME]] = encode_fstring(new)
        self.prop.slices[self.prop_index[PROP_WORLD_SLOT]] = encode_fstring(new)

    def identity(self):
        guid_parts = [self.cinf.slices[self.cinf_index[part]] for part in CINF_GUID_PARTS]
        return {
            "cinf_world_name": decode_exact_fstring(self.cinf.slices[self.cinf_index["WorldName"]], "CINF WorldName"),
            "prop_world_name": decode_exact_fstring(self.prop.slices[self.prop_index[PROP_WORLD_NAME]], "WorldName"),
            "prop_world_slot_name": decode_exact_fstring(self.prop.slices[self.prop_index[PROP_WORLD_SLOT]],
                                                        "WorldSlotName"),
            "cinf_guid": b"".join(guid_parts).hex(),
            "prop_guid": self.prop.slices[self.prop_index[PROP_WORLD_GUID]].hex(),
        }


def parse_cinf(data, start, end):
    count = read_u32(data, start, end, "CINF")
    names, pos = [], start + 4
    for _ in range(count):
        text, pos = read_fstring(data, pos, end)
        names.append(text)
    slices, starts = read_offset_table(data, pos, end, "CINF")
    if len(slices) != count:
        fail("CINF name and offset counts differ")
    index = {}
    for i, name in enumerate(names):
        if name in index:
            fail(f"CINF defines {name} more than once")
        index[name] = i
    for required in ("WorldName",) + CINF_GUID_PARTS:
        if required not in index:
            fail(f"CINF has no {required}")
    return SlicedChunk("CINF", bytes(data[start:pos]), slices, starts), index


def parse_info(data, start, end):
    pos = start
    if end - pos < 2 + 8 + 9:
        fail("INFO is truncated")
    pos += 2 + 8
    flags_and_history = struct.unpack_from("<IbI", data, pos)
    if flags_and_history[1] != -1 or flags_and_history[2] != 0:
        fail("unsupported INFO title text")
    pos += 9
    _, pos = read_fstring(data, pos, end)
    children, cinf, cinf_index = [], None, None
    for tag, chunk_pos, body, chunk_end in read_chunks(data, pos, end):
        if tag == "CINF":
            if cinf is not None:
                fail("INFO has more than one CINF")
            cinf, cinf_index = parse_cinf(data, body, chunk_end)
            children.append(cinf)
        else:
            children.append(Raw(data[chunk_pos:chunk_end]))
    if cinf is None:
        fail("INFO has no CINF")
    return Container("INFO", bytes(data[start:pos]), children), cinf, cinf_index


def parse_target_object(data, start, end, classes):
    class_id = read_u32(data, start, end, "named object")
    _, pos = read_fstring(data, start + 4, end)
    pos += 12
    if pos > end:
        fail("truncated named object")
    paths = (PROP_WORLD_NAME, PROP_WORLD_SLOT, PROP_WORLD_GUID)
    if class_id >= len(classes):
        return None
    cdef = classes[class_id]
    found = [cdef.find(path) for path in paths]
    if all(i is None for i in found):
        return None
    if any(i is None for i in found):
        fail(f"class {cdef.name} defines only part of the world identity")
    expected = (STORAGE_STRING, STORAGE_STRING, STORAGE_GUID)
    if any(cdef.properties[i][1] != storage for i, storage in zip(found, expected)):
        fail(f"class {cdef.name} stores the world identity with unexpected types")
    children, prop, prop_index = [], None, None
    for tag, chunk_pos, body, chunk_end in read_chunks(data, pos, end):
        if tag == "PROP":
            if prop is not None:
                fail("named object has more than one PROP")
            slices, starts = read_offset_table(data, body, chunk_end, "PROP")
            if len(slices) != len(cdef.properties):
                fail("PROP does not have one entry per class property")
            prop = SlicedChunk("PROP", b"", slices, starts)
            prop_index = {path: i for i, (path, _) in enumerate(cdef.properties)}
            children.append(prop)
        else:
            children.append(Raw(data[chunk_pos:chunk_end]))
    if prop is None:
        fail("world identity object has no PROP")
    return Container("NOBJ", bytes(data[start:pos]), children), prop, prop_index


def parse_global(data, start, end):
    _, pos = read_fstring(data, start, end)
    children, classes, target = [], None, None
    chunks = read_chunks(data, pos, end)
    for tag, chunk_pos, body, chunk_end in chunks:
        if tag == "META":
            if classes is not None:
                fail("GLOB has more than one META")
            classes = parse_metadata(data, body, chunk_end)
    if classes is None:
        fail("GLOB has no META")
    for tag, chunk_pos, body, chunk_end in chunks:
        if tag != "GOBS":
            children.append(Raw(data[chunk_pos:chunk_end]))
            continue
        objects = []
        for obj_tag, obj_pos, obj_body, obj_end in read_chunks(data, body, chunk_end):
            decoded = parse_target_object(data, obj_body, obj_end, classes) if obj_tag == "NOBJ" else None
            if decoded is None:
                objects.append(Raw(data[obj_pos:obj_end]))
                continue
            if target is not None:
                fail("more than one object defines the world identity")
            target = decoded
            objects.append(decoded[0])
        children.append(Container("GOBS", b"", objects))
    if target is None:
        fail("no global object defines the world identity")
    return Container("GLOB", bytes(data[start:pos]), children), target[1], target[2]


def parse(data):
    try:
        return parse_save(bytes(data))
    except (struct.error, IndexError, OverflowError, UnicodeError) as error:
        raise SpudFormatError(f"malformed save: {error}") from error


def parse_save(data):
    if len(data) > MAX_SAVE_BYTES:
        fail("save is larger than the supported maximum")
    tag, start, end = read_chunk_header(data, 0, len(data))
    if tag != "SAVE" or end != len(data):
        fail("not a SAVE chunk spanning the whole file")
    chunks = read_chunks(data, start, end)
    if [c[0] for c in chunks] != ["INFO", "GLOB", "LVLS"]:
        fail("SAVE does not contain exactly INFO, GLOB, LVLS")
    info, cinf, cinf_index = parse_info(data, chunks[0][2], chunks[0][3])
    glob, prop, prop_index = parse_global(data, chunks[1][2], chunks[1][3])
    lvls = Raw(data[chunks[2][1]:chunks[2][3]])
    return SaveModel(data, Container("SAVE", b"", [info, glob, lvls]), cinf, cinf_index, prop, prop_index)


def check_new_name(old, new):
    if not NAME_PATTERN.fullmatch(new):
        raise ValueError("world name must be 1-32 characters of A-Z a-z 0-9 _ - and not start with -")
    if new == old:
        raise ValueError("the new world name equals the current one")


def rename_bytes(data, old, new):
    model = parse(data)
    model.rename(old, new)
    return model.serialize()


def rename_world(data, old, new):
    check_new_name(old, new)
    return rename_bytes(data, old, new)


def skeleton(node, skip):
    if isinstance(node, Raw):
        yield ("raw", node.data)
    elif isinstance(node, Container):
        yield ("container", node.tag, node.prefix)
        for child in node.children:
            yield from skeleton(child, skip)
    else:
        kept = tuple(item for i, item in enumerate(node.slices) if i not in skip[id(node)])
        yield ("sliced", node.tag, node.head, kept)


def model_skeleton(model):
    skip = {id(model.cinf): {model.cinf_index["WorldName"]},
            id(model.prop): {model.prop_index[PROP_WORLD_NAME], model.prop_index[PROP_WORLD_SLOT]}}
    return list(skeleton(model.root, skip))


def verify_candidate(original, candidate, old, new):
    before, after = parse(original), parse(candidate)
    if before.serialize() != original or after.serialize() != candidate:
        fail("a save does not re-serialize to itself")
    old_id, new_id = before.identity(), after.identity()
    if (old_id["cinf_world_name"], old_id["prop_world_name"], old_id["prop_world_slot_name"]) != (old, old, old):
        fail("the original does not store the old name in all three fields")
    if (new_id["cinf_world_name"], new_id["prop_world_name"], new_id["prop_world_slot_name"]) != (new, new, new):
        fail("the candidate does not store the new name in all three fields")
    guids = {old_id["cinf_guid"], old_id["prop_guid"], new_id["cinf_guid"], new_id["prop_guid"]}
    if len(guids) != 1:
        fail("the world GUID changed or its two representations disagree")
    if model_skeleton(before) != model_skeleton(after):
        fail("something other than the three name fields changed")
    if rename_world(original, old, new) != candidate:
        fail("the candidate is not what a fresh rename of the original produces")
    if rename_bytes(candidate, new, old) != original:
        fail("renaming the candidate back does not reproduce the original")
    return {
        "sha256_original": hashlib.sha256(original).hexdigest(),
        "sha256_candidate": hashlib.sha256(candidate).hexdigest(),
        "size_original": len(original),
        "size_candidate": len(candidate),
        "size_growth": len(candidate) - len(original),
        "guid": ue_guid(new_id["prop_guid"]),
    }


def ue_guid(raw_hex):
    raw = bytes.fromhex(raw_hex)
    return "".join(f"{U32.unpack_from(raw, i)[0]:08X}" for i in range(0, 16, 4))


def read_save(path):
    if path.stat().st_size > MAX_SAVE_BYTES:
        fail(f"{path} is larger than the supported maximum")
    return path.read_bytes()


def write_private(path, data):
    partial = path.with_name(path.name + ".partial")
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(partial, path)
    finally:
        partial.unlink(missing_ok=True)


def check_output_path(output):
    if os.path.lexists(output):
        fail(f"output already exists: {output}")
    if not output.parent.is_dir():
        fail(f"output directory does not exist: {output.parent}")
    if output.parent.resolve().name == "SaveGames":
        fail("refusing to write into a SaveGames directory; write a candidate elsewhere and install it deliberately")


def command_inspect(args):
    path = Path(args.path)
    data = read_save(path)
    identity = parse(data).identity()
    agree = identity["cinf_guid"] == identity["prop_guid"]
    print(f"file        : {path}")
    print(f"size        : {len(data)} bytes")
    print(f"sha256      : {hashlib.sha256(data).hexdigest()}")
    print(f"world name  : {identity['cinf_world_name']} (INFO/CINF)")
    print(f"world name  : {identity['prop_world_name']} (GLOB/GOBS PROP)")
    print(f"slot name   : {identity['prop_world_slot_name']} (GLOB/GOBS PROP)")
    print(f"world GUID  : {ue_guid(identity['prop_guid'])} (bytes {identity['prop_guid']})")
    print(f"GUID copies : {'agree' if agree else 'DISAGREE'}")
    return 0


def command_rename(args):
    source, output = Path(args.input), Path(args.output)
    check_output_path(output)
    data = read_save(source)
    candidate = rename_world(data, args.old_name, args.new_name)
    try:
        report = verify_candidate(data, candidate, args.old_name, args.new_name)
    except SpudFormatError as error:
        fail(f"verification failed: {error}")
    write_private(output, candidate)
    print(f"renamed world {args.old_name!r} -> {args.new_name!r}")
    print(f"input     : {source} sha256={report['sha256_original']} size={report['size_original']}")
    print(f"candidate : {output} sha256={report['sha256_candidate']} size={report['size_candidate']}")
    print(f"world GUID unchanged: {report['guid']}")
    print("verified  : only the three name fields changed; reverse rename reproduces the input byte for byte")
    return 0


def command_verify(args):
    original, candidate = read_save(Path(args.original)), read_save(Path(args.candidate))
    report = verify_candidate(original, candidate, args.old_name, args.new_name)
    print(f"original  sha256={report['sha256_original']} size={report['size_original']}")
    print(f"candidate sha256={report['sha256_candidate']} size={report['size_candidate']}")
    print(f"world GUID unchanged: {report['guid']}")
    print("verified  : only the three name fields changed; reverse rename reproduces the original byte for byte")
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Offline Dragonwilds SPUD world rename; never touches a running server.")
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect", help="print the world identity stored in a save")
    inspect.add_argument("path")
    rename = commands.add_parser("rename", help="write a renamed, verified copy of a save")
    rename.add_argument("--input", required=True)
    rename.add_argument("--output", required=True)
    rename.add_argument("--from", dest="old_name", required=True)
    rename.add_argument("--to", dest="new_name", required=True)
    verify = commands.add_parser("verify", help="check a candidate against its original")
    verify.add_argument("--original", required=True)
    verify.add_argument("--candidate", required=True)
    verify.add_argument("--from", dest="old_name", required=True)
    verify.add_argument("--to", dest="new_name", required=True)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    handlers = {"inspect": command_inspect, "rename": command_rename, "verify": command_verify}
    try:
        return handlers[args.command](args)
    except (ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
