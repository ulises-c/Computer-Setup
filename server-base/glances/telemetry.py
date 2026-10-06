"""Glances 4.5.4 adapters: cheap GPU bytes, NVMe-only cached SMART.

Never call pySMART DeviceList: it scans/queries every drive without a standby
check. Discover NVMe controllers through sysfs only; no SATA/USB health probes.
"""
import json
import os
import re
import time
from pathlib import Path
from types import SimpleNamespace
from copy import deepcopy
from threading import Event, RLock, Thread


class SampleCache:
    """Cache successes, empty results and errors; requests cannot bypass the TTL."""
    def __init__(self, interval, clock=time.monotonic, wall=time.time, copy_data=deepcopy):
        self.interval, self.clock, self.wall = interval, clock, wall
        self.copy_data = copy_data
        self.data, self.deadline = [], None
        self.collected_at = self.collected_mono = self.attempted_at = None
        self.status, self.collection_count = 'never', 0
        self.lock = RLock()

    def get(self, collect):
        with self.lock:
            now = self.clock()
            if self.deadline is None or now >= self.deadline:
                self.deadline = now + self.interval
                self.attempted_at = self.wall()
                self.collection_count += 1
                try:
                    self.data = collect()
                except Exception:
                    # Keep the last real sample and its timestamp, never a fake zero.
                    self.status = 'error'
                else:
                    self.collected_at, self.collected_mono = self.wall(), self.clock()
                    self.status = 'ok' if self.data else 'empty'
                self.deadline = self.clock() + self.interval
            return self.copy_data(self.data)

    def metadata(self):
        with self.lock:
            age = None if self.collected_mono is None else max(0, self.clock() - self.collected_mono)
            return dict(interval_seconds=self.interval, collected_at=self.collected_at,
                        collection_age_seconds=age, attempted_at=self.attempted_at,
                        status=self.status, collection_count=self.collection_count)


def nvme_provider(device, root=Path('/sys/class/nvme'), clock=time.monotonic,
                  interval=600, wall=time.time, enabled=True):
    # pySMART's deepcopy/pickle hooks convert typed NVMe attributes to dicts.
    cache = SampleCache(max(600, interval), clock, wall, copy_data=list)

    def collect():
        devices = []
        if not enabled:
            return devices
        for entry in sorted(root.glob('nvme*')):
            if not re.fullmatch(r'nvme\d+', entry.name):
                continue
            try:
                devices.append(device('/dev/' + entry.name, interface='nvme'))
            except Exception:
                # Never retry through ATA/SAT, nor manufacture a healthy sample.
                continue
        return devices

    def get_devices():
        return SimpleNamespace(devices=cache.get(collect))

    get_devices.cache = cache
    return get_devices


def solid_state_backing(node, seen=None):
    """Fail closed using sysfs only, including every mapper/RAID slave."""
    seen = set() if seen is None else set(seen)
    try:
        node = node.resolve(strict=True)
        if node in seen:
            return False
        seen.add(node)
        if (node / 'partition').exists():
            return solid_state_backing(node.parent, seen)
        slaves = list((node / 'slaves').iterdir()) if (node / 'slaves').is_dir() else []
        if slaves:
            return all(solid_state_backing(slave, seen) for slave in slaves)
        if node.name.startswith(('dm-', 'md', 'loop', 'ram', 'zram')):
            return False
        return (node / 'device').exists() and (node / 'queue/rotational').read_text().strip() == '0'
    except OSError:
        return False


def backing_disks(node, seen=None):
    """Whole-disk sysfs nodes behind a block node, or None when any link is unproven."""
    seen = set() if seen is None else set(seen)
    try:
        node = node.resolve(strict=True)
        if node in seen:
            return None
        seen.add(node)
        if (node / 'partition').exists():
            return backing_disks(node.parent, seen)
        if (node / 'slaves').is_dir():
            slaves = list((node / 'slaves').iterdir())
            if slaves:
                disks = []
                for slave in slaves:
                    found = backing_disks(slave, seen)
                    if found is None:
                        return None
                    disks += found
                return disks
        if node.name.startswith(('dm-', 'md', 'loop', 'ram', 'zram')):
            return None
        return [node] if (node / 'device').exists() else None
    except OSError:
        return None


