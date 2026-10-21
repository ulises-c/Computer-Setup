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

    def test_lost_city_git_metadata_is_read_only_in_the_game(self):
        # The host runs git on these checkouts; a writable .git would let the game
        # plant config (filters, ext:: remotes) that git executes on the host.
        service = load_compose("lostcity")["services"]["lostcity"]
        read_only = {v["target"] for v in service["volumes"] if v.get("read_only")}
        for repo in ("engine", "content", "webclient"):
            with self.subTest(repo=repo):
                self.assertIn(f"/opt/server/{repo}/.git", read_only)
        self.assertEqual(service["environment"]["HUSKY"], "0")

    def test_game_containers_opt_out_of_watchtower(self):
        # Their images are local builds under an unregistered Hub namespace, and a
        # watchtower restart would skip the in-game countdown.
        for name, service in (("lostcity", "lostcity"), ("rs-sdk", "rs-sdk")):
            with self.subTest(service=service):
                labels = load_compose(name)["services"][service]["labels"]
                self.assertIn("com.centurylinklabs.watchtower.enable=false", labels)

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

    def test_rs_sdk_internal_servers_avoid_lost_city_ports(self):
        # Both stacks share the host network. Lost City's setup wizard uses the
        # engine defaults, so RS-SDK must move every internal server off them, or
        # it would join Lost City's login/friend server instead of its own.
        lost_city_defaults = {"WEB_PORT": "8888", "WEB_MANAGEMENT_PORT": "8898", "NODE_PORT": "43594",
                              "LOGIN_PORT": "43500", "FRIEND_PORT": "45099", "LOGGER_PORT": "43501"}
        env = load_compose("rs-sdk")["services"]["rs-sdk"]["environment"]
        for key, taken in lost_city_defaults.items():
            with self.subTest(key=key):
                self.assertIn(key, env)
                self.assertNotEqual(env[key], taken)
        for key in ("LOGIN_HOST", "FRIEND_HOST", "LOGGER_HOST"):
            with self.subTest(key=key):
                self.assertEqual(env[key], "127.0.0.1")
        rs_sdk_ports = {env[k] for k in ("WEB_PORT", "WEB_MANAGEMENT_PORT", "NODE_PORT", "LOGIN_PORT",
                                         "FRIEND_PORT", "LOGGER_PORT", "AGENT_PORT", "GATEWAY_PUBLIC_PORT")}
        self.assertEqual(len(rs_sdk_ports), 8)
        activate = (ROOT / "2004scape" / "activate.sh").read_text()
        for port in rs_sdk_ports | set(lost_city_defaults.values()):
            with self.subTest(port=port):
                self.assertIn(f'"{port}"', activate)

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
