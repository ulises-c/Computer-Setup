from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent


def card(source, name):
    return source.split(f'    - {name}:', 1)[1].split('\n    - ', 1)[0]


class HomepageCardTests(unittest.TestCase):
    def setUp(self):
        self.services = (ROOT / "homepage" / "services.local.yaml").read_text()
        self.lostcity = card(self.services, '"Lost City: 2004Scape"')
        self.rs_sdk = card(self.services, '"RS-SDK: bot server"')

    def test_both_stacks_link_their_tailnet_entrypoints(self):
        self.assertIn("id: lostcity-server", self.lostcity)
        self.assertIn(":9444/rs2.cgi", self.lostcity)
        self.assertIn("id: rs-sdk-server", self.rs_sdk)
        self.assertIn("href: https://{{HOMEPAGE_VAR_GAME_HOMEPAGE_DOMAIN}}/rs-sdk/\n", self.rs_sdk)

    def test_cards_read_the_loopback_status_producer(self):
        for text, stack in ((self.lostcity, "lostcity"), (self.rs_sdk, "rs-sdk")):
            with self.subTest(stack=stack):
                self.assertIn(f"url: http://127.0.0.1:8097/{stack}-status.json", text)
                self.assertIn("refreshInterval: 15000", text)
                for field in ("status", "software_summary", "rules_summary", "cpu_summary", "memory_summary",
                              "players_summary", "connect_lan", "storage_summary", "maintenance_summary",
                              "next_maintenance", "backup_status", "last_backup"):
                    self.assertIn(f"field: {field}\n", text)
        self.assertNotIn("8080/engine-status\n          refreshInterval", self.rs_sdk)

    def test_cards_have_the_same_rows_so_they_are_the_same_height(self):
        def labels(text):
            return [line.split("label: ", 1)[1] for line in text.splitlines() if "label: " in line]
        self.assertEqual(len(labels(self.lostcity)), len(labels(self.rs_sdk)))
        self.assertEqual(labels(self.lostcity)[1:], labels(self.rs_sdk)[1:])

    def test_bot_server_is_visibly_distinct_from_vanilla(self):
        self.assertIn("icon: /icons/lostcity.jpg", self.lostcity)
        self.assertIn("icon: mdi-robot", self.rs_sdk)
        css = (REPO / "server-base" / "homepage" / "custom.css").read_text()
        self.assertIn('url("/images/lostcity-title.jpg")', css)
        self.assertIn('url("/images/runescape-logo.png")', css)
        self.assertIn('url("/images/rs-sdk-lava-maze.jpg")', css)
        self.assertIn('content: "BOT SERVER"', css)
        assets = (REPO / "server-base" / "homepage" / "fetch-assets.sh").read_text()
        for asset in ("icons/lostcity.jpg", "images/lostcity-title.jpg", "images/runescape-logo.png|",
                      "images/rs-sdk-lava-maze.jpg"):
            self.assertIn(asset, assets)

    def test_generated_config_carries_the_cards(self):
        generated = (ROOT / "homepage" / "config" / "services.yaml").read_text()
        self.assertIn(self.lostcity.strip(), generated)
        self.assertIn(self.rs_sdk.strip(), generated)
        self.assertIn(card(self.services, '"Darkan: 2012 server"').strip(), generated)

    def test_darkan_card_reads_every_field_the_producer_writes(self):
        darkan = card(self.services, '"Darkan: 2012 server"')
        self.assertIn("url: http://127.0.0.1:8097/darkan-status.json", darkan)
        self.assertIn("container: darkan-world", darkan)
        fields = [line.split("field: ", 1)[1] for line in darkan.splitlines() if "field: " in line]
        source = (ROOT / "2004scape" / "game_status.py").read_text()
        for field in fields:
            with self.subTest(field=field):
                self.assertIn(f"'{field}'" if f"'{field}'" in source else f"{field}=", source)
        labels = [line for line in darkan.splitlines() if "label: " in line]
        self.assertEqual(len(labels), len([line for line in self.rs_sdk.splitlines() if "label: " in line]))


if __name__ == "__main__":
    unittest.main()
