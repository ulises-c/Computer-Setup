# Glances storage collection policy

`entrypoint.sh` installs the shared `telemetry.py` adapters **before any Glances
plugin is constructed**, including sensor initialization. The adapters target
the installed/pinned Glances **4.5.4** interfaces. Re-audit them before upgrading
the image; adapter failures stop the launcher rather than start unprotected.

## Defaults (backend, not just browser polling)

| Collection | Default / minimum interval | Allowed source |
|---|---:|---|
| HDD SMART and temperature | **disabled**, no routine schedule | none |
| SATA/USB SSD SMART; unknown devices | **disabled** | none |
| NVMe SSD SMART | 600 seconds | only explicit `/dev/nvmeN`, `interface=nvme`, sysfs controller discovery |
| NVMe temperature | same cached SMART sample | no independent hwmon or SMART query |
| Filesystem used/free | 300 seconds | statvfs only after sysfs proves **all** backing devices nonrotational; local ext4/xfs only |
| HDD filesystem used/free | **disabled** in tracked main Compose | experimental opt-in uses historical I/O counters, not proof of current power state (below) |
| Unknown/network filesystem used/free | **disabled** | no statvfs, pathname walk or tree scan |
| Disk I/O rates | 60 seconds | psutil's Linux `/proc/diskstats` counters, not drive queries |
| Hardware storage inventory | 3600 seconds | sysfs names, rotational flag, transport path and block capacity only |
| CPU/board temperature | existing live sensor cadence | explicit non-storage hwmon chip allowlist, filtered before reading inputs |

These intervals are also set on Glances' plugins. Monotonic, lock-protected
FS/SMART caches independently enforce their deadlines across direct requests,
`/all`, views/history/top endpoints and backend updates. Empty results and errors
cannot trigger rapid retries. A failed filesystem refresh retains the previous
real sample and timestamp with `collection_status=error`; it never fabricates
zero usage or healthy disks. Restarting Glances resets its in-memory caches.

Both the Glances SMART binding and `pySMART.DeviceList` are replaced: there is no
broad smartctl/ATA/SAT discovery. Glances' SMART `show` filter is **not** safe:
upstream constructs/queries DeviceList *before* filtering. The HDDtemp grabber is
also blocked, and the broad psutil temperature read is bypassed, including during
sensor construction. NVMe hwmon inputs are not read at all. Unknown temperature
chips are omitted; CPU/board/fan readings do not rely on a drive-health scan.

### Spinning disks: experimental activity gate disabled

Tracked main-server Compose explicitly sets `GLANCES_HDD_ACTIVITY_STATS=false`.
The optional sampler remains available for controlled experiments, not as a
no-wake guarantee. When enabled, its thread reads registered HDDs' completed
read/write counters from sysfs (`/sys/dev/block/.../stat`: kernel memory) on a
nominal 10-second poll (`GLANCES_HDD_ACTIVITY_POLL`, floor 10). Changed counters
prove only historical activity. Scheduling delays, suspension and activity on
only one RAID member can leave a backing drive asleep when `statvfs` runs.
There is no enforced maximum active-use window or non-probing power-state proof.
The previous claim that these reads cannot spin a drive up is withdrawn.

- At most one read attempt per mount per `GLANCES_HDD_INTERVAL` (default and floor 300 s),
  however busy the drive is and whether or not the read succeeds. A damaged or
  hand-edited cache file loses its invalid samples on load (non-finite, negative,
  future-dated, percent over 100). The first reading after startup only sets the baseline.
  Live registration changes to mount ID, root, device number, filesystem type,
  source or backing sysfs paths invalidate usage, throttle state and I/O baseline.
  Persisted numeric figures are **not reused after restart**: their filesystem
  identity cannot be proved from a saved mount path without touching storage.
  The optional cache file is not a durable freshness or identity guarantee.
- Rows appear in `/api/4/fs` only after a first sample (`storage_class=hdd`,
  `collection_source=activity_gated_statvfs`, `collection_age_seconds` counted from
  `collected_at` by the wall clock within the current process). Before that the mount is
  absent, never zero.
- Every disk behind a mapper/RAID node must be rotational and is watched; a mixed,
  unproven or non-ext4/xfs backing stays omitted.
