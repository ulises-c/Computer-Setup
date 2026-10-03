import json
import importlib.util
import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "dragonwilds/player_log.py"
SPEC = importlib.util.spec_from_file_location("player_log", MODULE_PATH)
player_log = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(player_log)
PlayerLog = player_log.PlayerLog
aggregate_player_events = player_log.aggregate_player_events
parse_journal_records = player_log.parse_journal_records
SESSION_1 = "session:" + "1" * 32
SESSION_2 = "session:" + "2" * 32
SESSION_3 = "session:" + "3" * 32


class PlayerLogTests(unittest.TestCase):
    def test_parses_join_and_leave_without_retaining_raw_messages(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.10:4321",
            },
            {
                "__CURSOR": "c2",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "LogNet: Join succeeded: Alice Example",
            },
            {
                "__CURSOR": "c3",
                "__REALTIME_TIMESTAMP": "1760000060000000",
                "MESSAGE": "UNetDriver::RemoveClientConnection - Removed address 192.0.2.10:4321",
            },
        ]

        events, state = parse_journal_records(records, {}, session_id=SESSION_1, server_build="123")

        self.assertEqual([event["event"] for event in events], ["player_joined", "player_left"])
        self.assertEqual(events[0]["player_name"], "Alice Example")
        self.assertEqual(events[0]["remote_addr"], "192.0.2.10")
        self.assertEqual(events[0]["remote_port"], 4321)
        self.assertEqual(events[0]["server_build"], "123")
        self.assertEqual(events[1]["player_name"], "Alice Example")
        self.assertNotIn("message", events[0])
        self.assertNotIn("message", events[1])
        self.assertEqual(state["last_cursor"], "c3")
        self.assertEqual(state["active_connections"], {})

    def test_does_not_guess_between_concurrent_pending_connections(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.10:4321",
            },
            {
                "__CURSOR": "c2",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.11:4322",
            },
            {
                "__CURSOR": "c3",
                "__REALTIME_TIMESTAMP": "1760000002000000",
                "MESSAGE": "LogNet: Join succeeded: Alice Example",
            },
        ]

        events, state = parse_journal_records(records, {}, session_id=SESSION_1)

        self.assertIsNone(events[0]["remote_addr"])
        self.assertIsNone(events[0]["remote_port"])
        self.assertEqual(state["active_connections"], {})
        self.assertEqual(len(state["pending_connections"]), 2)

    def test_new_session_discards_old_connection_correlation_state(self):
        records = [
            {
                "__CURSOR": "c2",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 198.51.100.20:5000",
            },
            {
                "__CURSOR": "c3",
                "__REALTIME_TIMESTAMP": "1760000002000000",
                "MESSAGE": "LogNet: Join succeeded: Bob",
            },
        ]
        old_state = {
            "session_id": SESSION_2,
            "active_connections": {
                "192.0.2.10:4321": {
                    "player_name": "Old Player",
                    "remote_addr": "192.0.2.10",
                    "remote_port": 4321,
                }
            },
            "pending_connections": [{"address": "192.0.2.11", "port": 4322}],
        }

        events, state = parse_journal_records(records, old_state, session_id=SESSION_3)

        self.assertEqual(events[0]["remote_addr"], "198.51.100.20")
        self.assertEqual(state["session_id"], SESSION_3)
        self.assertNotIn("192.0.2.10:4321", state["active_connections"])

    def test_removed_connection_is_not_left_pending(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.10:4321",
            },
            {
                "__CURSOR": "c2",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "UNetDriver::RemoveClientConnection - Removed address 192.0.2.10:4321",
            },
        ]

        _, state = parse_journal_records(records, {}, session_id=SESSION_1)

        self.assertEqual(state["pending_connections"], [])

    def test_timestamp_less_pending_state_is_discarded(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "LogNet: Join succeeded: Alice",
            },
        ]
        state = {
            "session_id": SESSION_1,
            "pending_connections": [{"address": "192.0.2.10", "port": 4321}],
        }

        events, _ = parse_journal_records(records, state, session_id=SESSION_1)

        self.assertIsNone(events[0]["remote_addr"])

    def test_extracts_a_stable_player_id_when_the_journal_exposes_one(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.10:4321",
            },
            {
                "__CURSOR": "c2",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "LogNet: Join succeeded: Alice PlayerId=EOS-ABC123",
            },
        ]

        events, _ = parse_journal_records(records, {}, session_id=SESSION_1, server_build="123")

        self.assertEqual(events[0]["player_id"], "EOS-ABC123")
        self.assertEqual(events[0]["identity_source"], "player_id")

    def test_player_name_parser_drops_metadata_suffixes(self):
        records = [
            {
                "__CURSOR": "c1",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "LogNet: Join succeeded: Alice [opaque-code] JoinCode=do-not-store Password=do-not-store",
            },
        ]

        events, _ = parse_journal_records(records, {}, session_id=SESSION_1)

        self.assertEqual(events[0]["player_name"], "Alice")
        self.assertNotIn("do-not-store", json.dumps(events[0]))

    def test_aggregates_repeated_joins_into_one_player_entry(self):
        events = [
            {
                "event": "player_joined",
                "timestamp": "2026-10-01T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice",
                "remote_addr": "192.0.2.10",
                "remote_port": 4321,
            },
            {
                "event": "player_joined",
                "timestamp": "2026-10-02T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice NewName",
                "remote_addr": "192.0.2.11",
                "remote_port": 5000,
            },
            {
                "event": "player_joined",
                "timestamp": "2026-10-03T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice NewName",
                "remote_addr": "192.0.2.11",
                "remote_port": 5001,
            },
        ]

        summary = aggregate_player_events({}, events)
        player = summary["players"]["id:EOS-ABC123"]

        self.assertEqual(len(summary["players"]), 1)
        self.assertEqual(player["join_count"], 3)
        self.assertEqual(player["first_seen"], "2026-10-01T10:00:00Z")
        self.assertEqual(player["last_seen"], "2026-10-03T10:00:00Z")
        self.assertEqual(player["names_seen"], ["Alice", "Alice NewName"])
        self.assertEqual(player["ip_history"]["192.0.2.10"]["join_count"], 1)
        self.assertEqual(player["ip_history"]["192.0.2.11"]["join_count"], 2)
        self.assertEqual(player["ip_history"]["192.0.2.11"]["ports"], {"5000": 1, "5001": 1})

    def test_name_fallback_is_explicit_and_can_be_upgraded_to_player_id(self):
        summary = aggregate_player_events(
            {},
            [
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:00:00Z",
                    "player_id": None,
                    "player_name": "Alice",
                    "remote_addr": "192.0.2.10",
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-02T10:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                    "remote_addr": "192.0.2.10",
                },
            ],
        )

        self.assertNotIn("name:alice", summary["players"])
        player = summary["players"]["id:EOS-ABC123"]
        self.assertEqual(player["join_count"], 2)
        self.assertEqual(player["identity_source"], "player_id")

    def test_id_first_name_fallback_later_merges_back_into_the_id(self):
        summary = aggregate_player_events(
            {},
            [
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": None,
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:01:00Z",
                    "player_id": None,
                    "player_name": "Alice",
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:02:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                },
            ],
        )

        self.assertEqual(list(summary["players"]), ["id:EOS-ABC123"])
        self.assertEqual(summary["players"]["id:EOS-ABC123"]["join_count"], 3)

    def test_fallback_merge_keeps_endpoint_from_latest_timestamp(self):
        summary = aggregate_player_events(
            {},
            [
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:01:00Z",
                    "player_id": None,
                    "player_name": "Alice",
                    "remote_addr": "192.0.2.10",
                    "remote_port": 4001,
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:02:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                    "remote_addr": "192.0.2.11",
                    "remote_port": 4002,
                },
            ],
        )
        player = summary["players"]["id:EOS-ABC123"]
        self.assertEqual(player["last_seen"], "2026-10-01T10:02:00Z")
        self.assertEqual(player["last_ip"], "192.0.2.11")
        self.assertEqual(player["last_port"], 4002)

    def test_same_name_multiple_ids_do_not_absorb_an_unidentified_join(self):
        summary = aggregate_player_events(
            {},
            [
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:00:00Z",
                    "player_id": "EOS-ONE",
                    "player_name": "Alice",
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:01:00Z",
                    "player_id": "EOS-TWO",
                    "player_name": "alice",
                },
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-01T10:02:00Z",
                    "player_id": None,
                    "player_name": "ALICE",
                },
            ],
        )

        self.assertEqual(summary["players"]["id:EOS-ONE"]["join_count"], 1)
        self.assertEqual(summary["players"]["id:EOS-TWO"]["join_count"], 1)
        self.assertEqual(summary["players"]["name:alice"]["join_count"], 1)

    def test_commit_drops_unallowlisted_and_secret_event_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            log.commit(
                [
                    {
                        "event": "player_joined",
                        "event_id": "c1:player_joined",
                        "timestamp": "2026-10-03T10:00:00Z",
                        "player_id": "EOS-ABC123",
                        "player_name": "Alice [JoinCode=do-not-store]",
                        "remote_addr": "192.0.2.10",
                        "remote_port": 4321,
                        "message": "raw journal line",
                        "password": "do-not-store",
                        "join_code": "do-not-store",
                    }
                ],
                {
                    "last_cursor": "c1",
                    "message": "raw state line",
                    "raw_message": "do-not-store",
                    "active_connections": {"raw": {"message": "do-not-store"}},
                },
            )

            event_text = (root / "events.jsonl").read_text()
            self.assertNotIn("do-not-store", event_text)
            self.assertNotIn("raw journal line", event_text)
            event = json.loads(event_text)
            self.assertNotIn("message", event)
            self.assertEqual(event["player_name"], "Alice")
            state_text = (root / "state.json").read_text()
            self.assertNotIn("raw state line", state_text)
            self.assertNotIn("do-not-store", state_text)

    def test_commit_requires_an_event_deduplication_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            event = {
                "event": "player_joined",
                "timestamp": "2026-10-03T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice",
            }

            log.commit([event, event], {"last_cursor": "c1"})

            self.assertEqual((root / "events.jsonl").read_text(), "")
            summary = json.loads((root / "players.json").read_text())
            self.assertEqual(summary["players"], {})

    def test_summary_input_is_allowlisted_before_reuse(self):
        clean = aggregate_player_events(
            {
                "raw_message": "do-not-store",
                "players": {
                    "id:EOS-ABC123": {
                        "player_id": "EOS-ABC123",
                        "names_seen": ["Alice"],
                        "first_seen": "2026-10-01T10:00:00Z",
                        "last_seen": "2026-10-01T10:00:00Z",
                        "join_count": 1,
                        "message": "do-not-store",
                    }
                },
            },
            [],
        )

        serialized = json.dumps(clean)
        self.assertNotIn("do-not-store", serialized)
        self.assertNotIn("message", serialized)
        self.assertEqual(clean["players"]["id:EOS-ABC123"]["join_count"], 1)

    def test_missing_systemd_session_properties_fail_closed(self):
        with self.assertRaises(RuntimeError):
            player_log._session_id("")

    def test_unset_systemd_timestamp_properties_are_not_used_as_journal_bounds(self):
        self.assertEqual(player_log._normalize_active_enter("n/a"), "")
        self.assertEqual(player_log._normalize_active_enter("0"), "")
        self.assertEqual(player_log._normalize_active_enter("Thu 1970-01-01 00:00:00 UTC"), "")

    def test_malformed_or_non_integer_ports_are_rejected(self):
        self.assertIsNone(player_log._remote_endpoint("Removed address 192.0.2.10:999999999999999999999"))
        self.assertIsNone(player_log._clean_remote_port(4321.9))

    def test_player_log_writes_summary_and_bounded_events_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root, retention_days=90)
            events = [
                {
                    "event": "player_joined",
                    "timestamp": "2026-10-03T10:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                    "remote_addr": "192.0.2.10",
                    "source_cursor": "c1",
                }
            ]

            log.commit(events, {"last_cursor": "c1", "active_connections": {}})

            self.assertEqual(json.loads((root / "players.json").read_text())["players"]["id:EOS-ABC123"]["join_count"], 1)
            self.assertEqual(json.loads((root / "state.json").read_text())["last_cursor"], "c1")
            event_lines = (root / "events.jsonl").read_text().splitlines()
            self.assertEqual(len(event_lines), 1)
            self.assertEqual(json.loads(event_lines[0])["source_cursor"], "c1")

            log.commit(events, {"last_cursor": "c1", "active_connections": {}})
            self.assertEqual(len((root / "events.jsonl").read_text().splitlines()), 1)
            self.assertEqual(json.loads((root / "players.json").read_text())["players"]["id:EOS-ABC123"]["join_count"], 1)

    def test_event_retention_does_not_delete_long_term_aggregate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root, retention_days=1)
            old_event = {
                "event": "player_joined",
                "timestamp": "2020-01-01T10:00:00Z",
                "player_id": "EOS-OLD",
                "player_name": "Old Player",
                "remote_addr": "192.0.2.20",
                "source_cursor": "old",
                "event_id": "old:player_joined",
            }
            log.commit([old_event], {"last_cursor": "old"})

            summary = json.loads((root / "players.json").read_text())
            self.assertEqual(summary["players"]["id:EOS-OLD"]["join_count"], 1)
            self.assertEqual((root / "events.jsonl").read_text(), "")

    def test_commit_recovers_an_interrupted_multi_file_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            event = {
                "event": "player_joined",
                "event_id": "c1:player_joined",
                "timestamp": "2026-10-03T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice",
                "remote_addr": "192.0.2.10",
                "remote_port": 4321,
            }
            real_replace = player_log.os.replace

            def fail_players(source, destination):
                if destination == str(root / "players.json"):
                    raise OSError("injected summary write failure")
                real_replace(source, destination)

            with mock.patch.object(player_log.os, "replace", side_effect=fail_players):
                with self.assertRaises(OSError):
                    log.commit([event], {"last_cursor": "c1"})

            recovered = PlayerLog(root)
            recovered.commit([], {"last_cursor": "c1"})
            summary = json.loads((root / "players.json").read_text())
            self.assertEqual(summary["players"]["id:EOS-ABC123"]["join_count"], 1)

    def test_journal_cursor_failure_retries_from_session_start(self):
        record = {"__CURSOR": "new", "MESSAGE": "ignored"}
        with mock.patch.object(
            player_log,
            "_run_capped",
            side_effect=[(1, "", "invalid cursor"), (0, json.dumps(record) + "\n", "")],
        ) as run:
            records, recovered = player_log._journal("dragonwilds.service", "stale", "session-start")

        self.assertTrue(recovered)
        self.assertEqual(records, [record])
        self.assertEqual(len(run.call_args_list), 2)
        self.assertNotIn("--after-cursor", run.call_args_list[1].args[0])

    def test_cursor_recovery_keeps_unseen_records_at_the_last_timestamp(self):
        records = [
            {"__CURSOR": "already", "__REALTIME_TIMESTAMP": "100", "MESSAGE": "old"},
            {"__CURSOR": "new", "__REALTIME_TIMESTAMP": "100", "MESSAGE": "new"},
            {"__CURSOR": "older", "__REALTIME_TIMESTAMP": "99", "MESSAGE": "old"},
        ]

        filtered = player_log._filter_recovered_records(
            records,
            {"last_realtime_timestamp_us": 100, "processed_cursors": ["already"]},
        )

        self.assertEqual([record["__CURSOR"] for record in filtered], ["new"])

    def test_same_session_clock_rollback_fails_closed_during_recovery(self):
        with self.assertRaises(RuntimeError):
            player_log._filter_recovered_records(
                [{"__CURSOR": "new", "__REALTIME_TIMESTAMP": "99", "MESSAGE": "old"}],
                {
                    "session_id": SESSION_1,
                    "last_realtime_timestamp_us": 100,
                    "processed_cursors": [],
                },
                SESSION_1,
            )

    def test_same_session_clock_rollback_fails_closed_during_successful_parse(self):
        with self.assertRaises(RuntimeError):
            parse_journal_records(
                [
                    {
                        "__CURSOR": "new",
                        "__REALTIME_TIMESTAMP": "99",
                        "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: 192.0.2.10:4321",
                    }
                ],
                {
                    "session_id": SESSION_1,
                    "last_realtime_timestamp_us": 100,
                },
                session_id=SESSION_1,
            )

    def test_parser_boundary_drops_untrusted_endpoint_and_state_fields(self):
        records = [
            {
                "__CURSOR": "safe-cursor",
                "__REALTIME_TIMESTAMP": "1760000000000000",
                "MESSAGE": "AddClientConnection: Added client connection RemoteAddr: [PASSWORD=secret]:4321",
            },
            {
                "__CURSOR": "safe-join",
                "__REALTIME_TIMESTAMP": "1760000001000000",
                "MESSAGE": "LogNet: Join succeeded: Alice",
                "PLAYER_ID": "EOS-ABC123",
            },
        ]
        events, state = parse_journal_records(
            records,
            {
                "message": "raw state",
                "active_connections": {
                    "bad": {"remote_addr": "[PASSWORD=secret]", "message": "raw"}
                },
            },
            session_id=SESSION_1,
            server_build="PASSWORD=secret",
        )

        serialized = json.dumps({"events": events, "state": state})
        self.assertNotIn("PASSWORD=secret", serialized)
        self.assertIsNone(events[0]["remote_addr"])
        self.assertEqual(state["active_connections"], {})

    def test_session_id_includes_boot_or_invocation_identity(self):
        first = player_log._session_id("same timestamp", "a" * 32, "11111111-1111-1111-1111-111111111111")
        second = player_log._session_id("same timestamp", "a" * 32, "22222222-2222-2222-2222-222222222222")
        third = player_log._session_id("same timestamp", "b" * 32, "11111111-1111-1111-1111-111111111111")

        self.assertNotEqual(first, second)
        self.assertNotEqual(first, third)
        self.assertIsNone(player_log._clean_session_id("mono:" + "9" * 100))

    def test_missing_state_with_retained_summary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "players.json").write_text(json.dumps({"schema": player_log.SCHEMA, "players": {}}))
            with mock.patch.object(
                player_log.sys,
                "argv",
                ["player_log.py", "--install-dir", directory, "--data-dir", directory],
            ):
                with self.assertRaises(RuntimeError):
                    player_log.main()

    def test_timestamp_offsets_are_compared_as_instants(self):
        summary = aggregate_player_events(
            {},
            [
                {
                    "event": "player_joined",
                    "event_id": "later",
                    "timestamp": "2026-10-01T11:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                },
                {
                    "event": "player_joined",
                    "event_id": "earlier",
                    "timestamp": "2026-10-01T12:00:00+02:00",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                },
            ],
        )

        player = summary["players"]["id:EOS-ABC123"]
        self.assertEqual(player["first_seen"], "2026-10-01T10:00:00Z")
        self.assertEqual(player["last_seen"], "2026-10-01T11:00:00Z")

    def test_corrupt_transaction_markers_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".transaction.json").write_text("[]")
            with self.assertRaises(RuntimeError):
                PlayerLog(root)

    def test_incomplete_transaction_does_not_mix_stale_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "players.json").write_text("{\"stale\": true}\n")
            (root / ".transaction.json").write_text(
                json.dumps({
                    "schema": player_log.SCHEMA,
                    "files": {
                        "events": {"sha256": "0" * 64},
                        "players": {"sha256": "0" * 64},
                        "state": {"sha256": "0" * 64},
                    },
                })
            )
            with self.assertRaises(RuntimeError):
                PlayerLog(root)

    def test_state_timestamp_and_counts_are_bounded(self):
        clean_state = player_log._sanitize_state({"last_realtime_timestamp_us": 10**30})
        self.assertNotIn("last_realtime_timestamp_us", clean_state)

        summary = aggregate_player_events(
            {
                "unidentified_join_count": player_log.MAX_COUNT,
                "players": {
                    "id:EOS-ABC123": {
                        "player_id": "EOS-ABC123",
                        "names_seen": ["Alice"],
                        "first_seen": "2026-10-01T10:00:00Z",
                        "last_seen": "2026-10-01T10:00:00Z",
                        "join_count": player_log.MAX_COUNT,
                    }
                },
            },
            [
                {
                    "event": "player_joined",
                    "event_id": "c1",
                    "timestamp": "2026-10-01T10:01:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                },
                {
                    "event": "player_joined",
                    "event_id": "c2",
                    "timestamp": "2026-10-01T10:01:00Z",
                    "player_id": None,
                    "player_name": None,
                },
            ],
        )
        self.assertEqual(summary["players"]["id:EOS-ABC123"]["join_count"], player_log.MAX_COUNT)
        self.assertEqual(summary["unidentified_join_count"], player_log.MAX_COUNT)

    def test_embedded_secret_markers_are_rejected_from_names_and_ids(self):
        self.assertIsNone(player_log._clean_player_name("AliceWorldPassword=xyz"))
        self.assertIsNone(player_log._clean_player_name("AliceJoinCode=xyz"))
        self.assertIsNone(player_log._clean_player_name("Alice API_KEY=xyz"))
        self.assertIsNone(player_log._clean_player_name("AliceCredential=xyz"))
        self.assertIsNone(player_log._clean_player_name("Alice passphrase=xyz"))
        self.assertIsNone(player_log._clean_identifier("AlicePassword=xyz"))

    def test_future_and_malformed_timestamps_are_not_persisted(self):
        self.assertIsNone(
            player_log._sanitize_event(
                {
                    "event": "player_joined",
                    "event_id": "future",
                    "timestamp": "9999-12-31T23:59:59Z",
                    "player_name": "Alice",
                },
                require_key=True,
            )
        )
        _, state = parse_journal_records(
            [{"__CURSOR": "bad-time", "MESSAGE": "Join succeeded: Alice"}],
            {},
            session_id=SESSION_1,
        )
        self.assertEqual(state["last_cursor"], "bad-time")
        self.assertEqual(state["processed_cursors"], ["bad-time"])

    def test_missing_summary_rebuilds_from_retained_events(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            event = {
                "event": "player_joined",
                "event_id": "c1",
                "timestamp": "2026-10-01T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice",
            }
            log.commit([event], {"last_cursor": "c1"})
            (root / "players.json").unlink()

            log.commit([], {"last_cursor": "c1"})

            summary = json.loads((root / "players.json").read_text())
            self.assertEqual(summary["players"]["id:EOS-ABC123"]["join_count"], 1)

    def test_incomplete_summary_is_rejected_against_retained_events(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            event = {
                "event": "player_joined",
                "event_id": "c1:player_joined",
                "timestamp": "2026-10-03T10:00:00Z",
                "player_id": "EOS-ABC123",
                "player_name": "Alice",
                "source_cursor": "c1",
            }
            log.commit([event], {"last_cursor": "c1"})
            incomplete = aggregate_player_events([], [])
            (root / "players.json").write_text(json.dumps(incomplete))
            with self.assertRaises(RuntimeError):
                PlayerLog(root).commit([], {"last_cursor": "c1"})

    def test_malformed_event_lines_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            (root / "events.jsonl").write_text("not-json\n")
            with self.assertRaises(RuntimeError):
                log.commit([], {"last_cursor": "c1"})

    def test_non_regular_persistence_paths_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            (root / "state.json").symlink_to(root / "outside-state.json")
            with self.assertRaises(RuntimeError):
                log.load_state()
            (root / "state.json").unlink()
            os.mkfifo(root / "events.jsonl")
            with self.assertRaises(RuntimeError):
                log._load_events()

    def test_incomplete_state_and_missing_history_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            log.commit([], {"last_cursor": "prior"})
            (root / "players.json").unlink()
            (root / "events.jsonl").unlink()
            with self.assertRaises(RuntimeError):
                PlayerLog(root).commit([], {"last_cursor": "new"})

    def test_state_with_only_a_session_marker_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            (root / "state.json").write_text(json.dumps({"session_id": SESSION_1}))
            with self.assertRaises(RuntimeError):
                log.load_state()

    def test_missing_event_file_with_existing_summary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            log.commit(
                [{
                    "event": "player_joined",
                    "event_id": "c1:player_joined",
                    "source_cursor": "c1",
                    "timestamp": "2026-10-03T10:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                }],
                {"last_cursor": "c1"},
            )
            (root / "events.jsonl").unlink()
            with self.assertRaises(RuntimeError):
                PlayerLog(root).commit([], {"last_cursor": "c1"})

    def test_malformed_nested_summary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = PlayerLog(root)
            log.commit(
                [{
                    "event": "player_joined",
                    "event_id": "c1:player_joined",
                    "source_cursor": "c1",
                    "timestamp": "2026-10-03T10:00:00Z",
                    "player_id": "EOS-ABC123",
                    "player_name": "Alice",
                }],
                {"last_cursor": "c1"},
            )
            summary = json.loads((root / "players.json").read_text())
            summary["players"]["id:EOS-ABC123"]["last_ip"] = "not-an-ip"
            (root / "players.json").write_text(json.dumps(summary))
            with self.assertRaises(RuntimeError):
                PlayerLog(root).commit([], {"last_cursor": "c1"})

    def test_manifest_symlink_and_fifo_are_ignored_without_blocking(self):
        with tempfile.TemporaryDirectory() as directory:
            install = Path(directory)
            manifest = install / "steamapps/appmanifest_4019830.acf"
            manifest.parent.mkdir(parents=True)
            (install / "outside.acf").write_text('"buildid" "123"')
            manifest.symlink_to(install / "outside.acf")
            self.assertEqual(player_log._server_build(install), "")
            manifest.unlink()
            os.mkfifo(manifest)
            self.assertEqual(player_log._server_build(install), "")

    def test_retention_days_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                PlayerLog(root, retention_days=-1)
            with self.assertRaises(ValueError):
                PlayerLog(root, retention_days=player_log.MAX_RETENTION_DAYS + 1)

    def test_journal_decode_is_bounded(self):
        output = "\n".join(json.dumps({"__CURSOR": str(index)}) for index in range(player_log.MAX_JOURNAL_RECORDS + 1))
        with self.assertRaises(RuntimeError):
            player_log._decode_journal(output)
        with self.assertRaises(RuntimeError):
            player_log._decode_journal('{"__CURSOR":"ok"}\nnot-json\n')


if __name__ == "__main__":
    unittest.main()
