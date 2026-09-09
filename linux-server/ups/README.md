# UPS (NUT)

[Network UPS Tools](https://networkupstools.org/) with two USB UPS units wired
in series:

- **cyberpower** — CyberPower CST135UC2 (1500VA), `usbhid-ups`, standalone. This
  is the **primary** UPS: on power loss it pushes ntfy alerts; when the battery
  runs low it shuts the server down cleanly and tells the UPS to cut its outlets
  so everything restarts when wall power returns.
- **ecoflow** — EcoFlow River 3 Plus, `usbhid-ups`, **monitoring-only** (no
  shutdown wiring). Added as a battery bank upstream of the CyberPower.

Wiring: `wall power -> EcoFlow -> CyberPower -> server`. The EcoFlow is on the
wall frontier, so its `ups.status` is the early indicator of grid loss; the
CyberPower steps in a moment later for the actual server supply.

The EcoFlow needs NUT **2.8.4+**, which ships the dedicated `EcoFlow HID` 
subdriver. Do **not** set `explore = 1` for it — that forces the generic EXPLORE
subdriver, which then reports only identity and a constant `OB` with no
battery/input data. The stanza in `ups.conf` mirrors EcoFlow's own "Power
Manager" config (`usb_hid_ep_in/out = 1`, `ignorelb`,
`override.battery.runtime.low = -1`).

## Setup

1. Install NUT (the root `setup.sh --profile server` installs it via
   `packages.json`, or):
   ```sh
   sudo apt install nut
   ```
2. Configure:
   ```sh
   cd linux-server/ups
   cp .env.example .env
   # set UPSMON_PASSWORD (openssl rand -hex 16) + the ntfy URL/topic
   ```
3. Deploy configs to `/etc/nut` and enable the services:
   ```sh
   bash setup.sh --dry-run     # works before .env exists
   sudo bash setup.sh
   ```
4. Verify:
   ```sh
   upsc cyberpower ups.status   # expect: OL (on line power)
   upsc cyberpower               # full variable dump — charge, runtime, load
   upsc ecoflow ups.status       # expect: OL (wall power present)
   upsc ecoflow                  # charge, runtime, AC input state
   bash ../../verify.sh --platform server
   journalctl -u nut-monitor -f
   ```
5. Test a notification (safe — no shutdown involved):
   ```sh
   sudo -u nut NOTIFYTYPE=ONBATT /etc/nut/ups-notify.sh "test event"
   ```
6. In BIOS, set **Restore on AC Power Loss → Power On** so the machine boots
   when the UPS re-energizes its outlets after an outage.

## What happens during an outage

1. Wall power drops → upsmon logs `ONBATT` and pushes an urgent ntfy alert.
2. Power returns before the battery runs low → `ONLINE` alert, nothing else.
3. Battery hits the low threshold → upsmon runs `SHUTDOWNCMD`
   (`shutdown -h +0`), sets `/etc/killpower`, and the Debian shutdown hook
   tells the UPS to power off its outlets after the OS halts.
4. Wall power returns → the UPS re-energizes, and with the BIOS set to
   power-on the server boots unattended.

## Tuning

- **Low-battery threshold**: CyberPower firmware fires LOWBATT late (~10%
  charge). For more headroom, uncomment in `ups.conf` and re-run `setup.sh`:
  ```
  override.battery.charge.low = 25      # shut down at 25% charge
  override.battery.runtime.low = 300    # or at 5 minutes runtime left
  ```
  `setup.sh` restarts `nut-driver@cyberpower` when `ups.conf` changes, so the
  new threshold is active immediately without a reboot.
- Poll/timing knobs (`POLLFREQ`, `HOSTSYNC`, `DEADTIME`, `FINALDELAY`) are at
  conventional values in `upsmon.conf.template`.
- Brief blips send an ONBATT + ONLINE alert pair. If that gets noisy,
  `upssched` can debounce (only alert after N seconds on battery) — not wired
  up; layer it in later if needed.
- Communication loss alerts fire on the `COMMBAD` transition and recovery on
  `COMMOK`; recurring `NOCOMM` warnings stay in the system journal instead of
  pushing every five minutes.

## Dashboard (PeaNUT)

[PeaNUT](https://github.com/Brandawg93/PeaNUT) serves a web dashboard with
charge/load/runtime graphs at `https://peanut.<tailnet>.ts.net/` (Tailscale
sidecar per [`../HTTPS.md`](../HTTPS.md), host-networked variant like glances —
PeaNUT itself must stay on the host network to reach the loopback-only `upsd`)
and feeds the homepage **ups** card (`type: peanut` widget via localhost).
Auth is disabled (read-only stats on a trusted network, same posture as
glances). Its runtime settings dir (`peanut-config/`) is gitignored.

```sh
cd linux-server/ups
# set TS_AUTHKEY in .env (same OAuth client secret as the other sidecars)
docker compose up -d
```

## Files

| Repo file | Deployed to | Purpose |
|---|---|---|
| `nut.conf` | `/etc/nut/nut.conf` | `MODE=standalone` (turns NUT on) |
| `ups.conf` | `/etc/nut/ups.conf` | `usbhid-ups` drivers for both the CyberPower (primary) and EcoFlow (monitoring-only) |
| `upsd.conf` | `/etc/nut/upsd.conf` | upsd listens on loopback only |
| `upsd.users.template` | `/etc/nut/upsd.users` | upsmon user (password from `.env`) |
| `upsmon.conf.template` | `/etc/nut/upsmon.conf` | shutdown + notification policy |
| `ups-notify.sh` | `/etc/nut/ups-notify.sh` | NOTIFYCMD → ntfy |
| (rendered from `.env`) | `/etc/nut/ups-notify.env` | ntfy settings for the hook |

Each unit gets its own systemd driver instance (`nut-driver@cyberpower`,
`nut-driver@ecoflow`); `nut-server` and `nut-monitor` are shared. The homepage
dashboard shows both via PeaNUT (`key: cyberpower` and `key: ecoflow`).

Everything in `/etc/nut` is `root:nut 640` (the notify script `750`); secrets
live only in the gitignored `.env` and the rendered `/etc/nut` files.
