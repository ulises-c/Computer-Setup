#!/usr/bin/env python3
import contextlib
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import unittest.mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "dragonwilds/spud_world_rename.py"
spec = importlib.util.spec_from_file_location("spud_world_rename", MODULE_PATH)
spud = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = spud
spec.loader.exec_module(spud)

GUID = bytes.fromhex("00112233445566778899aabbccddeeff")
OWNER_TEXT = "owner-secret-0123456789abcdef"
PASSWORD_TEXT = "join-secret-hunter2"
PREFIX = "WorldSaveSettings"
OWNER_PREFIX = "WorldSaveSettings/PlayerOwnerGuid"
VERSION_PAIR = struct.pack("<II", 522, 1017)
TIMESTAMP = "2026-10-05T04:16:16.564Z"


def fstr(text):
    raw = text.encode("ascii") + b"\0"
    return struct.pack("<i", len(raw)) + raw


RAW_BODIES = {}


def chunk(tag, body):
    body = RAW_BODIES.get(tag, body)
    return tag.encode("ascii") + struct.pack("<I", len(body)) + body


def offset_table(slices):
    offsets, position = [], 0
    for item in slices:
        offsets.append(position)
        position += len(item)
    return (struct.pack("<I", len(slices)) + b"".join(struct.pack("<I", o) for o in offsets)
            + struct.pack("<I", position) + b"".join(slices))


def default_props(world, slot, guid):
    return [
        ("WorldSettingsVersion", PREFIX, 2, struct.pack("<I", 7)),
        ("WorldSaveGuid", PREFIX, 23, guid),
        ("WorldName", PREFIX, 30, fstr(world)),
        ("WorldSlotName", PREFIX, 30, fstr(slot)),
        ("WorldMapName", PREFIX, 30, fstr("L_World")),
        ("bFriendlyFire", PREFIX, 0, b"\0"),
        ("SurvivalDifficulty", PREFIX, 1, struct.pack("<H", 2)),
        ("CustomDifficultySettings", PREFIX, 64, bytes(range(8))),
        ("LastSavedByEntries", PREFIX, 64, bytes(range(100, 200))),
        ("GuidData", OWNER_PREFIX, 30, fstr(OWNER_TEXT)),
        ("OwnerName", PREFIX, 30, fstr("Some Owner")),
        ("SaveFileRevision", PREFIX, 6, struct.pack("<i", 3)),
    ]


def cinf_chunk(world, guid, password=PASSWORD_TEXT, skip=()):
    fields = [
        ("VERSION", struct.pack("<I", 9)),
        ("GUID_A", guid[0:4]), ("GUID_B", guid[4:8]), ("GUID_C", guid[8:12]), ("GUID_D", guid[12:16]),
        ("WorldName", fstr(world)),
        ("WorldMapName", fstr("L_World")),
        ("FriendlyFire", b"\0"),
        ("SurvivalDifficulty", struct.pack("<I", 0)),
        ("HardcoreState", struct.pack("<I", 1)),
        ("TimeOfSave", bytes(range(8))),
        ("SessionPrivacy", struct.pack("<I", 0)),
        ("SessionPasswd", fstr(password)),
        ("CrossplayEnabled", struct.pack("<I", 1)),
        ("WorldOwnerId", struct.pack("<I", 4242)),
        ("WorldNameOwner", fstr("Some Owner")),
        ("LastSavedBy", fstr("build-" + "x" * 60)),
        ("Meta_SaveFileRevision", struct.pack("<I", 3)),
    ]
    fields = [f for f in fields if f[0] not in skip]
    names = b"".join(fstr(name) for name, _ in fields)
    return chunk("CINF", struct.pack("<I", len(fields)) + names + offset_table([data for _, data in fields]))


