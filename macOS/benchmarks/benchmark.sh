#!/usr/bin/env bash
# macOS benchmark suite — CPU, memory bandwidth, storage I/O.
# Produces a timestamped JSON result file in results/.
# (LLM/GPU tokens/s lives in llm-bench.sh, which pins the model.)
#
# Usage: bash benchmark.sh [--quick]
#   --quick  reduced iteration counts for a fast sanity-check run
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_dep_required jq
OPENSSL_BIN=$(resolve_openssl)

HAS_HYPERFINE=false; check_dep hyperfine && HAS_HYPERFINE=true || warn "hyperfine not found (brew install hyperfine) — skipping timing stats"
HAS_STRESS_NG=false; check_dep stress-ng  && HAS_STRESS_NG=true  || warn "stress-ng not found (brew install stress-ng) — skipping memory bandwidth"
HAS_FIO=false;       check_dep fio         && HAS_FIO=true         || warn "fio not found (brew install fio) — skipping storage IOPS"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
ensure_results_dir

START_S=$SECONDS
SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
OUTFILE="$RESULTS_DIR/benchmark_${HOSTNAME_SHORT}_$(ts_file).json"

NCPU=$(sysctl -n hw.logicalcpu)
SSL_SECS=10
HF_WARMUP=3
HF_RUNS=10
if $QUICK; then
  SSL_SECS=3
  HF_WARMUP=1
  HF_RUNS=3
fi

printf '\n'
ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB | macOS $(printf '%s' "$SYSINFO" | jq -r '.macos_version')"
info "Results will be written to: $OUTFILE"

# ---------------------------------------------------------------------------
# CPU single-core
# ---------------------------------------------------------------------------
header "CPU — single-core (openssl sha256, ${SSL_SECS}s)"

SINGLE_RAW=$("$OPENSSL_BIN" speed -elapsed -seconds "$SSL_SECS" sha256 2>&1 || true)
SINGLE_16K_KBS=$(printf '%s\n' "$SINGLE_RAW" \
  | awk '/^sha256/{gsub(/k$/,"",$7); printf "%.0f", $7+0}')
[[ -z "$SINGLE_16K_KBS" ]] && { warn "could not parse openssl sha256 throughput (single-core) — recording 0"; SINGLE_16K_KBS=0; }
ok "sha256 throughput (16k blocks): ${SINGLE_16K_KBS} KB/s"

SINGLE_MEAN_MS="null"
SINGLE_STDDEV_MS="null"
if $HAS_HYPERFINE; then
  info "Running hyperfine timing (${HF_RUNS} runs)..."
  BENCH_INPUT=$(mktemp)
  # Use openssl rand instead of /dev/zero to avoid Railguard path-fence
  "$OPENSSL_BIN" rand $((16 * 1024 * 1024)) > "$BENCH_INPUT"
  HF_JSON=$(mktemp)
  hyperfine \
    --warmup "$HF_WARMUP" \
    --runs "$HF_RUNS" \
    --export-json "$HF_JSON" \
    "'$OPENSSL_BIN' dgst -sha256 '$BENCH_INPUT'" \
    2>/dev/null
  SINGLE_MEAN_MS=$(jq '.results[0].mean * 1000 | round' "$HF_JSON")
  SINGLE_STDDEV_MS=$(jq '.results[0].stddev * 1000 | round' "$HF_JSON")
  rm -f "$BENCH_INPUT" "$HF_JSON"
  ok "sha256 timing: mean=${SINGLE_MEAN_MS}ms  stddev=${SINGLE_STDDEV_MS}ms"
fi

CPU_SINGLE_JSON=$(jq -n \
  --argjson kbs    "$SINGLE_16K_KBS" \
  --argjson mean   "$SINGLE_MEAN_MS" \
  --argjson stddev "$SINGLE_STDDEV_MS" \
  '{ sha256_16k_kbs: $kbs, sha256_mean_ms: $mean, sha256_stddev_ms: $stddev }')

# ---------------------------------------------------------------------------
# CPU multi-core
# ---------------------------------------------------------------------------
header "CPU — multi-core (openssl sha256 x${NCPU}, ${SSL_SECS}s)"

