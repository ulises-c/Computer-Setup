# macOS Benchmark Suite

Scripts for benchmarking and stress-testing Apple Silicon Macs. Designed to
run identically on two machines so results can be diffed with `compare.sh`.

## Files

| File | Purpose |
|---|---|
| `benchmark.sh` | Synthetic CPU, memory bandwidth, storage I/O |
| `standardized.sh` | Geekbench 6, Cinebench, Blender Benchmark wrappers |
| `llm-bench.sh` | Local LLM tokens/s — same model through MLX and llama.cpp |
| `omlx-bench.sh` | oMLX server concurrency sweep — continuous-batching throughput |
| `stress-test.sh` | Sustained CPU load — detects thermal throttling |
| `compare.sh` | Side-by-side diff of two result files (any suite) |
| `collect-sysinfo.sh` | Machine identity JSON (called internally) |
| `lib.sh` | Shared helpers (sourced, not run directly) |
| `results/` | Output directory — gitignored, machine-local |

All result files carry a `metadata.suite` tag (`benchmark`, `standardized`,
`llm`, `omlx`, `stress`). `compare.sh` auto-detects it and refuses to compare
across suites.

## Prerequisites

Required:
- `openssl@3` — CPU benchmark (`brew install openssl@3`). Stock macOS
  `openssl` is LibreSSL, which lacks `speed -seconds`; the scripts pick up the
  keg-only brew install automatically.
- `jq` — JSON assembly (`brew install jq`)

Optional, for `benchmark.sh` (each unlocks an additional section):

```sh
brew install stress-ng   # memory bandwidth (STREAM benchmark)
brew install fio         # storage I/O — sequential MB/s + random IOPS
brew install hyperfine   # timing stats with stddev for CPU section
```

For `standardized.sh`:

```sh
brew install --cask geekbench geekbench-ai blender-benchmark
bash macOS/install-cinebench.sh   # Cinebench: direct .dmg (brew cask checksum goes stale vs Maxon's rolling build)
```

For `llm-bench.sh`:

```sh
brew install mlx-lm      # provides mlx_lm.generate (MLX runtime)
brew install llama.cpp   # provides llama-bench (GGUF runtime)
```

For `omlx-bench.sh` — install the oMLX **menu-bar app** (native front end +
server), not the brew formula:

```sh
bash macOS/install-omlx-app.sh   # downloads the latest .dmg from Releases
```

