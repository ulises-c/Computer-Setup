# macOS benchmark suite — review findings (2026-07)

Findings from the max-effort review of the `feat/packages-macos-benchmarks` branch
(10 finder angles, per-finding verification, gap sweep), shipped in
[#53](https://github.com/ulises-c/Computer-Setup/pull/53). **All resolved** — this
is the engineering record of what was wrong and why, preserved out of `TODO.md`.

Most failures were silent (`|| true` / `2>/dev/null` degrade to `null` fields), so
the fix protocol was: after the P0/P1 fixes, re-run every suite end-to-end on one
Mac and confirm the result JSON has no unexpected nulls before trusting numbers.

## P0 — measurement paths broken, data corruption, or setup aborts

- `benchmark.sh:56` (also `stress-test.sh:59,91`) — `openssl speed -seconds` is not
  supported by stock macOS LibreSSL, and the unguarded `$( )` under `set -e` killed
  the script silently right after the section header. Resolve a `-seconds`-capable
  openssl at startup (brew `openssl@3` is keg-only — probe
  `$(brew --prefix openssl@3)/bin/openssl`) or die with a clear install hint.
- `llm-bench.sh:137` — `llama-bench` does not accept `--hf-repo` (that flag belongs
  to llama-cli/llama-server), so the whole llama.cpp half failed arg parsing with
  stderr discarded. Pre-download the GGUF and pass `-m <path>`; stop discarding
  `llama-bench` stderr.
- `benchmark.sh:250-253` — GPU `llama-bench` parse always null: the `grep -v "^\["`
  filter stripped the JSON array's opening bracket, and `jq -s '.[0].avg_ts'`
  double-wrapped the array (and `[0]` would be the pp row, not tg). Parse like
  `llm-bench.sh` (`jq '[.[] | select(...)]'`) or drop the GPU section.
- `standardized.sh:105` — Cinebench detection used `-maxdepth 3` but the binary sits
  at depth 4 (`.../Cinebench.app/Contents/MacOS/Cinebench`); never detected even
  after our own installer runs. Use `-maxdepth 4`.
- `platforms/macos.sh:72` — one failing custom installer (e.g. a 404'd Cinebench DMG
  URL) aborted the entire remaining setup run under `set -e`. Collect failures and
  continue, like `BREW_FAILURES` (the #31 pattern).
- `compare.sh:117` — a metric missing on machine A crashed the comparison mid-table:
  `pct()` yields null when `av == 0`, `@tsv` renders null as an empty field,
  `IFS=$'\t' read` collapses adjacent tabs (shifting `winner` into `pct`), and
  `printf '%+.1f%%'` then fails under `set -e`. Emit the literal string `"null"`.
- `stress-test.sh:91` — throttle methodology was self-defeating: baseline was one
  openssl thread on an idle machine (single-core boost, P-core) but each sample
  contends with NCPU stressors, so a healthy Mac read ~0.5–0.7 and flagged THROTTLE.
  Reworked (baseline as first sample under load / sample-trend instead of idle-ratio).
- `stress-test.sh:105-114` — powermetrics parse patterns were Intel-era and never
  matched Apple Silicon: frequency is `... HW active frequency: N MHz` (lowercase f)
  and power is `CPU Power: N mW` (not `Package power:`); also convert mW → W.
- `benchmark.sh:124` — memory-bandwidth `awk /stream/` matched stress-ng's
  `dispatching hogs: 1 stream` info line before the metrics row, printing 0. Anchor
  on the metrics row (`/metrc.*stream/`).
- `omlx-bench.sh:159` — `fire_one` converted failed requests (curl error, 429/5xx)
  into `{}`: token totals silently shrank while wall time still included the failure,
  corrupting `aggregate_tps` / `peak_aggregate_tps` / `batching_speedup`. Count
  failures per level, surface the count in the result JSON, warn/fail on any failure.
- `standardized.sh:142` — Blender's `benchmark-launcher-cli` does not auto-download
  the runtime/scenes; run `blender download <ver>` and `scenes download -b <ver>`
  first (or die with instructions), else `blender_benchmark` is null on fresh install.
- `standardized.sh:111-118` — single-core Cinebench parse grepped the combined raw
  file (multi wrote first, single appended, failures `|| true`-swallowed), so a
  failed single run silently recorded the multi-core score as `cpu_single`. Use a
  separate raw file per run.
- `compare.sh:38-75` — no `stress` case: comparing two stress results died
  `unknown suite: stress` while the README advertised it. Add a stress table (or drop
  the claim); also fix the header comment, which omitted the supported `omlx` suite.
- `lib/verify.sh:92` + the new cinebench/omlx `packages.json` entries — the macOS
  custom probe only tried `brew list --formula` / `command -v`, so GUI-only `.app`
  installs could never verify. Add an app-store-style `[[ -d /Applications/<App>.app ]]`
  probe for custom entries.
- `benchmarks/README.md:85` — the compare example embedded two real machine
  short-hostnames in this public repo (privacy rule: placeholders only) and used a
  `results/` path that doesn't resolve from the repo root. Use `<hostname-a>` /
  `<hostname-b>` placeholders and the `macOS/benchmarks/results/` path.

## P1 — moderate correctness

- `standardized.sh:116` — `--cpu-only` must not skip the single-core Cinebench run:
  it is a CPU test; only Blender/GPU belongs behind that flag.
- `llm-bench.sh:99-101` — the PP/TG/MEM parse pipelines had no `|| true`; under
  pipefail a non-matching grep killed the run instead of reaching the `=null`
  fallbacks.
- `stress-test.sh:39` / `omlx-bench.sh:74` — INT/TERM traps didn't `exit`; a plain
  `kill` mid-run stopped the load but the sample loop continued on an idle machine
  and wrote a bogus `throttled:false` result. End the handlers with `exit`.
- `omlx-bench.sh:100` — `OMLX_PORT` built BASE_URL but was never passed to
  `omlx serve`, so overriding the port polled an address the server never bound.
  Pass the port flag (or reject the override).
- `stress-test.sh` + README `sudo` — a first run under sudo created root-owned
  `results/`; later non-sudo suites finished then died at the final `> "$OUTFILE"`.
  Create/chown `results/` as `$SUDO_USER` when running under sudo.
- `compare.sh:113,131` — a metric present on only one machine rendered as 0-vs-real
  and counted as a win, skewing the summary; skip or mark those rows.
- `compare.sh:61` — `standardized.sh` never emits `.geekbench_ai.score` (only
  result_url/mode/note), so the row was dead; parse a score or drop the row.
- `benchmark.sh:107` — `scaling_factor` was passed with `--arg`, landing as a JSON
  string (or literal `"null"`); use `--argjson`/`tonumber` like `$gbs`.

## P2 — minor / latent

- `platforms/macos.sh:68` — macOS never called `custom_reminders_section`, so any
  future custom entry without `handled_by_setup: true` was silently dropped. Wire the
  reminder section into `platform_main` like `linux_main`.
- `scripts/validate-packages.sh` — validate `handled_by_setup` is a real boolean and
  custom entries carry an `install_command` (a string `"true"` or missing command
  previously passed and degraded silently).
- `macOS/lib-dmg-install.sh:30` — handle hdiutil's already-attached reuse (image
  mounted via Finder → `-mountpoint` ignored, empty mount dir, misleading
  `no .app found` death, pre-existing mount left attached).
- `platforms/macos.sh` dry-run fidelity — gate the pipx `[i/N]` progress line on
  DRY_RUN (:86), print a `[dry-run] sudo -v` line in `mac_prime_sudo` (:96), include
  `--adopt` in the cask progress/FAIL lines (:50, :56).
- `platforms/macos.sh:99` — sudo keepalive inherited `set -e` (one failed
  `sudo -n true` silently killed it) and held stdout so a piped run hung up to 60s
  after exit; add `|| true` and redirect stdout.
- `standardized.sh:59` — grep the already-captured `$GB_RAW` for the Geekbench result
  URL before re-running the whole CPU benchmark (the fallback also truncated the
  first run's output).
- `omlx-bench.sh:127` — when `OMLX_MODEL` is set, don't die on an empty `/v1/models`
  list (lazy-loading servers list nothing until the first request).

## P3 — cleanup (dedupe within the new code)

- `macOS/benchmarks/lib.sh` — add a `bench_init <suite>` helper for the
  SYSINFO/HOSTNAME_SHORT/OUTFILE/banner prologue (was copy-pasted ×5) and a single
  `SUITE_VERSION` constant (literal `"1.0.0"` ×5).
- `macOS/benchmarks/lib.sh` — extract the openssl-speed sha256 run+parse into one
  helper (was ×4 across benchmark.sh / stress-test.sh); pairs with the P0 LibreSSL fix.
- `platforms/macos.sh` — factor the `[i/N]` progress-counter plumbing shared by the
  brew/cask/pipx tiers (×3) into `mac_install_list`; pipx failures now also collect
  into the summary instead of aborting the run.
- `macOS/lib-dmg-install.sh` — move the curl/hdiutil dep checks, the already-installed
  guard, and the success message into the lib (kept its own `info`/`die` — sourcing
  `benchmarks/lib.sh` would couple the standalone installers to the suite internals).
- `platforms/macos.sh:285` — drive the codeburn menubar reminder from `packages.json`
  instead of a hardcoded package-name check — new `codeburn-menubar` custom entry
  (priority none, handled_by_setup false) rendered by `custom_reminders_section`.
- `macOS/install-cinebench.sh:12` — make `DMG_URL` env-overridable
  (`CINEBENCH_DMG_URL`); it pinned a versioned filename while the comment claimed a
  rolling stable URL.