def build_save(world="1", slot=None, cinf_world=None, guid=GUID, prop_guid=None, props=None,
               glai=None, levels=3, nobj_extra=b"", tail=b"", extra_prop_slices=(), nobj_copies=1,
               cinf_skip=(), cnix_name=None, clst_style="cdve"):
    slot = world if slot is None else slot
    cinf_world = world if cinf_world is None else cinf_world
    props = default_props(world, slot, prop_guid or guid) if props is None else props
    prop_names, class_defs, slices = [], [], []
    for name, prefix, dtype, data in props:
        for text in (prefix, name):
            if text not in prop_names:
                prop_names.append(text)
        class_defs.append(struct.pack("<IIH", prop_names.index(name), prop_names.index(prefix), dtype))
        slices.append(data)
    slices += list(extra_prop_slices)
    class_name = "/Script/Test.PersistenceSubsystem"
    cdef = chunk("CDEF", fstr(class_name) + struct.pack("<H", len(props)) + b"".join(class_defs))
    meta = chunk("META", b"".join([
        chunk("VERS", struct.pack("<i", 5)),
        chunk("CNIX", struct.pack("<I", 1) + fstr(cnix_name or class_name)),
        chunk("CLST", {"cdve": chunk("CDVE", b"\0" + cdef), "cdef": cdef,
                       "other": chunk("ZZZZ", cdef[8:])}[clst_style]),
        chunk("PNIX", struct.pack("<I", len(prop_names)) + b"".join(fstr(n) for n in prop_names)),
    ]))
    nobj = chunk("NOBJ", struct.pack("<I", 0) + fstr("TestPersistence") + struct.pack("<I", 0) + VERSION_PAIR
                 + chunk("PROP", offset_table(slices)) + nobj_extra)
    glai = chunk("GLAI", chunk("LVNI", bytes(range(256)) * 4) + b"\x11" * 77) if glai is None else glai
    glob = chunk("GLOB", fstr("L_World") + meta + chunk("GOBS", nobj * nobj_copies) + glai)
    info = chunk("INFO", struct.pack("<H", 8) + VERSION_PAIR + struct.pack("<IbI", 0, -1, 0)
                 + fstr(TIMESTAMP) + cinf_chunk(cinf_world, guid, skip=cinf_skip))
    lvls = chunk("LVLS", b"".join(
        chunk("LEVL", fstr(f"Cell_{i}") + VERSION_PAIR + bytes([i]) * (50 + 13 * i)) for i in range(levels)))
    return chunk("SAVE", info + glob + lvls + tail)


class RoundtripTests(unittest.TestCase):
    def test_noop_roundtrip_is_byte_exact(self):
        data = build_save()
        self.assertEqual(spud.parse(data).serialize(), data)

    def test_identity_reports_schema_selected_fields(self):
        identity = spud.parse(build_save(world="Alpha", slot="Beta", cinf_world="Gamma")).identity()
        self.assertEqual(identity["cinf_world_name"], "Gamma")
        self.assertEqual(identity["prop_world_name"], "Alpha")
        self.assertEqual(identity["prop_world_slot_name"], "Beta")
        self.assertEqual(identity["cinf_guid"], GUID.hex())
        self.assertEqual(identity["prop_guid"], GUID.hex())


def reordered_props(world, slot, guid, order):
    by_name = {p[0]: p for p in default_props(world, slot, guid)}
    return [by_name[name] for name in order]


def chunk_children(data, start, end):
    out, pos = [], start
    while pos < end:
        tag = data[pos:pos + 4].decode("ascii")
        length = struct.unpack_from("<I", data, pos + 4)[0]
        out.append((tag, data[pos:pos + 8 + length]))
        pos += 8 + length
    return out


def untouched_regions(data):
    top = dict(chunk_children(data, 8, len(data)))
    glob_body = top["GLOB"][8:]
    skip = 4 + struct.unpack_from("<i", glob_body, 0)[0]
    glob = dict(chunk_children(glob_body, skip, len(glob_body)))
    return {"LVLS": top["LVLS"], "GLAI": glob["GLAI"], "META": glob["META"]}


