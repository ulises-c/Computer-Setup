import os, re

mapping_str = os.environ.get("GLANCES_DISK_MAPPING", "")
disk_aliases = {}
if mapping_str:
    for pair in mapping_str.split(","):
        if ":" in pair:
            kernel, label = pair.split(":", 1)
            disk_aliases[kernel.strip()] = label.strip()


def patch():
    try:
        import glances.plugins.diskio
        orig = glances.plugins.diskio.DiskioPlugin.get_raw

        def patched(self):
            stats = orig(self)
            for stat in stats:
                dn = stat.get("disk_name", "")
                if re.match(r"^[a-z]+$", dn) and dn in disk_aliases:
                    stat["disk_name"] = disk_aliases[dn]
            return stats

        glances.plugins.diskio.DiskioPlugin.get_raw = patched
    except Exception:
        pass


patch()