- No SMART, power-state command, hdparm or smartctl is involved, and the USB
  bridges in front of the DAS disks are never asked anything.
- Physical verification remains outstanding: delayed ticks, suspension/resume,
  evicted pathname metadata and multi-disk backing must be assessed with a
  separately authorized, non-waking observation method. Synthetic tests prove
  code paths and cache invalidation, **not physical HDD no-wake behavior**.
  Keep usage disabled unless a non-probing active-use guarantee is established.

### Filesystem tradeoff

Without the switch above, the three sleeping DAS HDDs on the main server remain
inventory, not refreshed used/free gauges. Their raw **block capacity** is not filesystem capacity/free
space. It would be misleading to display an invented 0% usage or describe their
capacity as a fresh 5-second reading. Even occasional statvfs path resolution
can require disk I/O after cached inodes are evicted, so this policy does **not**
call it on HDDs. Device mapper/RAID backing is traversed through sysfs slaves;
unknown, cyclic, incomplete and mixed SSD/HDD backing fails closed. MicroSD is
nonrotational flash (Pi), not NVMe; its ext4 filesystem capacity is cached at the
same 300-second cadence. Btrfs and other unverified filesystem types are omitted.

No power-state checks, spin-up/down commands, self-tests, device scans, mounted
tree enumeration, package installs or new exporter/service are required. This
default policy excludes HDD SMART, temperature and statvfs paths; it does not claim a
physical sleep-state observation or control unrelated applications/daemons.
Intentional HDD diagnostics require separate authorization and a proven
standby-safe transport; unsupported bridges must stay unknown.

## Host settings

Set these non-secret values in the host's `glances/.env`, then recreate **only**
that project's Glances app from its existing Compose file:

```dotenv
GLANCES_FS_INTERVAL=300
GLANCES_NVME_HEALTH_INTERVAL=600
GLANCES_NVME_HEALTH_ENABLED=true
GLANCES_DISKIO_INTERVAL=60
# Experimental only; tracked main Compose explicitly keeps this false.
# GLANCES_HDD_ACTIVITY_STATS=false
# GLANCES_HDD_CACHE_FILE=/var/lib/glances-hdd/hdd-cache.json
# GLANCES_HDD_INTERVAL=300
# GLANCES_HDD_ACTIVITY_POLL=10
```

Intervals below their minimum are clamped; malformed intervals stop startup.
Only literal `true` enables NVMe health. Set it to `false` to collect no hardware
storage health/temperature at all. HDD health and temperature have deliberately **no opt-in switch**;
HDD filesystem usage has the experimental activity-gated switch above, disabled by default.
Preserve the host's existing environment, network mode and any Tailscale sidecar;
do not recreate a sidecar alone or restart unrelated projects.

## API contract / truthful cache age

`/api/4/fs` retains the standard FS row fields. Every returned row adds:

```json
{
  "collected_at": 1000,
  "collection_age_seconds": 299,
  "collection_interval_seconds": 300,
  "collection_status": "ok",
  "storage_class": "solid_state",
  "collection_source": "cached_statvfs"
}
```

`collected_at` is Unix epoch seconds (UTC, numeric); age uses monotonic elapsed
seconds, not HTTP response time. Frequent HTTP reads **do not imply freshness**.
The illustrated timestamps/values above and below are schema examples, not live
measurements. Null timestamps/ages mean not collected. Status is `never`, `ok`,
`empty` or `error`. `collection_count` counts collection attempts since startup.

With the HDD switch on, `/api/4/storagepolicy` also carries `filesystem_hdd_enabled: true`
and an `hdd` object (`scope`, `interval_seconds`, per-mount `collected_at` and
`collection_age_seconds`); inventory rows for those disks say
`filesystem_usage: "activity_gated"`.

`/api/4/storagepolicy` is a normal Glances plugin (also in `/api/4/all`), not a
new service. It reads only metadata and the slow sysfs inventory, and never
initiates FS or SMART collection:

