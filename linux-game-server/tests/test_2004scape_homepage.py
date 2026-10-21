from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class HomepageCardTests(unittest.TestCase):
    def test_both_stacks_have_lan_and_tailnet_links(self):
        services = (ROOT / "homepage" / "services.local.yaml").read_text()
        for marker in (
            "id: lostcity-server",
            "id: rs-sdk-server",
            ":9444/rs2.cgi",
            ":9445/",
            "LAN :8888",
            "LAN :8080",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, services)


if __name__ == "__main__":
    unittest.main()
