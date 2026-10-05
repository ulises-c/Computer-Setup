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

    def test_compact_server_inventory_is_consistent_and_native_facts_are_hourly(self):
        for host in FLEET['hosts']:
            for server in FLEET['servers']:
                card = generate.server_card(server,host)[server['name']]
                self.assertEqual(card.get('id'), 'server-'+server['key'])
                widgets = card['widgets']
                self.assertEqual(len(widgets),3)
                self.assertEqual([m['label'] for w in widgets for m in w['mappings']],
                                 ['Platform','Board / SoC','CPU','Memory','Graphics','Software'])
                self.assertEqual(widgets[1]['mappings'][0]['scale'],'1/1073741824')
                self.assertEqual(widgets[1]['mappings'][0]['suffix'],'GiB usable')
                software=widgets[2]['mappings'][1]
                self.assertEqual(software['field'],'linux_distro')
                self.assertEqual(software['additionalField']['field'],'os_version')
                self.assertEqual([w['refreshInterval'] for w in widgets],[3600000]*3)
                self.assertIn(server['facts']['platform'], str(widgets))
                self.assertIn(server['facts']['graphics'], str(widgets))

    def test_game_host_top_bar_carries_no_rgb(self):
        # Lighting lives on the OpenRGB card; the top bar has no RGB tile, chip or URL.
        top = FLEET["hosts"]["linux-game-server"]["topbar"]
        self.assertNotIn("rgb", top)
        repo = ROOT.parent
        settings = (repo / "linux-game-server/homepage/config/settings.yaml").read_text()
        self.assertNotIn("rgb", settings.lower())
        self.assertNotIn("host-status", settings)
        self.assertIn("grouped: true", settings)
        self.assertNotIn("rgb", (ROOT / "homepage/grouped-topbar.js").read_text().lower())
        self.assertNotIn("rgb", (repo / "linux-game-server/homepage/config/custom.js").read_text().lower())

    def test_top_bar_rgb_url_is_rejected_so_it_cannot_return_by_config(self):
        import copy
        fleet = copy.deepcopy(FLEET)
        fleet["hosts"]["linux-game-server"]["topbar"]["rgb"] = "/host-status/rgb.json"
        with self.assertRaisesRegex(ValueError, "OpenRGB card"):
            generate.render_settings(fleet, "linux-game-server", "")

    def test_grouped_storage_contract_and_host_capabilities_are_explicit(self):
        import copy
        fleet = copy.deepcopy(FLEET)
        for host in fleet['hosts']:
            top = fleet['hosts'][host]['topbar']
            top.update(grouped=True, safeSSDHealth=False, filesystemIntervalMs=600000,
                       smartIntervalMs=900000, wifi=host == 'linux-pi',
                       gpu=host != 'linux-pi', diskLabels={'/etc/hostname': 'System SSD'},
                       temperatureLabels=['NVMe'])
            text = generate.render_settings(fleet, host, '')
            for expected in ['safeSSDHealth: false', 'filesystemIntervalMs: 600000', 'smartIntervalMs: 900000',
                             'diskLabels:', 'temperatureLabels:', 'wifi:', 'gpu:']:
                self.assertIn(expected, text, host)
            css = generate.render_css(fleet, host)
            self.assertIn('@media (scripting:enabled)', css)
            self.assertIn('Host metrics loading', css)
            self.assertIn('monitor-native-fallback', css)
            self.assertIn('data:image/svg+xml,', css)

    def test_hdds_are_declared_per_host_and_never_polled_or_displayed(self):
        import copy
        fleet = copy.deepcopy(FLEET)
        main = fleet['hosts']['linux-server']['topbar']
        self.assertEqual(sorted(main['hddDisks']), ['/mnt/seagate4tb', '/mnt/wd14tb', '/mnt/wd1tb'])
        self.assertTrue(set(main['hddDisks']) <= set(main['disks']))
        main['grouped'] = True
        settings = generate.render_settings(fleet, 'linux-server', '')
        for mount in main['hddDisks']:
            self.assertIn(f'- \"{mount}\"', settings.split('hddDisks:')[1])
        css = generate.render_css(fleet, 'linux-server')
        self.assertEqual(css.count('Not monitored'), 0)  # skeleton is URL-encoded inside the SVG data URI
        from urllib.parse import quote
        self.assertGreaterEqual(css.count(quote('Not monitored · HDD', safe='')), 3)
        self.assertNotIn('storageMetadataUrl', settings)
        for host in ('linux-pi', 'linux-game-server'):
            self.assertNotIn('hddDisks', fleet['hosts'][host]['topbar'])

    def test_ssd_health_requests_are_opt_in_per_host(self):
        # Game keeps its existing NVMe health (backend is NVMe-only and cached);
        # main stays off until the parent verifies it, Pi has no NVMe at all.
        hosts = FLEET['hosts']
        self.assertTrue(hosts['linux-game-server']['topbar']['safeSSDHealth'])
        self.assertFalse(hosts['linux-server']['topbar']['safeSSDHealth'])
        self.assertFalse(hosts['linux-pi']['topbar']['safeSSDHealth'])
        self.assertNotIn('temperatureLabels', hosts['linux-pi']['topbar'])
        for host in hosts.values():
            self.assertGreaterEqual(host['topbar']['filesystemIntervalMs'], 300000)
            self.assertGreaterEqual(host['topbar']['smartIntervalMs'], 600000)

    def test_tile_heights_follow_each_hosts_row_counts_and_match_live_css(self):
        import copy, re
        fleet = copy.deepcopy(FLEET)
        fleet['hosts']['linux-game-server']['topbar']['grouped'] = True
        css = generate.render_css(fleet, 'linux-game-server')
        root = re.search(r'#information-widgets \{([^}]*--monitor-h-[^}]*)\}', css).group(1)
        # dGPU: 5 rows; NVMe+health: 4 rows; CPU: 4 rows. 106 + 18n, 94 + 18n, 80 + 18n.
        self.assertIn('--monitor-h-gpu: 196px', root)
        self.assertIn('--monitor-h-storage: 166px', root)
        self.assertIn('--monitor-h-compute: 152px', root)
        live = (generate.HERE / 'grouped-topbar.css').read_text()
        for var in ('compute', 'gpu', 'storage', 'net', 'system'):
            self.assertIn(f'var(--monitor-h-{var}', live)
        # An iGPU with only a Usage row is not given a dGPU-sized tile.
        main = copy.deepcopy(FLEET)
        main['hosts']['linux-server']['topbar']['grouped'] = True
        def root_vars(css):
            return re.search(r'#information-widgets \{([^}]*--monitor-h-[^}]*)\}', css).group(1)
        self.assertIn('--monitor-h-gpu: 124px', root_vars(generate.render_css(main, 'linux-server')))
        # Hosts with no GPU declare no GPU height at all (Pi).
        pi = copy.deepcopy(FLEET)
        pi['hosts']['linux-pi']['topbar']['grouped'] = True
        self.assertNotIn('--monitor-h-gpu', root_vars(generate.render_css(pi, 'linux-pi')))

    def test_skeleton_reserves_health_rows_only_when_the_host_opts_in(self):
        import copy
        from urllib.parse import quote
        fleet = copy.deepcopy(FLEET)
        for host in ('linux-game-server', 'linux-server'):
            fleet['hosts'][host]['topbar']['grouped'] = True
        game = generate.render_css(fleet, 'linux-game-server')
        main = generate.render_css(fleet, 'linux-server')
        self.assertIn(quote('<dt>Health</dt>', safe=''), game)
        self.assertNotIn(quote('<dt>Health</dt>', safe=''), main)

    def test_storage_columns_scale_with_many_disks_to_keep_main_topbar_short(self):
        import copy
        fleet = copy.deepcopy(FLEET)
        fleet['hosts']['linux-server']['topbar']['grouped'] = True
        css = generate.render_css(fleet, 'linux-server')
        self.assertIn('--monitor-storage-cols: 3', css)
        fleet['hosts']['linux-game-server']['topbar']['grouped'] = True
        self.assertIn('--monitor-storage-cols: 2', generate.render_css(fleet, 'linux-game-server'))

    def test_emitted_strings_are_quoted(self):
        lines = generate.emit([{"g": [{"svc": {"description": "NAS: storage", "n": 4, "b": True}}]}])
        self.assertIn('        description: "NAS: storage"', lines)
        self.assertIn("        n: 4", lines)
        self.assertIn("        b: true", lines)


if __name__ == "__main__":
    unittest.main()
