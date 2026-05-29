# LACT Tuning Guide — AMD Radeon AI PRO R9700

LACT (Linux AMD Configuration Tool) is a GUI + daemon that persists GPU tuning across reboots via a background service. The R9700 runs RDNA 4 (`navi48`/gfx1201), which uses a **voltage offset** model — you shift the entire voltage curve down by N mV rather than editing individual VF points (that was RDNA 1/Vega).

## Known issue: fan control broken on some R9700 units

Before doing anything else, verify fan control actually works on your board. Some R9700 units (confirmed: ASUS Turbo, vBIOS `115-G287BP00-100`) have a firmware mismatch that makes fan control completely non-functional on Linux. LACT's fan curve UI is grayed out, `pwm1` is read-only, and the config's fan curve is silently ignored — the GPU can reach 109 °C with fans physically stationary.

**Root cause:** the card's SMU firmware reports interface version 50 (`0x32`), but the amdgpu driver only supports up to version 46 (`0x2e`). This affects all kernel versions tested through 7.0 as of May 2026.

```bash
# Check 1: does the fan control sysfs path exist?
ls /sys/class/drm/card0/device/gpu_od/fan_ctrl/
# Good: lists fan_curve  acoustic_limit_rpm_threshold  fan_minimum_pwm  ...
# Bad:  "No such file or directory" → fan control is broken on your unit

# Check 2: confirm the SMU mismatch in dmesg
sudo dmesg | grep -i "smu.*version"
# Bad:  "SMU driver if version not matched" → confirms the bug
```

If you're affected: AMD has a fix in progress (targeting TheRock 7.13 / ROCm 7.13). Until then, the voltage offset and power cap sections below still work — only fan control is broken. See [ROCm issue #6101](https://github.com/ROCm/ROCm/issues/6101) for status.

---

## Prerequisites

### 1. Install LACT

```bash
# Arch / CachyOS — official repos
sudo pacman -S lact

# Enable and start the daemon
sudo systemctl enable --now lactd
```

