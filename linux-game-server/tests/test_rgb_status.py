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
        self.assertEqual(devices[0]["name"], "HP Omen 30L")
        self.assertEqual(devices[0]["type"], "Motherboard")
        self.assertEqual(devices[0]["mode"], "Static")
        self.assertEqual(devices[0]["zones"], 6)
        self.assertEqual(devices[0].get("zone_details"), [
            {"name": name, "status": "detected", "color": None, "readback": False}
            for name in ["Logo", "Bar", "Front Fan", "Bottom Fan LED", "Middle Fan LED", "Top Fan LED"]
        ])
        self.assertEqual(devices[0]["available_modes"], ["Direct","Static","Breathing","Color Cycle"])
        self.assertEqual(devices[0]["mode_source"], "last-set / device-wide; not hardware readback")
        self.assertEqual(devices[0]["led_names"], ["Logo","Bar"])
        self.assertEqual(devices[1]["mode"], "Direct")

    def test_empty_output(self):
        self.assertEqual(rgb.parse(""), [])


if __name__ == "__main__":
    unittest.main()
