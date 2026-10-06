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
| HDD filesystem used/free | **disabled** unless `GLANCES_HDD_ACTIVITY_STATS=true` | only while the kernel's I/O counters show the drive in use (below) |
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

### Spinning disks: read only while they are in use

With `GLANCES_HDD_ACTIVITY_STATS=true` (main server only) a sampler thread reads
each registered HDD mount's backing disks' completed read/write counters from
sysfs (`/sys/dev/block/.../stat`: kernel memory, no drive query) every 10 seconds
(`GLANCES_HDD_ACTIVITY_POLL`, floor 10). Counters that moved since the previous
reading mean something else is already using the drive, so one `statvfs` then
cannot spin it up. Idle drives are never touched: their last sample is reported
as is, with the epoch time it was taken (`collected_at`), and it is persisted to
`GLANCES_HDD_CACHE_FILE` so it survives restarts.

- At most one read per mount per `GLANCES_HDD_INTERVAL` (default and floor 300 s),
  however busy the drive is. The first reading after startup only sets the baseline.
- Rows appear in `/api/4/fs` only after a first sample (`storage_class=hdd`,
  `collection_source=activity_gated_statvfs`, `collection_age_seconds` counted from
  `collected_at` by the wall clock, so it spans restarts). Before that the mount is
  absent, never zero.
- Every disk behind a mapper/RAID node must be rotational and is watched; a mixed,
  unproven or non-ext4/xfs backing stays omitted.
- No SMART, power-state command, hdparm or smartctl is involved, and the USB
  bridges in front of the DAS disks are never asked anything.
- Residual risk: the read happens up to one poll (10 s) after the I/O it piggybacks
  on, which sits far inside any drive's idle spindown timer, and `statvfs` on a
  mounted ext4 normally reads in-memory superblock counters anyway.

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
policy proves the Glances collector has no HDD probe path; it does not claim a
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
# Main server only (set in its compose file): HDD used/free while in use.
# GLANCES_HDD_ACTIVITY_STATS=true
# GLANCES_HDD_CACHE_FILE=/var/lib/glances-hdd/hdd-cache.json
# GLANCES_HDD_INTERVAL=300
# GLANCES_HDD_ACTIVITY_POLL=10
```

Intervals below their minimum are clamped; malformed intervals stop startup.
Only literal `true` enables NVMe health. Set it to `false` to collect no hardware
storage health/temperature at all. HDD health and temperature have deliberately **no opt-in switch**;
HDD *capacity* has the activity-gated one above.
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
NVMe sensor rows reuse the SMART timestamp/interval/age with
`collection_source=nvme_smart_cache`. Capability metadata never includes serials,
UUIDs, network addresses or credentials. Empty/failed health is unavailable, not
healthy. A browser may opt out of displaying/requesting health independently of
the backend NVMe policy; it should request FS no faster than its configured slow
cadence, honor the returned ages and keep HDD usage explicitly unavailable.

## Verified fleet rollout

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
