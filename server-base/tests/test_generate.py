#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generate", ROOT / "homepage/generate.py")
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)
FLEET = json.loads((ROOT / "fleet.json").read_text())


class GenerateTests(unittest.TestCase):
    def test_outputs_are_current(self):
        self.assertEqual(generate.main(["generate.py", "--check"]), 0)

    def test_every_host_lists_every_server_and_only_its_own_unlinked(self):
        names = [s["name"] for s in FLEET["servers"]]
        for host in FLEET["hosts"]:
            cards = [generate.server_card(s, host) for s in FLEET["servers"]]
            self.assertEqual([next(iter(c)) for c in cards], names)
            unlinked = [s["dir"] for s, c in zip(FLEET["servers"], cards) if "href" not in c[s["name"]]]
            self.assertEqual(unlinked, [host])

    def test_shared_services_only_on_other_hosts(self):
        shared_dir = next(s["dir"] for s in FLEET["servers"] if s["key"] == FLEET["shared_services"]["host"])
        group = f"- {FLEET['shared_services']['group']}:"
        for host in FLEET["hosts"]:
            text = (ROOT.parent / host / "homepage/config/services.yaml").read_text()
            self.assertEqual(group in text, host != shared_dir, host)

    def test_every_group_has_an_accent(self):
        for host, cfg in FLEET["hosts"].items():
            text = (ROOT.parent / host / "homepage/config/services.yaml").read_text()
            groups = {line[2:-1] for line in text.splitlines() if line.startswith("- ") and line.endswith(":")}
            nested = {line.strip()[2:-1] for line in text.splitlines()
                      if line.startswith("    - ") and line.endswith(":") and not line.startswith("     ")}
            headed = (groups | {g for g in nested if g in cfg["accents"]}) - {"Core"}
            self.assertEqual(sorted(headed - set(cfg["accents"])), [], host)

    def test_top_bar_is_this_hosts_own_glances(self):
        for host, cfg in FLEET["hosts"].items():
            own = next(s for s in FLEET["servers"] if s["dir"] == host)
            widgets = (ROOT.parent / host / "homepage/config/widgets.yaml").read_text()
            self.assertIn(f'url: "{generate.LOCAL_GLANCES}"', widgets, host)
            for disk in cfg["topbar"]["disks"]:
                self.assertIn(f'- "{disk}"', widgets, host)
            settings = (ROOT.parent / host / "homepage/config/settings.yaml").read_text()
            self.assertIn(f'  glances: "{own["glances_url"]}"', settings, host)

    def test_server_cards_carry_no_live_widgets(self):
        for host in FLEET["hosts"]:
            for server in FLEET["servers"]:
                card = generate.server_card(server, host)[server["name"]]
                for widget in card.get("widgets", []):
                    self.assertEqual(widget["refreshInterval"], 3600000, (host, server["name"]))

    def test_grouped_renderer_is_opt_in_and_other_hosts_are_byte_identical(self):
        import copy
        original = copy.deepcopy(FLEET)
        original["hosts"]["linux-game-server"]["topbar"].pop("grouped", None)
        grouped = copy.deepcopy(original)
        grouped["hosts"]["linux-game-server"]["topbar"]["grouped"] = True
        before = dict(generate.outputs(original))
        after = dict(generate.outputs(grouped))
        changed = [str(p.relative_to(ROOT.parent)) for p in after if after[p] != before[p]]
        self.assertEqual(sorted(changed), sorted([
            "linux-game-server/homepage/config/custom.js",
            "linux-game-server/homepage/config/custom.css",
            "linux-game-server/homepage/config/settings.yaml",
        ]))
        self.assertIn("grouped: true", generate.render_settings(grouped, "linux-game-server", ""))
        js = generate.render_js(grouped, "linux-game-server")
        self.assertNotIn("new MutationObserver(render)", js)
        self.assertNotIn("const chip =", js)
        self.assertIn("const start =", js)

    def test_gpu_inventory_only_emitted_for_opted_in_host(self):
        import copy
        fleet = copy.deepcopy(FLEET)
        fleet['hosts']['linux-game-server']['topbar']['gpuTypes'] = {'nvidia0':'dGPU'}
        self.assertIn('nvidia0: "dGPU"', generate.render_settings(fleet,'linux-game-server',''))
        self.assertNotIn('gpuTypes', generate.render_settings(fleet,'linux-server',''))
        self.assertNotIn('gpuTypes', generate.render_settings(fleet,'linux-pi',''))

    def test_emitted_strings_are_quoted(self):
        lines = generate.emit([{"g": [{"svc": {"description": "NAS: storage", "n": 4, "b": True}}]}])
        self.assertIn('        description: "NAS: storage"', lines)
        self.assertIn("        n: 4", lines)
        self.assertIn("        b: true", lines)


if __name__ == "__main__":
    unittest.main()
