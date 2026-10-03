import os
import sys
from pathlib import Path

DEFAULT_LABELS = ("Seagate_4TB", "WD_1TB", "WD14TB")


def resolve_aliases():
    label_dir = Path(os.environ.get("GLANCES_DISK_LABEL_DIR", "/dev/disk/by-label"))
    sys_block_dir = Path(os.environ.get("GLANCES_SYS_BLOCK_DIR", "/sys/class/block"))
    labels = os.environ.get("GLANCES_DISK_LABELS", ",".join(DEFAULT_LABELS)).split(",")
    aliases = {}

    for label in labels:
        label = label.strip()
        if not label or Path(label).name != label:
            continue
        try:
            device_name = (label_dir / label).resolve(strict=True).name
            sys_device = sys_block_dir / device_name
            if (sys_device / "partition").exists():
                device_name = sys_device.resolve(strict=True).parent.name
            aliases[device_name] = label
        except OSError:
            continue

    return aliases


def patch():
    try:
        import glances.plugins.diskio

        plugin = glances.plugins.diskio.DiskioPlugin
        original = plugin.get_raw

        def patched(self):
            stats = original(self)
            aliases = resolve_aliases()
            for stat in stats:
                disk_name = stat.get("disk_name", "")
                if disk_name in aliases:
                    stat["disk_name"] = aliases[disk_name]
            return stats

        plugin.get_raw = patched
    except Exception as exc:
        print(f"glances disk alias patch failed: {exc}", file=sys.stderr)
        return False

    print("glances disk alias patch installed", file=sys.stderr)
    return True
