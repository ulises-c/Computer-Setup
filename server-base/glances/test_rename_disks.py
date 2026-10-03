import contextlib
import io
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import rename_disks


class RenameDisksTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.labels = self.root / "labels"
        self.devices = self.root / "devices"
        self.sys_block = self.root / "sys-block"
        self.labels.mkdir()
        self.devices.mkdir()
        self.sys_block.mkdir()
        self.env = patch.dict(
            os.environ,
            {
                "GLANCES_DISK_LABEL_DIR": str(self.labels),
                "GLANCES_SYS_BLOCK_DIR": str(self.sys_block),
            },
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def add_partition(self, label, partition, parent):
        (self.devices / partition).touch()
        (self.labels / label).symlink_to(self.devices / partition)
        sys_parent = self.root / "sys-devices" / parent
        sys_partition = sys_parent / partition
        sys_partition.mkdir(parents=True)
        (sys_partition / "partition").touch()
        (self.sys_block / partition).symlink_to(sys_partition)

    def test_resolves_sd_nvme_and_mmc_parents(self):
        self.add_partition("Seagate_4TB", "sda1", "sda")
        self.add_partition("WD_1TB", "nvme0n1p2", "nvme0n1")
        self.add_partition("WD14TB", "mmcblk0p1", "mmcblk0")

        self.assertEqual(
            rename_disks.resolve_aliases(),
            {"sda": "Seagate_4TB", "nvme0n1": "WD_1TB", "mmcblk0": "WD14TB"},
        )

    def test_rechecks_late_and_reshuffled_devices(self):
        self.assertEqual(rename_disks.resolve_aliases(), {})
        self.add_partition("WD_1TB", "sdb1", "sdb")
        self.assertEqual(rename_disks.resolve_aliases(), {"sdb": "WD_1TB"})

        (self.labels / "WD_1TB").unlink()
        self.add_partition("WD_1TB", "nvme1n1p1", "nvme1n1")
        self.assertEqual(rename_disks.resolve_aliases(), {"nvme1n1": "WD_1TB"})

    def test_patch_renames_stats_and_logs_installation(self):
        self.add_partition("Seagate_4TB", "sda1", "sda")

        class DiskioPlugin:
            def get_raw(self):
                return [{"disk_name": "sda"}, {"disk_name": "nvme0n1"}]

        glances = types.ModuleType("glances")
        plugins = types.ModuleType("glances.plugins")
        diskio = types.ModuleType("glances.plugins.diskio")
        diskio.DiskioPlugin = DiskioPlugin
        plugins.diskio = diskio
        glances.plugins = plugins

        modules = {
            "glances": glances,
            "glances.plugins": plugins,
            "glances.plugins.diskio": diskio,
        }
        stderr = io.StringIO()
        with patch.dict(sys.modules, modules), contextlib.redirect_stderr(stderr):
            self.assertTrue(rename_disks.patch())
            self.assertEqual(
                DiskioPlugin().get_raw(),
                [{"disk_name": "Seagate_4TB"}, {"disk_name": "nvme0n1"}],
            )

        self.assertIn("patch installed", stderr.getvalue())

    def test_patch_failure_is_visible(self):
        glances = types.ModuleType("glances")
        plugins = types.ModuleType("glances.plugins")
        diskio = types.ModuleType("glances.plugins.diskio")
        plugins.diskio = diskio
        glances.plugins = plugins
        modules = {
            "glances": glances,
            "glances.plugins": plugins,
            "glances.plugins.diskio": diskio,
        }
        stderr = io.StringIO()
        with patch.dict(sys.modules, modules), contextlib.redirect_stderr(stderr):
            self.assertFalse(rename_disks.patch())

        self.assertIn("patch failed", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
