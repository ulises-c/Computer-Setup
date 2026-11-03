import unittest

import controller


class ControllerDefaultTests(unittest.TestCase):
    def test_missing_group_defaults_to_misc(self):
        registry = {'version': 1, 'excludedBots': ['bot_tester'], 'routines': [
            {'id': 'example', 'label': 'Example', 'runner': 'session', 'routine': 'example', 'denyBots': ['bot_pioneer'], 'args': []},
        ]}
        routine = controller.parse_registry(registry)['routines'][0]
        self.assertEqual((routine['category'], routine['group'], routine['method']), ('misc', 'Misc', 'Example'))


if __name__ == '__main__':
    unittest.main()
