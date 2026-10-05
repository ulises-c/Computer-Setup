# Game-host grouped metrics

`server-base/fleet.json` enables `topbar.grouped` **only** for this host.
The generator appends `server-base/homepage/grouped-topbar.css` and replaces
its legacy extras poller with `grouped-topbar.js`. Other hosts' generated
settings, CSS and JS are unchanged. Edit sources, never the generated copies:

```sh
python3 server-base/homepage/generate.py
python3 server-base/homepage/generate.py --check
python3 -m unittest server-base/tests/test_generate.py
# Use the already-installed Homepage image for its Node runtime:
docker run --rm --network none --entrypoint node -v "$PWD:/repo:ro" \
  ghcr.io/gethomepage/homepage:v2.4.0 \
  --test /repo/linux-game-server/tests/test_grouped_topbar.cjs
```

## Data and refresh contract

- **Compute:** CPU usage, actual 15-minute load (not a percentage), CPU
  temperature/warning, RAM used percentage/free/total; available GPU usage,
  temperature, VRAM and GPU fan percentage. Positive real host fan readings
  appear if exposed; no unsupported zero-RPM chassis fan is invented.
- **Storage:** labeled filesystem used percentage/free/total, available NVMe
  temperature/warning and SMART health/wear. Single-drive thermal and health
  rows share a tile; multiple devices are not silently associated.
- **Connectivity:** configured host NIC upload/download and available Wi-Fi.
- **System:** full native uptime, Homepage's browser-local date/clock, RGB
  last-set mode/name. RGB is not claimed to be hardware color readback.

The native Glances and datetime React widgets stay mounted. A narrowly scoped
passive `fetch` wrapper clones only the same-origin, index-0
`/api/widgets/glances` response; it returns the original Response to SWR.
It creates **no native polling** and reuses native sensors instead of making
another `/sensors` request. Homepage v2.4.0 owns its 1500ms refresh and error
retry behavior. The grouped view renders only after a compatible payload;
without JS, CSS or that payload the native view remains available.

One non-overlapping 5000ms extras timer reads the public host Glances
`/glances/api/4/{gpu,network,wifi}` paths and configured RGB URL, with a 4s
request timeout. SMART is fetched every 60s. Extras pause in hidden tabs and
refresh on return. URLs reject userinfo/unsafe protocols, requests omit
credentials, and API text is HTML-escaped. No new service or upstream fork.

Failed reads preserve the last value with **Unavailable · last value** text;
missing numeric fields use an em dash, not zero. Native/extras older than
15s and SMART older than 130s are **Stale · last value**. RGB also checks its
exporter's timestamp (30-minute cutoff; future-clock skew is labeled).
Optional empty GPU/Wi-Fi/sensor arrays mean unavailable hardware, not zero
utilization. Failed optional endpoints are identified in a visible notice.

The Glances link survives DOM updates so keyboard focus is not lost. Group
headings, definition lists and numeric usage text carry meaning without
color; meter bars are decorative. Only native Glances index 0 and datetime
are visually replaced. The CSS uses the generated widget ordering to cover
native errors too. Re-check this small adapter when changing Homepage's
version, fetcher, response shape or widget order.

## Deploy and rollback

After generating, revalidate the local Homepage and reload the browser:

```sh
docker exec homepage wget -qO- http://127.0.0.1:3000/api/revalidate
```

No container or game restart is needed. Disabling this host's `grouped` flag
and regenerating restores its legacy native/extras appearance. Never enable
other hosts or edit `linux-server/` as part of a game-host-only rollout.


## GPU bytes, lighting zones and spindle-safe health

The game host explicitly inventories `nvidia0` as a **dGPU**. Live PCI and
Glances discovery expose one NVIDIA GeForce GTX 1070 and no active iGPU adapter;
do not invent an iGPU tile. The GPU model stays visible in its tile. With this
host's `GLANCES_GPU_MEMORY=true`, the shared NVML adapter adds byte-valued
`memory_used` and `memory_total` to Glances `/api/4/gpu`. The tile shows used /
total binary units alongside the original percentage. Missing byte readings
are `— / —`, never estimated from percent. Future hosts set `topbar.gpuTypes`
by actual `gpu_id` inventory; unspecified types remain explicitly unknown.

The existing root-owned OpenRGB exporter/timer is still a read-only
`openrgb --noautoconnect --list-devices` collector every ten minutes. There is
no SDK listener on this host. The CLI can expose detected device/type, available
modes, last-set **device-wide** mode, quoted zone names and LED names; it cannot
report real zone colors, independent zone modes, LED count/type/capability
flags, on/off state or hardware readback. The new producer preserves numeric
`zones` and adds `zone_details` with name, `status: detected`, `color: null`,
`readback: false`, plus `available_modes`, `mode_source`, and `led_names`.
The renderer lists every reported zone as **Detected · color unknown**.
It neither uses a mode as evidence of illumination nor fabricates colors.
Exporter errors over HTTP 200 are unavailable, not healthy fresh samples.

The currently installed exporter publishes HP Omen 30L / Motherboard /
Direct / 7 zones, but discards zone names and supported modes. Unprivileged
OpenRGB cannot open the controller. Root authentication is required to replace
the installed copy; until that step the dashboard explicitly says **7 · names
need exporter update**. Real current zone names/capabilities cannot be verified
from the old JSON. Install only the producer (the timer/unit need no changes):

```sh
cd ~/github/Computer-Setup
sudo install -o root -g root -m 755 linux-game-server/rgb/rgb-status.py /usr/local/libexec/rgb-status
sudo systemctl start rgb-status.service
cat /var/lib/host-status/rgb.json
systemctl show rgb-status.service -p ExecStart -p Result
```

Read back the new JSON and dashboard after installation; a Git push alone does
not complete this step. No RGB write flags, SDK control commands, permissions
changes, or privileged-container workarounds are used.

See `server-base/glances/README.md`: upstream Glances SMART discovery is **not**
standby-safe (pySMART scans/queries all drives before display filtering).
The shared default now discovers only NVMe controllers via sysfs and caches
health for sixty seconds. Only game-host Glances has been recreated. Other
hosts are unchanged until their own opt-in deployment. Intentional HDD checks
require a known transport and `smartctl -n standby,3,5`; skipped/unsupported
checks remain unknown. No sleeping HDD was probed and no fleet rollout occurred.