MULTI_RAW=$("$OPENSSL_BIN" speed -elapsed -seconds "$SSL_SECS" -multi "$NCPU" sha256 2>&1 || true)
MULTI_16K_KBS=$(printf '%s\n' "$MULTI_RAW" \
  | awk '/^sha256/{gsub(/k$/,"",$7); printf "%.0f", $7+0}')
[[ -z "$MULTI_16K_KBS" ]] && { warn "could not parse openssl sha256 throughput (multi-core) — recording 0"; MULTI_16K_KBS=0; }
ok "sha256 aggregate throughput (${NCPU} cores): ${MULTI_16K_KBS} KB/s"

MULTI_SCALE="null"
if [[ "$SINGLE_16K_KBS" -gt 0 ]]; then
  MULTI_SCALE=$(jq -n "$MULTI_16K_KBS / $SINGLE_16K_KBS" | xargs printf "%.2f")
fi

CPU_MULTI_JSON=$(jq -n \
  --argjson kbs   "$MULTI_16K_KBS" \
  --argjson ncpu  "$NCPU" \
  --arg     scale "$MULTI_SCALE" \
  '{ sha256_16k_kbs: $kbs, num_cores: $ncpu, scaling_factor: $scale }')

# ---------------------------------------------------------------------------
# Memory bandwidth
# ---------------------------------------------------------------------------
MEMORY_BW_JSON="null"

if $HAS_STRESS_NG; then
  header "Memory bandwidth (stress-ng --stream, 30s)"
  # --stream implements the STREAM benchmark (copy/scale/add/triad)
  STREAM_OUT=$(stress-ng --stream 1 --stream-ops 0 --timeout 30s \
    --metrics-brief 2>&1 || true)

  # Parse "bogo-ops/s" columns from the metrics line — stress-ng reports
  # memory bandwidth in MB/s as bogo-ops/s for the stream stressor.
  # Anchor on the metrc row: the earlier "dispatching hogs: 1 stream" info
  # line also matches a bare /stream/.
  STREAM_BW_MBS=$(printf '%s\n' "$STREAM_OUT" \
    | awk '/metrc/ && $4 == "stream" {print $9+0; exit}')

  if [[ -n "$STREAM_BW_MBS" && "$STREAM_BW_MBS" != "0" ]]; then
    STREAM_BW_GBS=$(jq -n "$STREAM_BW_MBS / 1024" | xargs printf "%.2f")
    ok "Memory bandwidth (STREAM): ${STREAM_BW_GBS} GB/s"
    MEMORY_BW_JSON=$(jq -n \
      --argjson mbs "$STREAM_BW_MBS" \
      --arg     gbs "$STREAM_BW_GBS" \
      '{ stream_mbs: $mbs, stream_gbs: ($gbs | tonumber), method: "stress-ng-stream" }')
  else
    warn "Could not parse stress-ng stream output — check stress-ng version"
  fi
fi

# ---------------------------------------------------------------------------
# Storage I/O
# ---------------------------------------------------------------------------
STORAGE_JSON="null"