```json
{
  "version": 1,
  "hdd_health_enabled": false,
  "non_nvme_health_enabled": false,
  "filesystem_hdd_enabled": false,
  "filesystem_unknown_enabled": false,
  "hdd_temperature_enabled": false,
  "nvme_temperature_source": "nvme_smart_cache",
  "diskio_source": "proc_diskstats",
  "diskio_interval_seconds": 60,
  "fs": {
    "scope": "proven_solid_state_ext4_xfs",
    "interval_seconds": 300,
    "collected_at": 1000,
    "collection_age_seconds": 299,
    "attempted_at": 1000,
    "status": "ok",
    "collection_count": 1
  },
  "smart": {
    "enabled": true,
    "scope": "nvme_only",
    "interval_seconds": 600,
    "collected_at": 1000,
    "collection_age_seconds": 299,
    "attempted_at": 1000,
    "status": "ok",
    "collection_count": 1,
    "devices": [{"DeviceName": "nvme0 example-model", "collected_at": 1000, "collection_age_seconds": 299}]
  },
  "inventory": {
    "source": "sysfs_only",
    "interval_seconds": 3600,
    "collected_at": 1000,
    "collection_age_seconds": 299,
    "attempted_at": 1000,
    "status": "ok",
    "collection_count": 1,
    "devices": [{"name": "sda", "rotational": true, "storage_class": "hdd", "transport": "usb", "capacity_bytes": 1024000, "health": "disabled", "filesystem_usage": "disabled"}]
  }
}
```

SMART rows keep their upstream `DeviceName` and numeric attribute keys unchanged;
use `storagepolicy.smart.devices` for age metadata, matching `DeviceName`. Do not
add arbitrary metadata keys to SMART rows: Glances interprets them as attributes.
NVMe sensor rows reuse the SMART timestamp/interval/age/status with
`collection_source=nvme_smart_cache`. Capability metadata never includes serials,
UUIDs, network addresses or credentials. Empty/failed health is unavailable, not
healthy. A browser may opt out of displaying/requesting health independently of
the backend NVMe policy; it should request FS no faster than its configured slow
cadence, honor the returned ages and keep HDD usage explicitly unavailable.
The grouped renderer validates consumed arrays/members before accepting a
sample, retains last-good values on malformed responses and recovers on a good
response. Health and wear require finite, nonnegative numeric attributes (zero
is valid); invalid values remain Unknown. Merged NVMe tiles retain separate
temperature and health ages/errors; newer SMART metadata cannot refresh an
older native temperature reading.

## Verified fleet rollout

This is the earlier rollout record, not a deployment of the changes above.
The tracked HDD-disable setting still requires a scoped Glances recreation on
the main host; this review fix performs no live deployment or physical probes.

The game, Pi and main hosts were audited and rolled out in that order without
installing packages or changing their private `.env` files, source branches,
Tailscale sidecars or unrelated containers. The Dragonwilds application kept
its invocation. Main has three USB DAS rotational disks (1 TB, 4 TB, 14 TB) plus
a 256 GB NVMe SSD; game has a 512 GB NVMe SSD; Pi has 64 GB microSD flash, not an
NVMe SSD. No SATA SSD was visible in this sysfs inventory. Main/Pi were on an
older checkout with broad upstream SMART discovery; only the explicit shared
Glances runtime files were replaced there, preserving their existing Homepage
working-tree edits. API readback showed FS=300s, NVMe health=600s, kernel disk
counters=60s and inventory=3600s on every host; repeated requests left collection
counts/timestamps unchanged while ages advanced. Physical drive sleep was not
queried or asserted. Periodic status/player-log oneshots may change invocation
normally and are not the game application's invocation.

## Validation

Run from this directory:

```sh
python3 -m unittest -v test_rename_disks.py test_telemetry.py test_storage.py test_hdd_activity.py
```

`test_installed_storage.py` and `test_installed_hdd.py` (each in its own process,
because `telemetry.install` is one-shot) also run **inside each installed Glances image**
with synthetic provider data: real plugin construction and REST handlers for
`/all`, `/smart`, `/fs`, `/storagepolicy`, top/views/limits/history, forced plugin
updates, forbidden broad SMART/hwmon/HDDtemp call traps, and cache age/counters.
It never runs live drive queries. Deployment is staged game → Pi → main, preserves
the old main/Pi branches and unrelated working-tree files, and verifies effective
mounts, safe API snapshots, age progression and unchanged unrelated containers.

GPU byte enrichment remains separately host-opted-in with
`GLANCES_GPU_MEMORY=true`; it uses existing NVML handles and preserves percent
fields. No nvidia-smi subprocess or new timer is added.
