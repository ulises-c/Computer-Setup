# Glances health policy

The shared entrypoint installs `telemetry.py` before Glances starts. It replaces
Glances 4.5.4's SMART `DeviceList()` binding with NVMe-controller-only discovery
from `/sys/class/nvme/nvme[0-9]*`. Only `/dev/nvmeN` is opened, explicitly with
interface `nvme`; results (including failed/empty attempts) are cached for
60 seconds. No broad smartctl scan, SATA/USB enumeration, HDD health read, or
self-test is scheduled. Filtering Glances SMART `show` is **not** a safety
mechanism: the upstream plugin first constructs pySMART `DeviceList`, which
scans and reads all discovered drives, and only then filters its output.

This policy applies when a host next deploys/recreates this shared Glances
configuration. This change is deployed on the **game host only**; main and Pi
have not been recreated or probed. It does not claim their existing collectors
are standby-safe. No fleet disk-health rollout is authorized here.

Intentional HDD checks are manual opt-in, never part of this default collector.
Use `smartctl -n standby,3,5 -d <known-type> -a <known-device>` only after
identifying the correct ATA/SAT transport from existing inventory, not by
scanning sleeping disks. For example `-d ata` for a known native ATA disk or
`-d sat` for a known compatible bridge. The standby check must precede SMART
reads; code 3 means skipped/asleep, code 5 means unsupported power-mode check,
not healthy. Never retry without `-n`, autodetect the transport, or enable a
self-test on a skipped disk. Unsupported bridges remain unknown. These commands
are policy examples, **not executed probes**.

GPU byte enrichment is separately host-opted-in with `GLANCES_GPU_MEMORY=true`.
It uses the existing NVIDIA adapter's initialized NVML device handles and adds
`memory_used` / `memory_total` (bytes) to `/api/4/gpu`, preserving existing fields.
No `nvidia-smi` subprocess, new exporter, or background timer is added. Missing
NVML memory readings remain unavailable; percent is never used to estimate bytes.
The shared module is pinned to the deployed Glances 4.5.4 adapter interface and
must be checked again before upgrading Glances.

Tests: `python3 -m unittest -v test_rename_disks.py test_telemetry.py` in this dir.