class RenameTests(unittest.TestCase):
    def test_rename_equals_independently_built_fixture(self):
        for new in ("Ashenfall", "X", "Longer_World-Name_123", "ab"):
            with self.subTest(new=new):
                self.assertEqual(spud.rename_world(build_save(world="1"), "1", new), build_save(world=new))

    def test_rename_to_same_length_name_keeps_size(self):
        data = build_save(world="1")
        renamed = spud.rename_world(data, "1", "Z")
        self.assertEqual(len(renamed), len(data))
        self.assertEqual(renamed, build_save(world="Z"))

    def test_reverse_rename_restores_original_bytes(self):
        data = build_save(world="1")
        renamed = spud.rename_world(data, "1", "Ashenfall")
        self.assertEqual(spud.rename_world(renamed, "Ashenfall", "1"), data)

    def test_growth_is_three_string_fields(self):
        data = build_save(world="1")
        renamed = spud.rename_world(data, "1", "Ashenfall")
        self.assertEqual(len(renamed), len(data) + 3 * (len("Ashenfall") - len("1")))

    def test_opaque_regions_and_identity_are_untouched(self):
        data = build_save(world="1", glai=chunk("GLAI", b"opaque-global-ai" * 50), levels=5)
        renamed = spud.rename_world(data, "1", "Ashenfall")
        self.assertEqual(untouched_regions(renamed), untouched_regions(data))
        before, after = spud.parse(data).identity(), spud.parse(renamed).identity()
        self.assertEqual((after["cinf_guid"], after["prop_guid"]), (before["cinf_guid"], before["prop_guid"]))

    def test_other_properties_are_byte_identical(self):
        data = build_save(world="1")
        renamed = spud.rename_world(data, "1", "Ashenfall")
        before, after = spud.parse(data), spud.parse(renamed)
        skip_prop = {before.prop_index[spud.PROP_WORLD_NAME], before.prop_index[spud.PROP_WORLD_SLOT]}
        for i, (old, new) in enumerate(zip(before.prop.slices, after.prop.slices)):
            if i not in skip_prop:
                self.assertEqual(old, new, i)
        for i, (old, new) in enumerate(zip(before.cinf.slices, after.cinf.slices)):
            if i != before.cinf_index["WorldName"]:
                self.assertEqual(old, new, i)

    def test_rename_follows_schema_not_fixed_offsets(self):
        order = ["OwnerName", "WorldSlotName", "SaveFileRevision", "WorldMapName", "LastSavedByEntries",
                 "GuidData", "WorldName", "bFriendlyFire", "WorldSaveGuid", "CustomDifficultySettings",
                 "SurvivalDifficulty", "WorldSettingsVersion"]
        old = build_save(world="1", props=reordered_props("1", "1", GUID, order))
        expected = build_save(world="Ashenfall", props=reordered_props("Ashenfall", "Ashenfall", GUID, order))
        self.assertEqual(spud.rename_world(old, "1", "Ashenfall"), expected)

    def test_rename_handles_extra_leading_property(self):
        lead = ("AnotherSetting", PREFIX, 30, fstr("leading-value-is-long-enough-to-shift-everything"))
        old = build_save(world="1", props=[lead] + default_props("1", "1", GUID))
        expected = build_save(world="Ashenfall", props=[lead] + default_props("Ashenfall", "Ashenfall", GUID))
        self.assertEqual(spud.rename_world(old, "1", "Ashenfall"), expected)

    def test_rename_leaves_a_same_text_string_in_another_field_alone(self):
        props = default_props("1", "1", GUID) + [("Nickname", PREFIX, 30, fstr("not-a-world"))]
        old = build_save(world="1", props=props)
        expected = build_save(world="Ashenfall",
                              props=default_props("Ashenfall", "Ashenfall", GUID) + [props[-1]])
        self.assertEqual(spud.rename_world(old, "1", "Ashenfall"), expected)


def build_with_bodies(bodies, **kwargs):
    RAW_BODIES.update(bodies)
    try:
        return build_save(**kwargs)
    finally:
        RAW_BODIES.clear()


