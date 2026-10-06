# Homepage generation and compact Servers inventory

The game host's opt-in grouped bar shows Compute, Storage, Connectivity and
System. Lighting is deliberately separate on the **OpenRGB** card, never
in `topbarExtras`; `topbar.rgb` is rejected by the generator. The card maps
the installed RGB exporter's flat `rows` array and shows its update age.
See [the game dashboard guide](../../linux-game-server/homepage/README.md)
and [the keep-off service guide](../../linux-game-server/rgb/README.md).

## Servers inventory

Every dashboard gets the same six-row Servers cards from `fleet.json`:
Platform, Board / SoC, CPU (model + cores / threads), Memory (OS-visible usable
GiB), Graphics (model / type / dedicated VRAM or shared / unknown), and Software
(OS + kernel grouped). Hostname is not repeated as another row.

Platform, board/chipset, CPU and graphics are the user-approved live inventory
snapshot in each server's `facts` object. Update those fields after hardware
changes, rather than guessing from a vendor or OS. The HP game machine identifies
as OMEN **25L GT12** in platform inventory; its OpenRGB controller calls itself
**HP Omen 30L**. They are separate identification sources, not interchangeable.
Pi GPU capacity is unavailable; main Intel graphics share RAM; only the game
GTX 1070 has confirmed 8 GiB dedicated memory.

Memory stays `/api/4/mem.total`, scaled by `1/1073741824` with Homepage native
`float` formatting and the explicit **GiB usable** suffix. It is not installed
DIMM capacity and is not a nominal 16 / 4 / 32 GB label. Software stays the live
`/api/4/system` `linux_distro` plus `os_version`. The native customapi widgets
refresh hourly; there is no new card JS renderer, polling loop or endpoint.
`remap: [{any: true, to: ...}]` renders recorded hardware facts natively;
`additionalField` groups OS and kernel into one row. All rows use list layout.

The generator writes all three hosts' `services.yaml`. Card changes do not
change the top bar. During a card-only rollout, transfer only
the Servers block after checking the rest of each destination config. Preserve
the host's private `.env`, other service groups and topbar artifacts. Revalidate
with the **actual container PORT** (main/game 3000; Pi 3001), then reload and
verify the rendered rows. Synchronizing the entire branch would also update the
shared Glances entrypoint and require its new telemetry bind mount; do not do
that under a Servers-only authorization.

```sh
python3 server-base/homepage/generate.py
python3 server-base/homepage/generate.py --check
python3 server-base/tests/test_generate.py -v
```

## Grouped top bar: loading, failure and storage contract

Opt in per host with `topbar.grouped` in `fleet.json`; every key below is a
per-host value, so nothing is game-specific. Non-opted-in hosts' generated
output is byte-identical (tested).

| `topbar` key | Meaning | Default |
|---|---|---|
| `label`, `net`, `disks` | host label, NIC tile, filesystem mounts to show | required |
| `diskLabels` | `{mount: label}` | `/etc/hostname` = System disk, else the mount |
| `hddDisks` | mounts that are spinning disks: shown as **Not monitored · HDD**, never polled or displayed, even if a backend row leaks through | none |
| `gpuTypes`, `gpuFields`, `gpu` | `{gpu_id: dGPU/iGPU}`, rows kept per GPU id (e.g. an iGPU with no VRAM figure keeps `["Usage"]`), `false` = no GPU tile (Pi) | none |
| `temperatureLabels` | storage thermal sensors (`["NVMe"]`) reserved from first paint | none |
| `wifi` | reserve a Wi-Fi tile | no |
| `safeSSDHealth` | **opt in** to `/api/4/smart` + `/api/4/storagepolicy`; with `false` the page never requests either | `false` |
| `filesystemIntervalMs` / `smartIntervalMs` | expected backend cache cadence: header text, stale threshold (2x) and request cadence; values below 5 min / 10 min are clamped up | 300000 / 600000 |

Current fleet: all three hosts enable the grouped bar. Game and main opt in to SSD
health (their backend is NVMe-only and cached; main declares its three DAS HDD
mounts in `hddDisks`); the Pi has no NVMe, so it stays `false`.

### First paint, loading and failure behaviour

- Generated CSS draws a stable skeleton in `#information-widgets::before` from
  first paint (an SVG data URI of the same tiles, dashes and "Loading", with
  accessible "Host metrics loading..." text). It issues **no request**, and the
  native widget is hidden only while scripting is enabled. Tile heights are
  computed per host from its row counts into `--monitor-h-*` variables shared by
  the skeleton and live tiles, so the swap has no layout shift.
- `custom.js` mounts the live panel with the same dashes as soon as it runs; a
  value is only ever shown after a real payload. Unknown is an em dash, never 0.
- No JS: native widget is visible immediately (no skeleton). Enhancement script
  blocked or failing: the skeleton falls back to the native widget after 12 s
  (CSS-only). Silent or malformed native payload: the panel stays and says
  "Unavailable · awaiting native data" (after 12 s plus at most one 5 s tick)
  or "Unavailable"; invalid payloads are never rendered as numbers.
- Native Homepage still owns native polling. The first native response often
  precedes `custom.js`, so first data arrives on the next native cycle
  (measured ~3.2 s with a 150 ms backend; the skeleton shows until then).
- Extras (GPU, network, Wi-Fi) poll at 5 s; storage health at >= 10 min and only
  with `safeSSDHealth`.

### Storage ages (consumes `server-base/glances/README.md`)

Native filesystem rows carry `collected_at`, `collection_age_seconds`,
`collection_interval_seconds` and `collection_status`; the panel shows
`Cached · collected Nm ago`, `Stale · ...` (older than 2x the interval),
`Collection error · last value · ...`, `Waiting for first collection`, or
`Cached · age unknown` when a backend gives no metadata. Age is the backend's
monotonic seconds advanced by the time since this browser received them, never
the HTTP response time (the proxy may serve a cached snapshot instantly) and
never a browser-vs-server clock comparison. NVMe health matches
`storagepolicy.smart.devices[].DeviceName` for its age; `smart.enabled=false`
shows "Health disabled by host policy".

### Verification

```sh
python3 server-base/tests/test_generate.py -v
node --test linux-game-server/tests/test_grouped_topbar.cjs linux-game-server/tests/test_grouped_loading.cjs
# real Chromium, against a throwaway Homepage preview (needs `playwright`):
python3 linux-game-server/tests/browser_grouped_firstpaint.py --url http://127.0.0.1:<port>/ --host <fleet-dir> --fixture <json> --synthetic-storage
python3 linux-game-server/tests/browser_grouped_fallbacks.py --url http://127.0.0.1:<port>/ --host <fleet-dir> --output <dir>
```

The browser scripts delay `custom.js`, hold or fail native responses, record
per-frame native visibility, layout-shift sources, content position and
request counts, and fail on any request to `/fs`, `/all`, `/sensors` (and
`/smart`, `/storagepolicy` unless the host opted in). `--synthetic-storage`
injects schema-shaped rows for layout/state testing only; they are not
measurements.
