# RGB: keep lighting off, and export its status

This host (HP Omen 30L) boots with the case lighting in the firmware default, and
the user does not want lighting on unless asked. Two small root services handle
that, installed by one script:

| Piece | What it does |
| --- | --- |
| `rgb-off.service` | At boot, and on `sudo systemctl start rgb-off.service`: forces every OpenRGB-detected device to black (`#000000`). Runs once, then exits. |
| `rgb-off-resume.service` | The same after suspend / hibernate / hybrid-sleep / suspend-then-hibernate (standard `sleep.target` wiring). |
| `rgb-status.timer` + `.service` | Every 10 minutes writes `/var/lib/host-status/rgb.json` for the Homepage OpenRGB card, now including the keep-off state (`policy`, `rows`). |

There is **no periodic re-assert** by default: it would fight lighting you set on
purpose. See [Opt-in re-assert](#opt-in-re-assert).

## Install (one command, idempotent)

```sh
sudo bash linux-game-server/rgb/setup.sh [--dry-run]
```

It installs `rgb-off`, `rgb-status` and `rgb_common.py` into `/usr/local/libexec`
(root:root; the units never run anything from the writable checkout) and the
four units into `/etc/systemd/system`, runs `daemon-reload`, enables
`rgb-off.service`, `rgb-off-resume.service` and `rgb-status.timer`, then starts
`rgb-off.service` and `rgb-status.service` once and prints a short summary
(enabled state, the policy file, the head of `rgb.json`). Re-running it is safe.
It exits non-zero, after finishing the rest, if `rgb-off` could not turn the
lights off.

## How `rgb-off` decides

1. `openrgb --noautoconnect --list-devices` enumerates the devices. Zone and mode
   names come only from that output.
2. Per device, from **that device's own `Modes:` line**:
   * if it lists `Off`: `openrgb --noautoconnect --device N --mode Off`
   * else `Direct`, then `Static`: `... --device N --mode Direct --color 000000`
   * if the chosen command fails, the next listed candidate is tried.
   * a mode the device does not list is never sent; a device listing none of the
     three is `skipped` (logged, not commanded).
3. Only lighting is touched: no profile is loaded or saved (`--profile`,
   `--save-profile`), no `--server`/`--gui`/`--i2c-tools`, no firmware writes.
   The tests assert that only `--noautoconnect --list-devices --device --mode
   --color` ever reach OpenRGB. A failure is detected from the exit code and
   from `Error:` / `Wrong number of colors` output (OpenRGB exits 0 for the latter).
4. Boot-time enumeration can race device readiness (hidraw/i2c nodes appear
   late), so it retries: 6 attempts, waiting 5, 10, 20, 30, 45 s (about 110 s).
   "No devices" and non-zero exits are retryable; devices already off are not
   commanded again. If nothing could be turned off it exits non-zero with
   `rgb-off: FAILED after N attempts: <reason>` in the journal. A device that
   only enumerates after `rgb-off` has finished is not covered until the next
   `systemctl start rgb-off.service` (or the opt-in timer).

On this controller the already-installed exporter reported the modes
`Direct, Static, Off, Breathing, Color Cycle, Blinking, Wave, Radial`, so the
expected command is `--mode Off`.

### Trigger

The unit passes `--trigger auto` (boot unit) or `--trigger resume`. `auto` records
`boot` while systemd is still starting up (`systemctl is-system-running` is
`initializing`/`starting`) and `manual` for a later `systemctl start`; if systemd
cannot say it records `unknown`.

### Policy status file

`/var/lib/host-status/rgb-policy.json` (0644, written atomically, one run =
one file):

```json
{"name":"off","color":"000000","applied_at":1791230520,"trigger":"boot","result":"applied",
 "devices":[{"name":"HP Omen 30L","mode_used":"Off","result":"applied"}],
 "attempts":1,"attempted_at":1791230520,"boot_id":"…"}
```

`applied_at` is the time of the last successful command (null if none).
`result` is `applied` only if at least one device was commanded and none failed.
The file is reset to `result: never` when a run starts, so last boot's success
never survives a crash or a long retry. `boot_id` lets the exporter ignore a file
left by an earlier boot (for example after you disabled the service).

## `rgb.json` additions (contract with the Homepage card)

Every existing field is kept (`updated`, `devices[]` with `mode_source`,
`available_modes`, `zone_details`, `led_names`, `error`). Added:

* `policy`: `{"name":"off","color":"000000","applied_at":<epoch|null>,
  "trigger":"boot|resume|manual|unknown"|null,"result":"applied|failed|never",
  "devices":[{"name","mode_used","result":"applied|failed|skipped"}]}`.
  `result: never` (with nulls) when the file is absent, unreadable, still
  pending, or from an earlier boot.
* `rows`: flat `{name,label}` rows for a dynamic list: per device
  `<type> · <mode> (last-set, not readback)`; per zone `detected` /
  `commanded off #000000 at HH:MM` (host local time) / `off command failed` /
  `not commanded (no off-capable mode)`; last `Lighting policy` =
  `off (#000000) · applied HH:MM by <trigger>` / `· never applied` /
  `· last attempt failed`.
* If OpenRGB fails: `error` stays and `rows` is the single row
  `OpenRGB` → `unavailable: <reason>`.

OpenRGB's CLI cannot read colours back, so no row ever states a colour as
*current*; "commanded off" means the command was accepted, not that the LEDs
were observed black.

## "Login" and desktop sessions

This host is headless, so "on login" does not apply: the unit runs at boot,
independent of any session, and again on resume. A desktop session could in
principle undo it afterwards (an OpenRGB GUI/`--autostart` entry, a profile
loader, vendor software), because it would run after `rgb-off`. Nothing in this
repo starts such a thing; if you ever add one, start `rgb-off.service` after it
or use the opt-in timer below.

## Holding the lights on deliberately

* Until the next boot/resume: just set the colours with OpenRGB. Nothing
  re-applies the policy in between.
* Across reboots: `sudo systemctl disable rgb-off.service rgb-off-resume.service`
  (current lighting is untouched; the card then shows `never applied`). While a
  boot run is still retrying, `sudo systemctl stop rgb-off.service` aborts it.
* Restore the default (off at every boot/resume):
  `sudo systemctl enable rgb-off.service rgb-off-resume.service && sudo systemctl start rgb-off.service`,
  or just re-run `setup.sh`.

## Opt-in re-assert

Not installed. If you do want lights forced off every 30 minutes, create
`/etc/systemd/system/rgb-off.timer`:

```ini
[Unit]
Description=Re-assert RGB off (opt-in)
[Timer]
OnBootSec=10min
OnUnitActiveSec=30min
[Install]
WantedBy=timers.target
```

then `sudo systemctl enable --now rgb-off.timer`. It will override any lighting
you set in between, and each run re-enumerates the hardware. Remove with
`sudo systemctl disable --now rgb-off.timer && sudo rm /etc/systemd/system/rgb-off.timer`.

## Exporter probes and the device cache

`openrgb --list-devices` runs every OpenRGB detector, not only HID. Reading the
HP Omen 30L controller source (OpenRGB master; installed build is the Debian
`0.9+ (git)` 2025-10-09 snapshot), detection only opens the hidraw node and
builds the zone table. It writes nothing to the device; writes happen in
`SendZoneUpdate` (set colour / set mode). So that probe should not change
lighting. The other detectors include SMBus/I2C scans (`i2c_i801` is loaded and
`/dev/i2c-*` exist), which OpenRGB itself warns can disturb some hardware, and a
probe every 10 minutes is 144 root hardware scans a day for an inventory that
changes only when hardware does. So `rgb-status` caches the parsed device info in
`/var/lib/rgb-status/devices.json` (private) and re-probes only when the cache is
missing, older than 24 h (`RGB_PROBE_MAX_AGE`), from an earlier boot, or with
`/usr/local/libexec/rgb-status --refresh`. Empty or failed probes are never
cached. The 10-minute run still refreshes `policy` and `rows` from the status
file without touching the hardware.

**Untested hardware risk:** this reasoning comes from source reading. I did not
observe, on the physical machine, whether a probe leaves the lights unchanged,
nor test the cache-miss path on the real controller.

`rgb-off` and `rgb-status` take one shared `flock` (`/run/rgb-lock/openrgb.lock`,
the `RuntimeDirectory=rgb-lock` both units declare) around every single OpenRGB
invocation, so a list and a set-colour never overlap.

## Operating it

```sh
systemctl status rgb-off.service rgb-status.timer
journalctl -u rgb-off -b            # attempts, chosen modes, FAILED lines
cat /var/lib/host-status/rgb-policy.json
sudo systemctl start rgb-off.service   # apply again now (trigger: manual)
```

Tests (stub `openrgb`, no hardware): `cd linux-game-server/tests && python3 -m unittest test_rgb_common test_rgb_off test_rgb_status test_rgb_units`.

## Not verified on the real machine

Physical lights going dark, the real OpenRGB mode names beyond what the
exporter already reported, and root enumeration/commands against the real
controller (none of this could be run without root). Also not exercised on the
host: the `boot` vs `manual` classification at a real boot, the sleep-target
wiring on a real resume, and `ExecStopPost=systemctl start --no-block` from
inside the sandbox (it is `-`-prefixed, so a failure there cannot fail the unit).
`systemd-analyze verify` and the stub tests pass.