class RefusalTests(unittest.TestCase):
    def assert_refused(self, data, old="1", new="Ashenfall"):
        with self.assertRaises(spud.SpudFormatError):
            spud.rename_world(data, old, new)

    def test_refuses_when_cinf_world_name_is_not_the_expected_old_name(self):
        self.assert_refused(build_save(world="1", cinf_world="Other"))

    def test_refuses_when_prop_world_name_is_not_the_expected_old_name(self):
        props = default_props("1", "1", GUID)
        props[2] = ("WorldName", PREFIX, 30, fstr("Other"))
        self.assert_refused(build_save(world="1", props=props))

    def test_refuses_when_slot_name_is_not_the_expected_old_name(self):
        self.assert_refused(build_save(world="1", slot="Other"))

    def test_refuses_when_requested_old_name_does_not_match_the_save(self):
        self.assert_refused(build_save(world="1"), old="Main")

    def test_refuses_when_the_two_guid_representations_disagree(self):
        self.assert_refused(build_save(world="1", prop_guid=bytes(16)))

    def test_refuses_when_the_old_name_is_stored_in_an_unselected_place(self):
        self.assert_refused(build_save(world="1", glai=chunk("GLAI", b"head" + fstr("1") + b"tail")))

    def test_refuses_when_an_unselected_property_holds_the_old_name(self):
        props = default_props("1", "1", GUID) + [("Nickname", PREFIX, 30, fstr("1"))]
        self.assert_refused(build_save(world="1", props=props))

    def test_refuses_when_the_world_identity_schema_is_only_partial(self):
        props = [p for p in default_props("1", "1", GUID) if p[0] != "WorldSlotName"]
        self.assert_refused(build_save(world="1", props=props))

    def test_refuses_when_no_object_defines_the_world_identity(self):
        props = [p for p in default_props("1", "1", GUID) if p[0] not in ("WorldName", "WorldSlotName", "WorldSaveGuid")]
        self.assert_refused(build_save(world="1", props=props))

    def test_refuses_when_the_world_name_is_not_stored_as_a_string(self):
        for dtype in (31, 30 | 0x1000):
            with self.subTest(dtype=dtype):
                props = default_props("1", "1", GUID)
                props[2] = ("WorldName", PREFIX, dtype, fstr("1"))
                self.assert_refused(build_save(world="1", props=props))

    def test_refuses_a_utf16_world_name(self):
        props = default_props("1", "1", GUID)
        props[2] = ("WorldName", PREFIX, 30, struct.pack("<i", -2) + "1\0".encode("utf-16-le"))
        self.assert_refused(build_save(world="1", props=props))

    def test_refuses_when_prop_has_a_different_entry_count_than_its_class(self):
        self.assert_refused(build_save(world="1", extra_prop_slices=[b"\0\0"]))

    def test_refuses_when_two_objects_define_the_world_identity(self):
        with self.assertRaises(spud.SpudFormatError):
            spud.parse(build_save(world="1", nobj_copies=2))

    def test_refuses_a_property_table_that_does_not_start_at_zero(self):
        data = bytearray(build_save(world="1"))
        struct.pack_into("<I", data, data.index(b"PROP") + 8 + 4, 1)
        self.assert_refused(bytes(data))

    def test_refuses_an_unknown_chunk_in_the_class_definition_list(self):
        self.assert_refused(build_save(world="1", clst_style="other"))

    def test_accepts_class_definitions_stored_directly_as_cdef_chunks(self):
        old = build_save(world="1", clst_style="cdef")
        self.assertEqual(spud.rename_world(old, "1", "Ashenfall"), build_save(world="Ashenfall", clst_style="cdef"))

    def test_refuses_more_table_entries_than_the_limit(self):
        with unittest.mock.patch.object(spud, "MAX_ENTRIES", 10):
            with self.assertRaisesRegex(spud.SpudFormatError, "overruns"):
                spud.parse(build_save(world="1"))

    def test_refuses_more_child_chunks_than_the_limit(self):
        data = build_with_bodies({"GOBS": chunk("ZZZZ", b"") * 21})
        with unittest.mock.patch.object(spud, "MAX_ENTRIES", 20):
            with self.assertRaisesRegex(spud.SpudFormatError, "too many child chunks"):
                spud.parse(data)

    def test_refuses_when_cinf_lacks_a_guid_part(self):
        self.assert_refused(build_save(world="1", cinf_skip=("GUID_C",)))

    def test_refuses_when_cinf_lacks_the_world_name(self):
        self.assert_refused(build_save(world="1", cinf_skip=("WorldName",)))

    def test_refuses_when_class_definitions_do_not_match_the_class_index(self):
        self.assert_refused(build_save(world="1", cnix_name="/Script/Test.SomethingElse"))

    def test_refuses_a_truncated_save(self):
        self.assert_refused(build_save(world="1")[:-1])

    def test_refuses_trailing_bytes_after_the_save_chunk(self):
        self.assert_refused(build_save(world="1") + b"\0")

    def test_refuses_an_unexpected_top_level_chunk(self):
        self.assert_refused(build_save(world="1", tail=chunk("EXTR", b"x")))

    def test_refuses_a_file_that_is_not_a_save_chunk(self):
        data = bytearray(build_save(world="1"))
        data[0:4] = b"SAVX"
        self.assert_refused(bytes(data))

    def test_refuses_an_unsupported_title_text(self):
        data = bytearray(build_save(world="1"))
        data[data.index(fstr(TIMESTAMP)) - 5] = 0
        self.assert_refused(bytes(data))

    def test_refuses_an_unsupported_class_definition_version(self):
        data = bytearray(build_save(world="1"))
        data[data.index(b"CDVE") + 8] = 1
        self.assert_refused(bytes(data))

    def test_refuses_non_monotonic_property_offsets(self):
        data = bytearray(build_save(world="1"))
        struct.pack_into("<I", data, data.index(b"PROP") + 8 + 4 + 4 * 3, 99999)
        self.assert_refused(bytes(data))

    def test_refuses_an_implausible_entry_count_without_allocating(self):
        data = bytearray(build_save(world="1"))
        struct.pack_into("<I", data, data.index(b"CINF") + 8, 0xFFFFFFFF)
        self.assert_refused(bytes(data))

    def test_refuses_a_save_over_the_size_limit(self):
        data = build_save(world="1")
        with unittest.mock.patch.object(spud, "MAX_SAVE_BYTES", len(data) - 1):
            self.assert_refused(data)

    def test_any_corruption_is_refused_or_round_trips_exactly(self):
        import random
        data = build_save(world="1")
        rng = random.Random(20261005)
        cases = [data[:n] for n in range(0, len(data), 7)]
        for _ in range(3000):
            mutated = bytearray(data)
            for _ in range(rng.choice((1, 1, 2, 3))):
                mutated[rng.randrange(len(data))] = rng.randrange(256)
            cases.append(bytes(mutated))
        for case in cases:
            try:
                model = spud.parse(case)
                model.identity()
            except spud.SpudFormatError:
                continue
            self.assertEqual(model.serialize(), case)

    def test_garbage_in_any_table_chunk_is_refused_or_round_trips_exactly(self):
        import random
        rng = random.Random(7)
        tags = ("CINF", "CNIX", "PNIX", "CLST", "CDVE", "CDEF", "PROP", "VERS", "META", "GOBS", "NOBJ", "INFO",
                "GLOB", "LVLS", "LEVL", "GLAI")
        for tag in tags:
            for _ in range(150):
                body = bytes(rng.randrange(256) for _ in range(rng.randrange(0, 40)))
                case = build_with_bodies({tag: body})
                try:
                    model = spud.parse(case)
                    model.identity()
                except spud.SpudFormatError:
                    continue
                self.assertEqual(model.serialize(), case, tag)

    def test_empty_table_chunks_are_refused_not_read_past_their_end(self):
        for tag in ("CINF", "CNIX", "PNIX", "PROP", "CDEF"):
            with self.subTest(tag=tag):
                self.assert_refused(build_with_bodies({tag: b""}))


