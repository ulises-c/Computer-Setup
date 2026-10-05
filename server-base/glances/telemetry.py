"""Glances 4.5.4 adapters: cheap GPU bytes, NVMe-only cached SMART.

Never call pySMART DeviceList: it scans/queries every drive without a standby
check. Discover NVMe controllers through sysfs only; no SATA/USB health probes.
"""
import re
import time
from pathlib import Path
from types import SimpleNamespace


def nvme_provider(device, root=Path('/sys/class/nvme'), clock=time.monotonic):
    cached, deadline = [], None

    def get_devices():
        nonlocal cached, deadline
        now = clock()
        if deadline is None or now >= deadline:
            cached = []
            deadline = now + 60
            for entry in sorted(root.glob('nvme*')):
                if not re.fullmatch(r'nvme\d+', entry.name):
                    continue
                try:
                    cached.append(device('/dev/' + entry.name, interface='nvme'))
                except Exception:
                    # No fabricated healthy sample on permission/driver errors.
                    continue
        return SimpleNamespace(devices=cached)

    return get_devices


def gpu_memory(stats, handles, get_memory):
    for stat, handle in zip(stats, handles):
        try:
            memory = get_memory(handle)
            if memory.total > 0 and 0 <= memory.used <= memory.total:
                stat.update(memory_used=memory.used, memory_total=memory.total)
        except Exception:
            pass
    return stats


def install(gpu=False):
    import glances.plugins.smart as smart
    try:
        from pySMART import Device
    except ImportError:
        # Missing dependency already disables the upstream plugin. Still replace
        # its broad discovery binding, so it cannot become a scan accidentally.
        smart.DeviceList = lambda: SimpleNamespace(devices=[])
    else:
        if not getattr(smart, '_nvme_only', False):
            smart.DeviceList = nvme_provider(Device)
            smart._nvme_only = True
    if gpu:
        import glances.plugins.gpu.cards.nvidia as nvidia
        if not getattr(nvidia, '_memory_bytes', False) and hasattr(nvidia, 'pynvml'):
            original = nvidia.NvidiaGPU.get_device_stats

            def get_device_stats(self):
                return gpu_memory(original(self), self.device_handles, nvidia.pynvml.nvmlDeviceGetMemoryInfo)

            nvidia.NvidiaGPU.get_device_stats = get_device_stats
            nvidia._memory_bytes = True