def hdd_backing(node):
    """The disks behind a mount only when every one of them is rotational."""
    disks = backing_disks(node)
    try:
        if disks and all((disk / 'queue/rotational').read_text().strip() == '1' for disk in disks):
            return disks
    except OSError:
        pass
    return None


def io_counters(disks):
    """Completed reads and writes from sysfs: kernel memory, never a drive query."""
    try:
        counters = []
        for disk in disks:
            fields = (disk / 'stat').read_text().split()
            counters.append((int(fields[0]), int(fields[4])))
        return tuple(counters)
    except (OSError, ValueError, IndexError):
        return None


class HddActivityStats:
    """Filesystem usage of spinning disks, read only while something else uses them.

    A drive whose completed-I/O counters moved since the last tick is awake, so
    a read then cannot spin it up. Idle drives are never touched; their last
    sample keeps the date it was taken and survives restarts.
    """
    def __init__(self, usage, cache_file=None, interval=300, wall=time.time):
        self.usage, self.wall = usage, wall
        self.interval = max(300, interval)
        self.cache_file = None if cache_file is None else Path(cache_file)
        self.mounts, self.baselines = {}, {}
        self.lock = RLock()
        self.samples = self._load()

    def _load(self):
        try:
            mounts = json.loads(self.cache_file.read_text())['mounts']
            return {mnt: {key: float(sample[key]) for key in ('collected_at', 'size', 'used', 'free', 'percent')}
                    for mnt, sample in mounts.items()}
        except (AttributeError, OSError, ValueError, KeyError, TypeError):
            return {}

    def _save(self):
        if self.cache_file is None:
            return
        # Best effort: a read-only or missing state directory only loses restarts.
        try:
            temporary = self.cache_file.with_name(self.cache_file.name + '.tmp')
            temporary.write_text(json.dumps(dict(version=1, mounts=self.samples)))
            os.replace(temporary, self.cache_file)
        except OSError:
            pass

    def register(self, mounts):
        with self.lock:
            self.mounts = {mount['row']['mnt_point']: mount for mount in mounts}
            self.baselines = {mnt: value for mnt, value in self.baselines.items() if mnt in self.mounts}

    def tick(self):
        with self.lock:
            mounts = list(self.mounts.values())
        for mount in mounts:
            mnt, disks = mount['row']['mnt_point'], mount['disks']
            current, previous = io_counters(disks), self.baselines.get(mnt)
            self.baselines[mnt] = current
            if current is None or previous is None or current == previous:
                continue
            now = self.wall()
            sample = self.samples.get(mnt)
            if sample and 0 <= now - sample['collected_at'] < self.interval:
                continue
            try:
                usage = self.usage(mnt)
            except OSError:
                continue
            with self.lock:
                self.samples[mnt] = dict(collected_at=now, size=usage.total, used=usage.used,
                                         free=usage.free, percent=usage.percent)
                self._save()

    def rows(self):
        with self.lock:
            now = self.wall()
            return [dict(mount['row'], size=sample['size'], used=sample['used'], free=sample['free'],
                         percent=sample['percent'], storage_class='hdd',
                         collection_source='activity_gated_statvfs',
                         collected_at=sample['collected_at'],
                         collection_age_seconds=max(0, now - sample['collected_at']),
                         collection_interval_seconds=self.interval, collection_status='ok')
                    for mnt, mount in self.mounts.items() if (sample := self.samples.get(mnt))]

    def start(self, period=30):
        stop = Event()

        def run():
            while not stop.wait(period):
                try:
                    self.tick()
                except Exception:
                    # The sampler must outlive any single bad reading.
                    continue

        Thread(target=run, name='hdd-activity', daemon=True).start()
        return stop.set


def mount_records(path):
    """Decode proc mountinfo, never walk or stat mounted trees."""
    def unescape(value):
        return re.sub(r'\\([0-7]{3})', lambda match: chr(int(match[1], 8)), value)
    for line in path.read_text().splitlines():
        parts = line.split()
        try:
            separator = parts.index('-')
            yield dict(devno=parts[2], mnt_point=unescape(parts[4]), options=parts[5],
                       fs_type=parts[separator + 1], device_name=unescape(parts[separator + 2]))
        except (ValueError, IndexError):
            continue