class NameValidationTests(unittest.TestCase):
    def test_rejects_names_that_are_not_safe_file_names(self):
        for bad in ("", "a" * 33, "a/b", "..", "a b", "caf\u00e9", "a.b", "a\0b", "-lead", "tab\t"):
            with self.subTest(name=bad):
                with self.assertRaises(ValueError):
                    spud.rename_world(build_save(world="1"), "1", bad)

    def test_rejects_renaming_to_the_current_name(self):
        with self.assertRaises(ValueError):
            spud.rename_world(build_save(world="1"), "1", "1")

    def test_accepts_conservative_names(self):
        for good in ("Ashenfall", "World_2", "a", "A-b_C9", "x" * 32):
            with self.subTest(name=good):
                spud.rename_world(build_save(world="1"), "1", good)


class VerifyCandidateTests(unittest.TestCase):
    def setUp(self):
        self.old = build_save(world="1")
        self.new = spud.rename_world(self.old, "1", "Ashenfall")

    def test_accepts_the_real_candidate_and_reports_hashes(self):
        report = spud.verify_candidate(self.old, self.new, "1", "Ashenfall")
        self.assertEqual(report["sha256_original"], hashlib.sha256(self.old).hexdigest())
        self.assertEqual(report["sha256_candidate"], hashlib.sha256(self.new).hexdigest())
        self.assertEqual(report["size_growth"], 3 * (len("Ashenfall") - 1))

    def test_rejects_a_changed_opaque_region(self):
        data = bytearray(self.new)
        data[-1] ^= 1
        with self.assertRaisesRegex(spud.SpudFormatError, "other than the three name fields"):
            spud.verify_candidate(self.old, bytes(data), "1", "Ashenfall")

    def test_rejects_a_changed_unrelated_property(self):
        data = bytearray(self.new)
        data[data.index(fstr("Some Owner")) + 5] ^= 1
        with self.assertRaisesRegex(spud.SpudFormatError, "other than the three name fields"):
            spud.verify_candidate(self.old, bytes(data), "1", "Ashenfall")

    def test_rejects_a_candidate_with_a_different_guid(self):
        other = spud.rename_world(build_save(world="1", guid=bytes(range(16))), "1", "Ashenfall")
        with self.assertRaisesRegex(spud.SpudFormatError, "GUID"):
            spud.verify_candidate(self.old, other, "1", "Ashenfall")

    def test_rejects_a_candidate_that_still_has_the_old_name(self):
        with self.assertRaisesRegex(spud.SpudFormatError, "candidate does not store the new name"):
            spud.verify_candidate(self.old, self.old, "1", "Ashenfall")

    def test_rejects_when_a_fresh_rename_would_produce_different_bytes(self):
        with unittest.mock.patch.object(spud, "rename_world", lambda data, old, new: data):
            with self.assertRaisesRegex(spud.SpudFormatError, "fresh rename"):
                spud.verify_candidate(self.old, self.new, "1", "Ashenfall")

    def test_rejects_when_renaming_back_does_not_reproduce_the_original(self):
        real = spud.rename_bytes
        forward_only = lambda data, old, new: real(data, old, new) if old == "1" else data
        with unittest.mock.patch.object(spud, "rename_bytes", forward_only):
            with self.assertRaisesRegex(spud.SpudFormatError, "back does not reproduce"):
                spud.verify_candidate(self.old, self.new, "1", "Ashenfall")

    def test_rejects_when_a_save_does_not_reserialize_to_itself(self):
        real = spud.parse

        def broken(data):
            model = real(data)
            model.serialize = lambda: b"different"
            return model

        with unittest.mock.patch.object(spud, "parse", broken):
            with self.assertRaisesRegex(spud.SpudFormatError, "re-serialize"):
                spud.verify_candidate(self.old, self.new, "1", "Ashenfall")

    def test_rejects_a_candidate_renamed_to_another_name(self):
        other = spud.rename_world(self.old, "1", "Different")
        with self.assertRaisesRegex(spud.SpudFormatError, "candidate does not store the new name"):
            spud.verify_candidate(self.old, other, "1", "Ashenfall")

    def test_rejects_an_original_that_does_not_hold_the_old_name(self):
        with self.assertRaisesRegex(spud.SpudFormatError, "original does not store the old name"):
            spud.verify_candidate(self.old, self.new, "Other", "Ashenfall")


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "1.sav"
        self.source.write_bytes(build_save(world="1"))
        self.out = self.root / "candidate" / "Ashenfall.sav"
        self.out.parent.mkdir()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = spud.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def rename_args(self, **overrides):
        values = {"input": self.source, "output": self.out, "from": "1", "to": "Ashenfall"}
        values.update(overrides)
        return ["rename"] + [item for k, v in values.items() for item in (f"--{k}", str(v))]

    def assert_no_secrets(self, *streams):
        for text in streams:
            for secret in (PASSWORD_TEXT, OWNER_TEXT, "Some Owner"):
                self.assertNotIn(secret, text)

    def test_rename_writes_a_private_verified_candidate_and_leaves_the_input_alone(self):
        before = self.source.read_bytes()
        previous = os.umask(0o022)
        self.addCleanup(os.umask, previous)
        code, out, err = self.run_cli(*self.rename_args())
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.out.read_bytes(), build_save(world="Ashenfall"))
        self.assertEqual(self.out.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertIn(hashlib.sha256(before).hexdigest(), out)
        self.assertIn(hashlib.sha256(self.out.read_bytes()).hexdigest(), out)
        self.assertEqual(sorted(p.name for p in self.out.parent.iterdir()), ["Ashenfall.sav"])
        self.assert_no_secrets(out, err)

    def test_rename_refuses_to_overwrite_an_existing_output(self):
        self.out.write_bytes(b"keep me")
        code, _, err = self.run_cli(*self.rename_args())
        self.assertEqual(code, 2)
        self.assertIn("already exists", err)
        self.assertEqual(self.out.read_bytes(), b"keep me")

    def test_rename_refuses_the_input_as_output_even_through_a_symlink(self):
        link = self.root / "link.sav"
        link.symlink_to(self.source)
        before = self.source.read_bytes()
        for target in (self.source, link):
            code, _, _ = self.run_cli(*self.rename_args(output=target))
            self.assertEqual(code, 2)
        self.assertEqual(self.source.read_bytes(), before)

    def test_rename_refuses_to_write_into_a_save_games_directory(self):
        saves = self.root / "SaveGames"
        saves.mkdir()
        code, _, err = self.run_cli(*self.rename_args(output=saves / "Ashenfall.sav"))
        self.assertEqual(code, 2)
        self.assertIn("SaveGames", err)
        self.assertEqual(list(saves.iterdir()), [])

    def test_rename_refuses_a_bad_save_and_leaves_no_output(self):
        self.source.write_bytes(b"not a save")
        code, _, err = self.run_cli(*self.rename_args())
        self.assertEqual(code, 2)
        self.assertTrue(err.startswith("error:"))
        self.assertEqual(list(self.out.parent.iterdir()), [])

    def test_rename_refuses_an_input_over_the_size_limit(self):
        with unittest.mock.patch.object(spud, "MAX_SAVE_BYTES", 10):
            code, _, err = self.run_cli(*self.rename_args())
        self.assertEqual(code, 2)
        self.assertIn(f"{self.source} is larger", err)

    def test_rename_refuses_a_missing_output_directory(self):
        code, _, err = self.run_cli(*self.rename_args(output=self.root / "nope" / "Ashenfall.sav"))
        self.assertEqual(code, 2)
        self.assertIn("does not exist", err)

    def test_rename_refuses_a_missing_input_directory_or_name(self):
        for overrides in ({"input": self.root / "missing.sav"}, {"to": "bad name"}, {"from": "Other"}):
            with self.subTest(overrides=overrides):
                code, _, _ = self.run_cli(*self.rename_args(**overrides))
                self.assertEqual(code, 2)
                self.assertEqual(list(self.out.parent.iterdir()), [])

    def test_rename_never_leaves_an_unverified_output(self):
        real = spud.rename_world

        def corrupt(data, old, new):
            result = bytearray(real(data, old, new))
            result[-1] ^= 1
            return bytes(result)

        with unittest.mock.patch.object(spud, "rename_world", corrupt):
            code, _, err = self.run_cli(*self.rename_args())
        self.assertEqual(code, 2)
        self.assertIn("verification", err)
        self.assertEqual(list(self.out.parent.iterdir()), [])

    def test_inspect_prints_the_identity_and_no_secrets(self):
        code, out, err = self.run_cli("inspect", str(self.source))
        self.assertEqual((code, err), (0, ""))
        self.assertIn("world name", out)
        self.assertIn(GUID.hex(), out)
        self.assertIn("33221100" "77665544" "BBAA9988" "FFEEDDCC", out)
        self.assertIn(hashlib.sha256(self.source.read_bytes()).hexdigest(), out)
        self.assert_no_secrets(out, err)

    def test_verify_command_checks_a_candidate_against_its_original(self):
        self.run_cli(*self.rename_args())
        args = ["verify", "--original", str(self.source), "--candidate", str(self.out), "--from", "1",
                "--to", "Ashenfall"]
        self.assertEqual(self.run_cli(*args)[0], 0)
        tampered = bytearray(self.out.read_bytes())
        tampered[-1] ^= 1
        self.out.chmod(0o600)
        self.out.write_bytes(bytes(tampered))
        code, _, err = self.run_cli(*args)
        self.assertEqual(code, 2)
        self.assertTrue(err.startswith("error:"))


@unittest.skipUnless(os.environ.get("DRAGONWILDS_PRIVATE_SAVE"), "set DRAGONWILDS_PRIVATE_SAVE to a private save copy")
class PrivateSaveTests(unittest.TestCase):
    def setUp(self):
        self.data = Path(os.environ["DRAGONWILDS_PRIVATE_SAVE"]).read_bytes()
        self.old = spud.parse(self.data).identity()["prop_world_name"]
        self.new = os.environ.get("DRAGONWILDS_PRIVATE_NEW_NAME", "Ashenfall")

    def test_noop_roundtrip_is_byte_exact(self):
        self.assertEqual(spud.parse(self.data).serialize(), self.data)

    def test_rename_and_reverse_are_byte_exact_and_verified(self):
        candidate = spud.rename_world(self.data, self.old, self.new)
        self.assertEqual(len(candidate), len(self.data) + 3 * (len(self.new) - len(self.old)))
        self.assertEqual(spud.rename_world(candidate, self.new, self.old), self.data)
        spud.verify_candidate(self.data, candidate, self.old, self.new)


if __name__ == "__main__":
    unittest.main()