The app provides the menu-bar UI, the web chat at `http://localhost:8000/admin/chat`,
the inference server, and a CLI shim at `~/.omlx/bin/omlx`. `setup.sh --optional`
installs it automatically (it's the `omlx` entry in `packages.json`).

> Don't also `brew install omlx` — the app bundles its own server and the two
> collide on port 8000 and `~/.omlx/`.

All of the above are also in `packages.json` (priority `low`, macOS only), so
`./setup.sh --optional` on macOS installs them.

## Running a benchmark

```sh
bash macOS/benchmarks/benchmark.sh          # full run (~5–10 min with all deps)
bash macOS/benchmarks/benchmark.sh --quick  # fast sanity check (~1 min)
```

Results land in `macOS/benchmarks/results/benchmark_<hostname>_<datetime>.json`.

## Comparing two machines

1. Run `benchmark.sh` on machine A. Copy the result JSON somewhere.
2. Run `benchmark.sh` on machine B. Copy its result JSON to the same location.
3. Run:

```sh
bash macOS/benchmarks/compare.sh \
  macOS/benchmarks/results/benchmark_<hostname-a>*.json \
  macOS/benchmarks/results/benchmark_<hostname-b>*.json
```

Output is a table with absolute delta and % difference, with a winner column
for each metric. `compare.sh` works the same way for `standardized_*`,
`llm_*`, `omlx_*`, and `stress_*` result files — it picks the right metric
table from the suite tag.

## Standardized benchmarks

Wraps the industry-standard benchmark CLIs and records their scores. Each
benchmark is best-effort — a missing app or unparseable output is recorded as
`null` rather than aborting the run. Raw CLI output is saved alongside the JSON
for audit.

```sh
bash macOS/benchmarks/standardized.sh            # all installed benchmarks
bash macOS/benchmarks/standardized.sh --cpu-only # skip GPU/compute sub-tests
```

- **Geekbench 6** — free tier uploads to the public Geekbench Browser and the
  script records the result URL; a Pro license enables offline JSON export and
  the script records the numeric single/multi scores directly.
- **Geekbench AI** — runs the `banff` CLI (`--ai`), an ML-inference benchmark
  (single-precision / half-precision / quantized scores across Core ML / Metal
  / Neural Engine). The free CLI uploads to the Geekbench AI Browser; the script
  records the result URL.
- **Cinebench / Blender** — CLI flags and score formats vary by version. The
  script captures what it can and always keeps the raw output; verify against
  `results/standardized_*_raw/` if a score looks off.

Results land in `results/standardized_<hostname>_<datetime>.json`.

## Local LLM benchmark (MLX vs llama.cpp)

Runs the **same model** through Apple MLX and llama.cpp and records
prompt-processing (prefill) and generation (decode) tokens/sec, so you can
compare the two runtimes on one machine and one runtime across machines.

```sh
bash macOS/benchmarks/llm-bench.sh               # both runtimes
bash macOS/benchmarks/llm-bench.sh --quick       # 1 rep, 64 gen tokens
bash macOS/benchmarks/llm-bench.sh --mlx-only    # skip llama.cpp
bash macOS/benchmarks/llm-bench.sh --llama-only  # skip MLX
```

Default models (override via environment):

| Variable | Default | Meaning |
|---|---|---|
| `MLX_MODEL` | `mlx-community/gemma-4-12B-it-8bit` | HF repo for MLX |
| `GGUF_REPO` | `ggml-org/gemma-4-12b-it-GGUF` | HF repo for llama.cpp |
| `GGUF_QUANT` | `Q8_0` | GGUF quant tag |
| `N_PROMPT` / `N_GEN` / `REPS` | `512` / `128` / `3` | workload sizing |

```sh
# Example: compare a different model / quant
MLX_MODEL=mlx-community/Llama-3.1-8B-Instruct-4bit \
GGUF_REPO=bartowski/Meta-Llama-3.1-8B-Instruct-GGUF GGUF_QUANT=Q4_K_M \
  bash macOS/benchmarks/llm-bench.sh
```

> **First run downloads weights** (~13GB per runtime for the 12B-8bit default).
> MLX uses the Hugging Face cache; the GGUF is resolved via the HF API and
> cached under `~/.cache/llama.cpp` (override with `GGUF_CACHE`). MLX 8-bit and
> GGUF Q8_0 are different quantization schemes — close in size/quality but not
> bit-identical; the tokens/sec rates remain comparable. If no GGUF is found,
> the repo/quant likely doesn't exist — override `GGUF_REPO`/`GGUF_QUANT`.

Results land in `results/llm_<hostname>_<datetime>.json`.

## oMLX concurrency benchmark

[oMLX](https://github.com/jundot/omlx) is a local MLX inference server whose
differentiator is **continuous batching** — serving many concurrent requests
in one batch. Single-stream `llm-bench.sh` can't show this; `omlx-bench.sh`
starts the server, sweeps concurrency levels, and reports aggregate tokens/sec
at each level so you can see throughput scale (and where it saturates).

```sh
bash macOS/benchmarks/omlx-bench.sh          # sweep concurrency 1,4,8,16
bash macOS/benchmarks/omlx-bench.sh --quick  # sweep 1,4 with 64 gen tokens
```

If the menu-bar app is already serving on port 8000, the script **reuses that
server** (it won't start a second one). Otherwise it starts its own via the
`omlx` CLI / shim, waits for the model to load, sweeps, and stops it. When you
start your own, models must be laid out under `OMLX_MODEL_DIR` in oMLX's
two-level structure, e.g. `~/models/mlx-community/gemma-4-12B-it-8bit/`. When
reusing the app's server, just load a model in the app first — the app's own
`--max-concurrent-requests` then caps how far batching scales.

| Variable | Default | Meaning |
|---|---|---|
| `OMLX_MODEL_DIR` | `~/models` | directory of MLX models to serve |
| `OMLX_MODEL` | auto from `/v1/models` | model id to request |
| `OMLX_PORT` | `8000` | server port |
| `CONCURRENCY` | `1 4 8 16` | concurrency levels to sweep |
| `N_GEN` | `128` | tokens generated per request |
| `READY_TIMEOUT` | `180` | seconds to wait for model load |

Key output fields: `single_stream_tps`, `peak_aggregate_tps`,
`peak_concurrency`, `batching_speedup` (peak ÷ single-stream), plus the full
`sweep` array. Results land in `results/omlx_<hostname>_<datetime>.json`.

> The peak-aggregate figure is the meaningful one for comparing Macs as
> inference hosts — it reflects memory bandwidth and the batch scheduler under
> real concurrent load, not just single-request decode speed.

**vs. oMLX's built-in benchmark.** The oMLX admin dashboard
(`http://localhost:8000/admin`) has a one-click benchmark with *performance*
and *intelligence* sections. *Performance* measures prefill/generation
tokens/sec with prefix-cache-hit testing — the same throughput `omlx-bench.sh`
captures via the API, plus our concurrency sweep on top. *Intelligence* is a
model-quality eval. Both are dashboard-only (no documented API/CLI), so they
stay a manual step; `omlx-bench.sh` is the scriptable, two-machine-comparable
counterpart for the performance side.

## Stress test (throttle detection)

Runs all CPU cores at full load for 5 minutes (default), samples sha256
throughput every 30 seconds, and flags any sample where performance drops
below 90% of baseline. The baseline is measured **under load** after a short
settle period (an idle baseline would read single-core boost clocks and flag
normal scheduler contention as throttling), so the ratio isolates thermal
decline over the run.

```sh
bash macOS/benchmarks/stress-test.sh          # 5 min
bash macOS/benchmarks/stress-test.sh 600      # 10 min

sudo bash macOS/benchmarks/stress-test.sh     # adds CPU frequency + power data
```

Results land in `results/stress_<hostname>_<datetime>.json`.

The `throttle_detection.throttled` field in the JSON is the quick answer:
`true` means the machine sustained a ≥10% throughput drop under load.

## Metric reference

| Metric | Unit | Higher is better |
|---|---|---|
| `cpu_single.sha256_16k_kbs` | KB/s | yes |
| `cpu_single.sha256_mean_ms` | ms | no (lower = faster) |
| `cpu_multi.sha256_16k_kbs` | KB/s | yes |
| `cpu_multi.scaling_factor` | ratio | yes (ideal = num cores) |
| `memory_bw.stream_mbs` | MB/s | yes |
| `storage.seq_write_mbs` | MB/s | yes |
| `storage.seq_read_mbs` | MB/s | yes — may reflect SLC cache |
| `storage.rand_write_iops` | IOPS | yes |
| `storage.rand_read_iops` | IOPS | yes |

## Notes

**CPU frequency on Apple Silicon** — `sysctl hw.cpufrequency` is not
populated on Apple Silicon. The stress test uses a sha256 throughput ratio as
a proxy for frequency degradation. Run with `sudo` for `powermetrics`-derived
frequency and package power data.

**APFS sequential read** — a read immediately after a write often reflects
the SLC write cache rather than sustained NAND read speed. For a cold read
baseline, reboot the machine and run `fio` read-only before any writes.

**Apple Silicon core naming** — `hw.perflevel0` = P-cores ("Super" cluster on
M5), `hw.perflevel1` = E-cores ("Performance" cluster). The naming is
Apple-internal and reversed from what you might expect.

**M5 Max vs M4 Max expected differences** — M5 Max has more E-cores (12 vs 10)
and higher memory bandwidth. Single-core IPC improvement is moderate (~10–15%).
Multi-core gains are larger due to E-core count. The stress test is more
revealing for refurb/open-box validation — a healthy machine should show
< 5% throughput variance across the entire run.
