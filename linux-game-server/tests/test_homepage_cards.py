"""Keep the two Dragonwilds cards scoped and generator output authoritative."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HomepageCardsTests(unittest.TestCase):
    def test_primary_card_is_software_and_secondary_card_is_world(self):
        text = (ROOT / 'homepage/services.local.yaml').read_text().split('- Games:', 1)[1]
        self.assertIn('- "RuneScape: Dragonwilds":', text)
        primary, world = text.split('    - Active world:', 1)
        for field in ('game_version', 'build', 'installation_footprint', 'cpu_current', 'cpu_avg',
                      'cpu_max', 'memory_current', 'memory_avg', 'memory_max', 'sample_window',
                      'tasks_current', 'restarts', 'world_count'):
            self.assertIn('field: ' + field + '\n', primary)
        for field in ('online_capacity', 'player_names', 'last_join', 'last_join_name', 'join_password'):
            self.assertNotIn('field: ' + field + '\n', primary)
            self.assertIn('field: ' + field + '\n', world)
        self.assertNotIn('disk_free_bytes', text)
        self.assertNotIn('container: dragonwilds-status', text,
                         'nginx state must not masquerade as game or world health')
        generated = (ROOT / 'homepage/config/services.yaml').read_text()
        self.assertIn(text.strip(), generated)


if __name__ == '__main__':
    unittest.main()
