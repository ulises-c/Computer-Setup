# LACT Tuning Guide — AMD Radeon AI PRO R9700

LACT (Linux AMD Configuration Tool) is a GUI + daemon that persists GPU tuning across reboots via a background service. The R9700 runs RDNA 4 (`navi48`), which uses a **voltage offset** model — you shift the entire voltage curve down by N mV rather than editing individual VF points (that was RDNA 1/Vega).

## Prerequisites

### 1. Install LACT

```bash
# Arch / CachyOS — official repos
sudo pacman -S lact

# Enable and start the daemon
sudo systemctl enable --now lactd
```

Ubuntu: download the matching `.deb` from [LACT releases](https://github.com/ilya-zlobintsev/LACT/releases).

### 2. Enable AMD overdrive (required for voltage/clock control)

Add the kernel parameter `amdgpu.ppfeaturemask=0xffffffff` to your boot entry.

**CachyOS / Arch (GRUB):**
```
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... amdgpu.ppfeaturemask=0xffffffff"
```
```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

**systemd-boot:** add to your `/boot/loader/entries/*.conf` options line, then reboot.

Verify it took:
```bash
cat /sys/module/amdgpu/parameters/ppfeaturemask
# should print 0xffffffff (or -1 in decimal)
```

## Applying the config

Find your GPU's PCI ID:
```bash
lact-cli list-gpus
# e.g. → 0000:09:00.0  AMD Radeon AI PRO R9700
```

Copy the config template and replace `GPU_ID_HERE`:
```bash
sudo cp linux-desktop/lact_r9700.yaml /etc/lact/config.yaml
sudo sed -i 's/GPU_ID_HERE/0000:09:00.0/' /etc/lact/config.yaml   # use your actual ID
sudo systemctl restart lactd
```

Verify settings are live:
```bash
lact-cli info          # shows current clocks, power, temps
watch -n1 lact-cli info
```

## What the config does

| Setting | Value | Why |
|---|---|---|
| `voltage_offset` | **-80 mV** | Proven safe on R9700 Linux; reduces heat without capping clocks. Can go to -100 or -120 mV after stability testing. |
| `power_cap` | **210 W** | Stock TDP ~260 W. Token generation is memory-bandwidth bound so this barely affects t/s while cutting thermals and fan noise significantly. ~15% slower prefill (TTFT) is the trade-off. |
| `performance_level` | **manual** | Required for power cap and clock controls to be honored by the driver. |
| Fan curve | **junction temp** | Hotspot (junction) is more conservative than edge. Ramps to 60% by 75 °C to keep junction under ~80 °C at inference load. Requires exactly 5 entries on RDNA 3+. |

## Tuning further

### More aggressive undervolt (gaming / max performance)

RDNA 4 has exceptional undervolt headroom. Community data on the 9070 XT (same arch):

| Tester | Offset | Result |
|---|---|---|
| Der8auer (9070 XT) | -170 mV | +10% FPS, 2.9 → 3.36 GHz |
| Alva Jonathan (9070) | -125 mV | +10% FPS, 2.6 → 3.0 GHz |
| Conservative start | -75 mV | safe; larger cards may tolerate more |

For gaming, also raise `power_cap` back toward stock (~260.0) and optionally bump it to 110% of TDP (+10%) to give the extra clocks room to sustain.

### Capping max clock for AI inference only

If you want to aggressively limit power for pure inference (token gen), add `max_core_clock` to `clocks_configuration`:

```yaml
clocks_configuration:
  voltage_offset: -80
  max_core_clock: 2000   # MHz — adjust to taste; token gen is unaffected
```

This trades prefill speed for lower sustained power draw.

### Profiles (automatic switching)

LACT supports named profiles that auto-activate based on running processes:

```yaml
profiles:
  inference:
    gpus:
      GPU_ID_HERE:
        power_cap: 210.0
        clocks_configuration:
          voltage_offset: -80
    rule:
      type: process
      filter:
        name: llama-server
  gaming:
    gpus:
      GPU_ID_HERE:
        power_cap: 285.0
        clocks_configuration:
          voltage_offset: -150
    rule:
      type: process
      filter:
        name: steam
auto_switch_profiles: true
```

## Stability testing

After changing `voltage_offset`, stress-test before trusting the settings:

```bash
# GPU compute stress (ROCm)
rocm-smi --showuse
# run a large LLM for 10–15 min and watch junction temp + clocks
watch -n1 'rocm-smi --showtemp --showclocks --showpower'
```

If you see crashes, GPU resets, or display corruption, back off the voltage offset by 10–15 mV.

## References

- [Undervolting the R9700 — Level1Techs Forums](https://forum.level1techs.com/t/undervolting-the-r9700/249946)
- [Undervolted RX 9070 XT beats RTX 5080 — Tom's Hardware](https://www.tomshardware.com/pc-components/gpus/undervolted-rx-9070-xt-beats-rtx-5080-rx-9070-and-9070-xt-models-with-heavy-coolers-have-massive-oc-headroom)
- [LACT GitHub](https://github.com/ilya-zlobintsev/LACT)
- [LACT CONFIG.md](https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md)
