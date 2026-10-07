# Game-host grouped metrics

`server-base/fleet.json` enables `topbar.grouped` **only** for this host.
The generator appends `server-base/homepage/grouped-topbar.css` and replaces
its legacy extras poller with `grouped-topbar.js`. Other hosts' generated
settings, CSS and JS are unchanged. Edit sources, never the generated copies:

```sh
python3 server-base/homepage/generate.py
python3 server-base/homepage/generate.py --check
python3 server-base/tests/test_generate.py
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
- **System:** full native uptime and Homepage's browser-local date/clock.
  RGB lighting belongs exclusively on the **OpenRGB card**, not in this bar.

The native Glances and datetime React widgets stay mounted. A narrowly scoped
passive `fetch` wrapper clones only the same-origin, index-0
`/api/widgets/glances` response; it returns the original Response to SWR.
It creates **no native polling** and reuses native sensors instead of making
another `/sensors` request. Homepage v2.4.0 owns its 1500ms refresh and error
retry behavior. The grouped view renders only after a compatible payload;
without JS, CSS or that payload the native view remains available.

One non-overlapping 5000ms extras timer reads the public host Glances
`/glances/api/4/{gpu,network,wifi}` paths, with a 4s request timeout.
SMART is fetched every 60s. Extras pause in hidden tabs and refresh on return.
URLs reject userinfo/unsafe protocols, requests omit credentials, and API text
is HTML-escaped. There are no RGB requests from the top bar; the generator
rejects `topbar.rgb` so that it cannot return through configuration.

Failed reads preserve the last value with **Unavailable · last value** text;
missing numeric fields use an em dash, not zero. Native/extras older than
15s and SMART older than 130s are **Stale · last value**.
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

## GPU bytes and spindle-safe health

The game host explicitly inventories `nvidia0` as a **dGPU**. Live PCI and
Glances discovery expose one NVIDIA GeForce GTX 1070 and no active iGPU adapter;
do not invent an iGPU tile. The GPU model stays visible in its tile. With this
host's `GLANCES_GPU_MEMORY=true`, the shared NVML adapter adds byte-valued
`memory_used` and `memory_total` to Glances `/api/4/gpu`. The tile shows used /
total binary units alongside the original percentage. Missing byte readings
are `— / —`, never estimated from percent. Future hosts set `topbar.gpuTypes`
by actual `gpu_id` inventory; unspecified types remain explicitly unknown.

See `server-base/glances/README.md`: upstream Glances SMART discovery is **not**
standby-safe (pySMART scans/queries all drives before display filtering).
The shared default now discovers only NVMe controllers via sysfs and caches
health for sixty seconds. Only game-host Glances has been recreated. Other
hosts are unchanged until their own opt-in deployment. Intentional HDD checks
require a known transport and `smartctl -n standby,3,5`; skipped/unsupported
checks remain unknown. No sleeping HDD was probed and no fleet rollout occurred.

## OpenRGB lighting card

The **OpenRGB** card is in the Game server group and uses the root exporter's
public-safe `/host-status/rgb.json`, with OpenRGB's own logo (`/icons/openrgb.ico`,
fetched by `fetch-assets.sh`). Two native `customapi` widgets poll every
five minutes: the first renders the exporter's flat `rows` array (one row per
device with its zone count and off-command result, then the keep-off policy),
and the second renders `updated` as **Export updated**. Epoch seconds are scaled by 1000 before
Homepage's relative-date formatter; an old export stays visibly old instead
of being presented as a new sample. No dedicated browser polling loop is added.

The device row says **commanded off #000000 at HH:MM**, meaning the command was
accepted, not that a color was read back. Failures and never-applied
policy states come from the exporter.
The CLI cannot read zone colors or independent per-zone modes back.

Install the exporter and boot/resume keep-off policy together, using the
single installer in [the RGB guide](../rgb/README.md). Do not use the former
standalone exporter-copy commands; they omit its shared module and units.
On October 5, 2026 the install was verified: the controller accepted its
`Off` mode at 11:51 PDT, both keep-off units were enabled, the exporter
published all seven zone names and policy state, and the card rendered on
desktop and at 390px without horizontal overflow. Reboot/resume behavior
and physical lights-off confirmation remain hardware validation steps,
not things the browser or a successful command can prove.