def filesystem_rows(cache):
    with cache.lock:
        metadata = cache.metadata()
        return [dict(row, collected_at=metadata['collected_at'],
                     collection_age_seconds=metadata['collection_age_seconds'],
                     collection_interval_seconds=cache.interval,
                     collection_status=metadata['status']) for row in deepcopy(cache.data)]


def filesystem_provider(usage, block_root=Path('/sys/dev/block'),
                        mountinfo=Path('/proc/self/mountinfo'), clock=time.monotonic,
                        interval=300, wall=time.time, hdd=None):
    cache = SampleCache(max(300, interval), clock, wall)

    def get_filesystems(plugin):
        def collect():
            rows, spinning = [], []
            for record in mount_records(mountinfo):
                # Solid-state mounts are read here on a slow timer. Spinning disks
                # are only registered: `hdd` reads them while they are in use.
                # Unknown, mixed and network backing is omitted.
                if record['fs_type'] not in ('ext4', 'xfs'):
                    continue
                backing = block_root / record['devno']
                solid = solid_state_backing(backing)
                disks = None if solid or hdd is None else hdd_backing(backing)
                if not solid and not disks:
                    continue
                if not plugin.is_display_any(record['mnt_point'], record['device_name']):
                    continue
                row = {key: value for key, value in record.items() if key != 'devno'}
                row.update(key=plugin.get_key())
                alias = plugin.has_alias(record['mnt_point'])
                if alias is not None:
                    row['alias'] = alias
                if disks:
                    spinning.append(dict(row=row, disks=disks))
                    continue
                current = usage(record['mnt_point'])
                row.update(size=current.total, used=current.used, free=current.free,
                           percent=current.percent, storage_class='solid_state',
                           collection_source='cached_statvfs')
                rows.append(row)
            if hdd is not None:
                hdd.register(spinning)
            return rows
        cache.get(collect)
        return get_filesystems.rows()

    get_filesystems.rows = lambda: filesystem_rows(cache) + ([] if hdd is None else hdd.rows())
    get_filesystems.cache = cache
    get_filesystems.hdd = hdd
    return get_filesystems


def temperature_provider(health, hwmon=Path('/sys/class/hwmon')):
    """Known CPU/board chips only; NVMe temperature uses an existing SMART sample."""
    def get_temperatures():
        result = {}
        for node in sorted(hwmon.glob('hwmon*')):
            try:
                chip = (node / 'name').read_text().strip()
                # Filter BEFORE opening temp*_input. Unknown chips are omitted.
                if not re.fullmatch(r'coretemp|k[0-9]+temp|cpu_thermal|soc_thermal|acpitz|pch_[a-z0-9_]+|nct[0-9]+|it[0-9]+', chip):
                    continue
                if '/nvme/' in str(node.resolve()) or '/block/' in str(node.resolve()):
                    continue
            except OSError:
                continue
            temperatures = []
            for input_path in sorted(node.glob('temp[0-9]*_input')):
                base = input_path.name.removesuffix('_input')
                def value(suffix):
                    try:
                        return float((node / (base + suffix)).read_text().strip()) / 1000
                    except (OSError, ValueError):
                        return None
                current = value('_input')
                if current is None:
                    continue
                try:
                    label = (node / (base + '_label')).read_text().strip()
                except OSError:
                    label = ''
                temperatures.append(SimpleNamespace(label=label, current=current,
                                                    high=value('_max'), critical=value('_crit')))
            if temperatures:
                result[chip] = temperatures
        with health.cache.lock:
            nvme = []
            for index, device in enumerate(health.cache.data):
                temperature = getattr(device, 'temperature', None)
                if isinstance(temperature, (int, float)):
                    nvme.append(SimpleNamespace(label='Composite' if index == 0 else 'NVMe ' + device.name,
                                                current=temperature, high=None, critical=None))
            if nvme:
                result['nvme'] = nvme
        return result
    return get_temperatures