Ubuntu: download the matching `.deb` from [LACT releases](https://github.com/ilya-zlobintsev/LACT/releases).

### 2. Enable AMD overdrive — kernel cmdline only

Add `amdgpu.ppfeaturemask=0xfff7ffff` as a **kernel boot parameter**. Do not use `/etc/modprobe.d/` — the driver silently strips the OD feature bit (0x4000) when loaded from modprobe, resulting in `0xfff7bfff` instead of `0xfff7ffff` with no log warning.

**CachyOS / systemd-boot:** add to the `options` line in `/boot/loader/entries/*.conf`, then reboot.

**GRUB:**
```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="... amdgpu.ppfeaturemask=0xfff7ffff"

sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

Verify after reboot:
```bash
cat /sys/module/amdgpu/parameters/ppfeaturemask
# Must print 0xfff7ffff — if you see 0xfff7bfff you used modprobe, fix it
```

---

## Applying the LACT config

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
lact-cli info
watch -n1 lact-cli info
```

### lact-cli reference

The CLI is intentionally minimal — all tuning is done via config file, not CLI flags.

```bash
lact-cli list-gpus          # list GPU PCI IDs
lact-cli info               # current clocks, temps, power, fan speed
lact-cli info --gpu <id>    # target a specific GPU
```

For scripting or deeper integration, use the LACT Unix socket API directly.

---

## What the config does

| Setting | Value | Why |
|---|---|---|
| `voltage_offset` | **-80 mV** | Conservative, proven on R9700 Linux. Reduces heat without capping clocks. Go to -100 or -120 mV after stability testing. |
| `power_cap` | **210 W** | Stock TDP ~260 W. Token generation is memory-bandwidth bound so this barely affects t/s while cutting thermals and fan noise. ~15% slower prefill (TTFT) is the tradeoff. |
| `performance_level` | **manual** | Required for power cap and voltage controls to be honored by the driver. |
| Fan curve | **junction temp, 5 entries** | Quiet below 70 °C, 5 °C-step ramp to 60% at 90 °C. No-op if SMU mismatch bug is present. |

---

## Sysfs fallback (when LACT can't reach fan/clock registers)

If `gpu_od` is missing or LACT's controls are grayed out, you can still apply voltage offset and power cap directly via sysfs. Fan control is unavailable but undervolting still works.

```bash
# Set manual performance level
echo "manual" | sudo tee /sys/class/drm/card0/device/power_dpm_force_performance_level

# Apply voltage offset (-75mV — conservative starting point)
echo "vo -75" | sudo tee /sys/class/drm/card0/device/pp_od_clk_voltage
echo "c"      | sudo tee /sys/class/drm/card0/device/pp_od_clk_voltage

# Verify
cat /sys/class/drm/card0/device/pp_od_clk_voltage
# Should show: OD_VDDGFX_OFFSET: -75mV

# Set power cap (in microwatts)
echo "210000000" | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap  # quiet
echo "315000000" | sudo tee /sys/class/drm/card0/device/hwmon/hwmon*/power1_cap  # performance
```

These settings reset on reboot. Persist them via a systemd service or by letting LACT handle it once the SMU bug is fixed.

---

## Tuning further

### Performance profile (max inference throughput)

From the [amd-r9700-vllm-toolboxes](https://github.com/kyuz0/amd-r9700-vllm-toolboxes) project — higher power budget + lower voltage = more clock headroom for prefill:

```yaml
clocks_configuration:
  voltage_offset: -75
power_cap: 315.0
```

vs the config's conservative 210 W / -80 mV. Tradeoff: more power and heat, faster TTFT.

### More aggressive undervolt (gaming / max perf)

RDNA 4 has exceptional undervolt headroom. Community data on 9070/9070 XT (same arch):

| Tester | Offset | Result |
|---|---|---|
| Der8auer (9070 XT) | -170 mV | +10% FPS, 2.9 → 3.36 GHz |
| Alva Jonathan (9070) | -125 mV | +10% FPS, 2.6 → 3.0 GHz |
| Conservative start | -75 mV | safe baseline |

For gaming: raise `power_cap` toward stock (~260 W), drop `voltage_offset` to -100 to -150 mV, test stability.

### Capping max clock for pure inference

Token generation is memory-bandwidth bound — capping the GPU clock saves power with no t/s impact:

```yaml
clocks_configuration:
  voltage_offset: -80
  max_core_clock: 2000   # MHz — adjust to taste
```

### Automatic profiles (inference vs gaming)

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

---

## Stability testing

After changing `voltage_offset`, stress the GPU before trusting the settings:

```bash
# Watch temps, clocks, power live
watch -n1 'rocm-smi --showtemp --showclocks --showpower'

# Run a large LLM for 10–15 min under inference load
# If you see crashes, GPU resets, or display corruption → back off by 10–15 mV
```

---

## References

- [ROCm issue #6101 — R9700 fan not spinning (54 comments, open)](https://github.com/ROCm/ROCm/issues/6101)
- [ROCm issue #6078 — SMU interface version mismatch (closed, superseded)](https://github.com/ROCm/ROCm/issues/6078)
- [amd-r9700-vllm-toolboxes TUNING.md](https://github.com/kyuz0/amd-r9700-vllm-toolboxes)
- [Undervolting the R9700 — Level1Techs Forums](https://forum.level1techs.com/t/undervolting-the-r9700/249946)
- [Undervolted RX 9070 XT beats RTX 5080 — Tom's Hardware](https://www.tomshardware.com/pc-components/gpus/undervolted-rx-9070-xt-beats-rtx-5080-rx-9070-and-9070-xt-models-with-heavy-coolers-have-massive-oc-headroom)
- [LACT GitHub](https://github.com/ilya-zlobintsev/LACT)
- [LACT CONFIG.md](https://github.com/ilya-zlobintsev/LACT/blob/master/docs/CONFIG.md)
