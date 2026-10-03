#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("rgb", Path(__file__).resolve().parents[1] / "rgb/rgb-status.py")
rgb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rgb)

SAMPLE = """0: HP Omen 30L
  Type:           Motherboard
  Description:    HP Omen 30L Device
  Location:       HID: /dev/hidraw0
  Modes: Direct [Static] Breathing 'Color Cycle'
  Zones: Logo Bar 'Front Fan' 'Bottom Fan LED' 'Middle Fan LED' 'Top Fan LED'
  LEDs: Logo Bar

1: Other
  Modes: [Direct]
"""


class ParseTests(unittest.TestCase):
    def test_devices_modes_and_zones(self):
        devices = rgb.parse("<h2>warning</h2>\n" + SAMPLE)
        self.assertEqual(devices[0], {"name": "HP Omen 30L", "type": "Motherboard", "mode": "Static", "zones": 6})
        self.assertEqual(devices[1]["mode"], "Direct")

    def test_empty_output(self):
        self.assertEqual(rgb.parse(""), [])


if __name__ == "__main__":
    unittest.main()