class StoragePolicy:
    """Read-only collection metadata; snapshot never collects FS or SMART."""
    def __init__(self, filesystems, health, blocks=Path('/sys/class/block'),
                 clock=time.monotonic, wall=time.time, health_enabled=True):
        self.filesystems, self.health, self.blocks = filesystems, health, blocks
        self.hdd = getattr(filesystems, 'hdd', None)
        self.health_enabled = health_enabled
        self.diskio_interval = 60
        self.temperatures = temperature_provider(health)
        self.inventory = SampleCache(3600, clock, wall)

    def _inventory(self):
        rows = []
        for entry in sorted(self.blocks.iterdir()):
            try:
                if (entry / 'partition').exists() or not (entry / 'device').exists():
                    continue
                rotational = (entry / 'queue/rotational').read_text().strip()
                path = str(entry.resolve())
                transport = ('usb' if '/usb' in path else 'nvme' if entry.name.startswith('nvme')
                             else 'mmc' if entry.name.startswith('mmcblk') else 'ata' if '/ata' in path else 'unknown')
                storage_class = ('hdd' if rotational == '1' else 'nvme_ssd' if rotational == '0' and transport == 'nvme'
                                 else 'flash' if rotational == '0' and transport == 'mmc' else 'ssd' if rotational == '0' else 'unknown')
                rows.append(dict(name=entry.name, rotational=rotational == '1' if rotational in ('0', '1') else None,
                                 storage_class=storage_class, transport=transport,
                                 capacity_bytes=int((entry / 'size').read_text().strip()) * 512,
                                 health='nvme_only' if storage_class == 'nvme_ssd' and self.health_enabled else 'disabled',
                                 filesystem_usage='cached' if solid_state_backing(entry)
                                 else 'activity_gated' if self.hdd is not None and hdd_backing(entry) else 'disabled'))
            except (OSError, ValueError):
                continue
        return rows

    def snapshot(self):
        inventory = self.inventory.get(self._inventory)
        health_meta = self.health.cache.metadata()
        # Do not add nonnumeric metadata to SMART rows: Glances' SMART renderer
        # interprets every key other than DeviceName as an attribute number.
        with self.health.cache.lock:
            devices = [dict(DeviceName=f'{dev.name} {dev.model}',
                            collected_at=health_meta['collected_at'],
                            collection_age_seconds=health_meta['collection_age_seconds'])
                       for dev in self.health.cache.data]
        snapshot = dict(version=1, hdd_health_enabled=False, non_nvme_health_enabled=False,
                        filesystem_hdd_enabled=self.hdd is not None, filesystem_unknown_enabled=False,
                        diskio_source='proc_diskstats', diskio_interval_seconds=self.diskio_interval,
                        hdd_temperature_enabled=False, nvme_temperature_source='nvme_smart_cache',
                        fs=dict(self.filesystems.cache.metadata(), scope='proven_solid_state_ext4_xfs'),
                        smart=dict(health_meta, enabled=self.health_enabled, scope='nvme_only', devices=devices),
                        inventory=dict(self.inventory.metadata(), source='sysfs_only', devices=inventory))
        if self.hdd is not None:
            snapshot['hdd'] = dict(enabled=True, scope='activity_gated_statvfs',
                                   interval_seconds=self.hdd.interval,
                                   mounts=[dict(mnt_point=row['mnt_point'], collected_at=row['collected_at'],
                                                collection_age_seconds=row['collection_age_seconds'])
                                           for row in self.hdd.rows()])
        return snapshot


def gpu_memory(stats, handles, get_memory):
    for stat, handle in zip(stats, handles):
        try:
            memory = get_memory(handle)
            if memory.total > 0 and 0 <= memory.used <= memory.total:
                stat.update(memory_used=memory.used, memory_total=memory.total)
        except Exception:
            pass
    return stats


