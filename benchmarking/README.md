# Benchmarking Suite (Ubuntu 24.04)

Standardized benchmark suite for comparing workstation performance across
machines. Two commands: install, run.

```bash
./install.sh   # downloads tools into benchmarking/tools/ (multi-GB)
./run.sh       # runs everything, writes benchmarking/results/<host>-<timestamp>/
```

Run a subset with `--only` / `--skip` (both scripts, comma-separated):

```bash
./run.sh --only superposition          # just one benchmark
./run.sh --only geekbench,blender      # a subset
./run.sh --skip superposition          # everything except one
./install.sh --only geekbench          # install a single tool
```

## What runs automatically

| Benchmark | Measures | Notes |
| --- | --- | --- |
| Geekbench 6 | CPU single/multi-core, GPU OpenCL + Vulkan compute | Free tier **requires internet and uploads every result** to browser.geekbench.com; the result URL is captured in the log. Offline/JSON export needs a Pro license. |
| Blender Open Data | CPU and GPU render throughput (samples/minute) | Scenes: monster, junkshop, classroom. Fully headless, JSON output. |
| Unigine Superposition | GPU graphics (OpenGL), 1080p medium fullscreen | Needs a desktop session (`DISPLAY`/`WAYLAND_DISPLAY`) — skipped over bare SSH. Fullscreen so the render is a true 1920×1080 on any display (windowed mode clamps to the usable desktop area and silently degrades the score); it takes over the screen for the duration. Free edition has no official batch mode; the run script drives the engine binary directly. |

## Manual benchmarks

Documented only — no automation is possible or licensed:

- **OCCT** (stress & thermals): download from <https://www.ocbase.com/download>.
  Free Personal edition is GUI-only (CLI is Enterprise-only) and licensed for
  non-commercial use only.
- **SPECviewperf 2020 Linux Edition** (workstation graphics): register at
  <https://gwpg.spec.org/benchmarks/benchmark/specviewperf-2020v3-0-linux-edition/>.
  ~80 GB disk; viewsets install via its interactive utility; needs a large
  desktop display for valid runs.

## GPU vendor notes

`run.sh` auto-detects the GPU: NVIDIA → Blender `OPTIX`, AMD → Blender `HIP`
(override with `--device-type`). On AMD:

- Geekbench OpenCL needs the ROCm/AMDGPU-PRO OpenCL ICD; Vulkan (Mesa RADV)
  is the more reliable run. Per-API failures are logged and skipped, they
  don't abort the suite.
- RDNA4 cards need Blender 4.5+ (pinned default) and ROCm 7+ for HIP-RT.

## Versions

Pinned in `lib/common.sh` for cross-machine comparability; override per run:

```bash
GEEKBENCH_VERSION=6.8.0 ./install.sh --only geekbench --force
GEEKBENCH_VERSION=6.8.0 ./run.sh
```

The tools live in version-suffixed directories, so an override must be passed
to **both** commands — a plain `./run.sh` after an overridden install looks
for the pinned default and skips the benchmark.

`install.sh` prints the sha256 of each archive it downloads directly
(Geekbench, the Blender launcher, Superposition) — record it with the results
if you need provenance. The Blender engine and scene payloads are fetched by
the launcher itself and are not checksummed here.

## Results & privacy

Each run writes `results/<label>-<timestamp>/` with `machine-info.txt`
(CPU/GPU/RAM/kernel/driver versions), one raw log or JSON per benchmark, and
a `summary.md` with the headline numbers.

`tools/` and `results/` are gitignored. **Never commit results**: they
contain hostnames, hardware identifiers, and Geekbench result URLs, and this
repo is public.

## Future improvements

- Phoronix Test Suite as an alternative harness — evaluated and left out for
  now: its `pts/workstation` suite is deprecated upstream and overlaps poorly
  with the GPU-focused list above, but individual profiles (e.g.
  `pts/unigine-super`) could wrap some of these benchmarks later.
- Cross-machine comparison report generated from two or more `results/` dirs.
