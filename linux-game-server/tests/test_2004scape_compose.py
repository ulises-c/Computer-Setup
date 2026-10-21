from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


def load_compose(name: str) -> dict:
    path = ROOT / name / "docker-compose.yml"
    if not path.is_file():
        raise AssertionError(f"missing deployment compose: {path}")
    return yaml.safe_load(path.read_text())


class ComposeSafetyTests(unittest.TestCase):
    def test_lost_city_is_host_networked_and_data_is_outside_checkout(self):
        config = load_compose("lostcity")
        service = config["services"]["lostcity"]

        self.assertEqual(service["network_mode"], "host")
        self.assertNotIn("ports", service)
        self.assertEqual(service["restart"], "unless-stopped")
        self.assertIn("no-new-privileges:true", service["security_opt"])
        self.assertTrue(any(
            volume.get("target") == "/opt/server"
            and "LOSTCITY_RUNTIME_DIR" in volume.get("source", "")
            for volume in service["volumes"]
        ))
        self.assertIn("bootstrap", config["services"])
        self.assertIn("bootstrap", config["services"]["bootstrap"]["profiles"])

    def test_lost_city_image_supplies_bun_required_by_engine_scripts(self):
        dockerfile = (ROOT / "lostcity" / "Dockerfile").read_text()
        bootstrap = (ROOT / "lostcity" / "bootstrap-container.sh").read_text()

        self.assertIn("oven/bun:debian", dockerfile)
        self.assertIn("/usr/local/bin/bun", dockerfile)
        self.assertIn("bun install", bootstrap)
        self.assertIn("bun run setup", bootstrap)

    def test_rs_sdk_is_host_networked_with_private_persistent_data(self):
        config = load_compose("rs-sdk")
        service = config["services"]["rs-sdk"]

        self.assertEqual(service["network_mode"], "host")
        self.assertNotIn("ports", service)
        self.assertEqual(service["restart"], "unless-stopped")
        self.assertIn("no-new-privileges:true", service["security_opt"])
        self.assertTrue(any(
            volume.get("target") == "/opt/server/data"
            and "RS_SDK_DATA_DIR" in volume.get("source", "")
            for volume in service["volumes"]
        ))
        self.assertEqual(service["environment"]["NODE_PORT"], "43595")
        self.assertEqual(service["environment"]["GATEWAY_PUBLIC_PORT"], "7781")

    def test_tailnet_routes_use_separate_root_ports(self):
        serve_conf = (ROOT / "serve.conf").read_text()
        for route in (
            '"9444 / http://127.0.0.1:8888"',
            '"9445 / http://127.0.0.1:8080"',
            '"9446 / http://127.0.0.1:7781"',
        ):
            with self.subTest(route=route):
                self.assertIn(route, serve_conf)


if __name__ == "__main__":
    unittest.main()