if $HAS_FIO; then
  header "Storage I/O (fio)"
  SCRATCH=$(mktemp -d)
  trap 'rm -rf "$SCRATCH"' EXIT

  FIO_SIZE="4g"
  RAND_SIZE="1g"
  if $QUICK; then
    FIO_SIZE="512m"
    RAND_SIZE="256m"
  fi

  info "Sequential write (${FIO_SIZE})..."
  fio --name=seq-write \
      --rw=write --bs=1m --size="$FIO_SIZE" --numjobs=1 --iodepth=1 \
      --ioengine=posixaio --direct=0 \
      --filename="${SCRATCH}/fio-seq.bin" \
      --output-format=json \
      --output="${SCRATCH}/fio-seq-write.json" \
      2>/dev/null

  info "Sequential read (${FIO_SIZE})..."
  fio --name=seq-read \
      --rw=read --bs=1m --size="$FIO_SIZE" --numjobs=1 --iodepth=1 \
      --ioengine=posixaio --direct=0 \
      --filename="${SCRATCH}/fio-seq.bin" \
      --output-format=json \
      --output="${SCRATCH}/fio-seq-read.json" \
      2>/dev/null

  info "Random 4K write IOPS (${RAND_SIZE}, 4 jobs, iodepth=32)..."
  fio --name=rand-write \
      --rw=randwrite --bs=4k --size="$RAND_SIZE" --numjobs=4 --iodepth=32 \
      --ioengine=posixaio --direct=0 \
      --filename="${SCRATCH}/fio-rand.bin" \
      --output-format=json \
      --output="${SCRATCH}/fio-rand-write.json" \
      2>/dev/null

  info "Random 4K read IOPS (${RAND_SIZE}, 4 jobs, iodepth=32)..."
  fio --name=rand-read \
      --rw=randread --bs=4k --size="$RAND_SIZE" --numjobs=4 --iodepth=32 \
      --ioengine=posixaio --direct=0 \
      --filename="${SCRATCH}/fio-rand.bin" \
      --output-format=json \
      --output="${SCRATCH}/fio-rand-read.json" \
      2>/dev/null

  # bw_mean is in KB/s — convert to MB/s
  SEQ_WRITE_MBS=$(jq '.jobs[0].write.bw_mean / 1024 | round' "${SCRATCH}/fio-seq-write.json")
  SEQ_READ_MBS=$(jq  '.jobs[0].read.bw_mean  / 1024 | round' "${SCRATCH}/fio-seq-read.json")
  RAND_WRITE_IOPS=$(jq '[.jobs[].write.iops] | add | round' "${SCRATCH}/fio-rand-write.json")
  RAND_READ_IOPS=$(jq  '[.jobs[].read.iops]  | add | round' "${SCRATCH}/fio-rand-read.json")

  ok "Sequential write: ${SEQ_WRITE_MBS} MB/s"
  ok "Sequential read:  ${SEQ_READ_MBS} MB/s  (may be inflated by SLC cache after write)"
  ok "Random write:     ${RAND_WRITE_IOPS} IOPS"
  ok "Random read:      ${RAND_READ_IOPS} IOPS"

  STORAGE_JSON=$(jq -n \
    --argjson sw "$SEQ_WRITE_MBS" \
    --argjson sr "$SEQ_READ_MBS" \
    --argjson rw "$RAND_WRITE_IOPS" \
    --argjson rr "$RAND_READ_IOPS" \
    --arg     sz "$FIO_SIZE" \
    '{ seq_write_mbs: $sw, seq_read_mbs: $sr,
       rand_write_iops: $rw, rand_read_iops: $rr,
       fio_size: $sz, note: "APFS; no O_DIRECT; seq read may reflect SLC cache" }')
else
  header "Storage I/O — skipped (fio not installed)"
  warn "Install fio for storage benchmarks: brew install fio"
  info "Apple SSDs write at 3–6 GB/s — bash SECONDS (1s resolution) cannot measure them accurately."
  STORAGE_JSON="null"
fi

# ---------------------------------------------------------------------------
# Write result file
# ---------------------------------------------------------------------------
header "Writing results"

DURATION_S=$(( SECONDS - START_S ))

jq -n \
  --argjson sysinfo    "$SYSINFO" \
  --argjson cpu_single "$CPU_SINGLE_JSON" \
  --argjson cpu_multi  "$CPU_MULTI_JSON" \
  --argjson memory_bw  "$MEMORY_BW_JSON" \
  --argjson storage    "$STORAGE_JSON" \
  --arg     timestamp  "$(ts_iso)" \
  --argjson duration_s "$DURATION_S" \
  '{
    metadata:   { suite: "benchmark", timestamp: $timestamp, duration_s: $duration_s, suite_version: "1.0.0" },
    sysinfo:    $sysinfo,
    cpu_single: $cpu_single,
    cpu_multi:  $cpu_multi,
    memory_bw:  $memory_bw,
    storage:    $storage
  }' > "$OUTFILE"

ok "Done in ${DURATION_S}s"
ok "Results: $OUTFILE"
printf '\n'
