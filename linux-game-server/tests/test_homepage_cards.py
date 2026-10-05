"""Keep the two Dragonwilds cards scoped and generator output authoritative."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HomepageCardsTests(unittest.TestCase):
    def test_openrgb_card_uses_exported_zone_policy_rows_and_freshness(self):
        source = (ROOT / 'homepage/services.local.yaml').read_text()
        self.assertIn('    - OpenRGB:', source)
        card = source.split('    - OpenRGB:', 1)[1].split('\n- Games:', 1)[0]
        self.assertIn('id: openrgb-lighting', card)
        self.assertIn('widgets:', card)
        self.assertIn('items: rows', card)
        self.assertIn('name: name', card)
        self.assertIn('label: label', card)
        self.assertNotIn('items: devices', card)
        self.assertIn('field: updated', card)
        self.assertIn('scale: 1000', card, 'epoch seconds must become milliseconds')
        self.assertIn('format: relativeDate', card)
        self.assertEqual(card.count('refreshInterval: 300000'), 2)
        self.assertIn('colours cannot be read back', card)
        generated = (ROOT / 'homepage/config/services.yaml').read_text()
        self.assertIn(card.strip(), generated)

    def test_primary_card_is_software_and_secondary_card_is_world(self):
        text = (ROOT / 'homepage/services.local.yaml').read_text().split('- Games:', 1)[1]
        self.assertIn('- "RuneScape: Dragonwilds":', text)
        primary, world = text.split('    - Active world:', 1)
        for field in ('software_summary', 'installation_footprint', 'cpu_summary', 'memory_summary',
                      'sample_window', 'process_summary', 'worlds_summary', 'uptime_display'):
            self.assertIn('field: ' + field + '\n', primary)
        for field in ('online_capacity', 'player_names', 'last_join', 'last_join_name', 'join_password'):
            self.assertNotIn('field: ' + field + '\n', primary)
            self.assertIn('field: ' + field + '\n', world)
        self.assertNotIn('format: duration', text)
        self.assertEqual(text.count('refreshInterval: 5000'), 2)
        self.assertNotIn('disk_free_bytes', text)
        self.assertNotIn('container: dragonwilds-status', text,
                         'nginx state must not masquerade as game or world health')
        generated = (ROOT / 'homepage/config/services.yaml').read_text()
        self.assertIn(text.strip(), generated)


if __name__ == '__main__':
    unittest.main()