def install(gpu=False, policy=None):
    """Install before Glances creates ANY plugin, not just before API requests."""
    import os
    import glances.plugins.smart as smart
    if not getattr(smart, '_storage_policy', None):
        # Replace broad discovery immediately, even if a later interface check
        # fails (the launcher aborts rather than starting an unsafe collector).
        smart.DeviceList = lambda: SimpleNamespace(devices=[])
        import glances.plugins.fs as fs
        from glances.stats import GlancesStats
        from glances.plugins.plugin.model import GlancesPluginModel
        try:
            import pySMART
            device = pySMART.Device
        except ImportError:
            device = None
        if policy is None:
            def interval(name, minimum):
                value = int(os.environ.get(name, str(minimum)))
                return max(minimum, value)
            enabled = os.environ.get('GLANCES_NVME_HEALTH_ENABLED', 'true') == 'true' and device is not None
            health = nvme_provider(device, interval=interval('GLANCES_NVME_HEALTH_INTERVAL', 600), enabled=enabled)
            hdd = None
            if os.environ.get('GLANCES_HDD_ACTIVITY_STATS', 'false') == 'true':
                hdd = HddActivityStats(fs.psutil.disk_usage, os.environ.get('GLANCES_HDD_CACHE_FILE') or None,
                                       interval('GLANCES_HDD_INTERVAL', 300))
                hdd.start(interval('GLANCES_HDD_ACTIVITY_POLL', 10))
            filesystems = filesystem_provider(fs.psutil.disk_usage,
                                              interval=interval('GLANCES_FS_INTERVAL', 300), hdd=hdd)
            policy = StoragePolicy(filesystems, health, health_enabled=enabled)
            policy.diskio_interval = interval('GLANCES_DISKIO_INTERVAL', 60)
        smart.DeviceList = policy.health
        if device is not None:
            # Future imports from pySMART cannot restore broad discovery either.
            pySMART.DeviceList = policy.health
        # Bypass the unsafe upstream enumerator/statvfs path entirely. The cache
        # protects direct updates, /all, /fs and repeated updates independently
        # of both Glances' timers and the browser's HTTP cadence.
        fs.FsPlugin.update_local = lambda plugin: policy.filesystems(plugin)
        fs.FsPlugin.get_raw = lambda plugin: policy.filesystems.rows()
        import glances.plugins.sensors as sensors
        from glances.plugins.sensors.sensor.glances_hddtemp import GlancesGrabHDDTemp
        # HDDtemp does not honor --disable-hddtemp in every internal path.
        GlancesGrabHDDTemp.get = lambda grabber: []
        GlancesGrabHDDTemp.fetch = lambda grabber: ''
        grabber = sensors.GlancesGrabSensors
        original_fetch = grabber._GlancesGrabSensors__fetch_data
        original_update = grabber.update

        def fetch_sensor_data(sensor):
            if sensor.sensor_type == 'temperature_core':
                return policy.temperatures()
            return original_fetch(sensor)

        def update_sensor(sensor):
            rows = original_update(sensor)
            metadata = policy.health.cache.metadata()
            for row in rows:
                if row['label'] == 'Composite' or row['label'].startswith('NVMe '):
                    row.update(collected_at=metadata['collected_at'],
                               collection_age_seconds=metadata['collection_age_seconds'],
                               collection_interval_seconds=metadata['interval_seconds'],
                               collection_source='nvme_smart_cache')
            return rows

        grabber._GlancesGrabSensors__fetch_data = fetch_sensor_data
        grabber.update = update_sensor

        class StoragepolicyPlugin(GlancesPluginModel):
            def __init__(self, args=None, config=None):
                super().__init__(args=args, config=config, stats_init_value={}, fields_description={})
                self.display_curse = False

            def update(self):
                self.stats = policy.snapshot()
                return self.stats

            def get_raw(self):
                return policy.snapshot()

        StoragepolicyPlugin.__module__ = 'glances.plugins.storagepolicy'
        original_load = GlancesStats.load_plugins

        def load_plugins(stats, args=None):
            original_load(stats, args=args)
            stats._plugins['storagepolicy'] = StoragepolicyPlugin(args=args, config=stats.config)
            if args is not None:
                args.disable_storagepolicy = False
            # Per-plugin cadence too; HTTP API requests remain cheap cache reads.
            stats._plugins['fs'].set_refresh(policy.filesystems.cache.interval)
            stats._plugins['smart'].set_refresh(policy.health.cache.interval)
            if 'diskio' in stats._plugins:
                stats._plugins['diskio'].set_refresh(max(60, policy.diskio_interval))
            if args is not None:
                args.disable_hddtemp = True

        GlancesStats.load_plugins = load_plugins
        smart._storage_policy = policy
    if gpu:
        import glances.plugins.gpu.cards.nvidia as nvidia
        if not getattr(nvidia, '_memory_bytes', False) and hasattr(nvidia, 'pynvml'):
            original = nvidia.NvidiaGPU.get_device_stats

            def get_device_stats(self):
                return gpu_memory(original(self), self.device_handles, nvidia.pynvml.nvmlDeviceGetMemoryInfo)

            nvidia.NvidiaGPU.get_device_stats = get_device_stats
            nvidia._memory_bytes = True
