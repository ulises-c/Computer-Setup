#!/usr/bin/env bash
# Sustained CPU stress test with thermal/throttle detection.
# Exercises all cores for DURATION seconds and samples throughput every INTERVAL
# seconds to detect if performance degrades under heat (throttling).
#
# Usage: bash stress-test.sh [DURATION_SECONDS]
#   Default duration: 300s (5 minutes)
#   Run with sudo for CPU frequency + power data via powermetrics.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

DURATION=${1:-300}
INTERVAL=30
THROTTLE_THRESHOLD="0.90"

check_dep_required jq
check_dep_required stress-ng
OPENSSL_BIN=$(resolve_openssl)

ensure_results_dir

SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
OUTFILE="$RESULTS_DIR/stress_${HOSTNAME_SHORT}_$(ts_file).json"
NCPU=$(sysctl -n hw.logicalcpu)

STRESS_PID=""
SAMPLES_JSON="[]"

cleanup() {
  if [[ -n "$STRESS_PID" ]]; then
    kill "$STRESS_PID" 2>/dev/null || true
    wait "$STRESS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# A non-exiting INT/TERM handler would kill the load but let the sample loop
# keep running on an idle machine and write a bogus throttled:false result;
# exiting here routes cleanup through the EXIT trap exactly once
trap 'exit 130' INT TERM

HAS_SUDO_N=false
if sudo -n true 2>/dev/null; then
  HAS_SUDO_N=true
  info "sudo available — will collect CPU frequency and power via powermetrics"
else
  warn "No passwordless sudo — using throughput-ratio proxy for throttle detection"
  warn "Run 'sudo bash stress-test.sh' for power/frequency data"
fi

printf '\n'
ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB"
ok "Duration: ${DURATION}s | Sample interval: ${INTERVAL}s | Cores: ${NCPU}"
info "Results will be written to: $OUTFILE"

# ---------------------------------------------------------------------------
# Start stress load
# ---------------------------------------------------------------------------
header "Starting stress load on all ${NCPU} cores"
# --cpu 0 = one stressor per logical CPU; sha512 exercises integer + vector
# units. The extra 30s covers the baseline settle/measure time so the last
# sample still lands under load.
stress-ng --cpu 0 --cpu-method sha512 --timeout "$(( DURATION + 30 ))s" &
STRESS_PID=$!
info "Stress PID: $STRESS_PID"

# ---------------------------------------------------------------------------
# Baseline measurement (under load)
# ---------------------------------------------------------------------------
# The baseline must be taken while the stressors are running: an idle baseline
# reads a single-core-boost P-core, and the probe then contends with NCPU
# stressors on every sample — scheduler contention alone would read as a
# "throttle". Let clocks settle at the sustained all-core level first;
# throttling then shows up as a decline relative to this early-load figure.
header "Baseline throughput (5s, under load)"
sleep 10
BASELINE_RAW=$("$OPENSSL_BIN" speed -elapsed -seconds 5 sha256 2>&1 || true)
BASELINE_KBS=$(printf '%s\n' "$BASELINE_RAW" \
  | awk '/^sha256/{gsub(/k$/,"",$7); printf "%.0f", $7+0}')
if [[ -z "$BASELINE_KBS" || "$BASELINE_KBS" == 0 ]]; then
  die "could not establish a baseline sha256 throughput (openssl parse failed) — cannot compute throttle ratios"
fi
ok "Loaded baseline sha256: ${BASELINE_KBS} KB/s"

# ---------------------------------------------------------------------------
# Sample loop
# ---------------------------------------------------------------------------
header "Sampling every ${INTERVAL}s for ${DURATION}s"
printf '  %-8s %-20s %-8s %-14s %-14s\n' "Elapsed" "sha256 KB/s" "Ratio" "CPU MHz" "Power W"
printf '  %s\n' "--------------------------------------------------------------"

SAMPLE_COUNT=$(( DURATION / INTERVAL ))
if (( SAMPLE_COUNT < 1 )); then SAMPLE_COUNT=1; fi
for (( i = 1; i <= SAMPLE_COUNT; i++ )); do
  sleep "$INTERVAL"

  ELAPSED=$(( i * INTERVAL ))

  # 1-second throughput measurement (brief window, parallel to stress load)
  CUR_RAW=$("$OPENSSL_BIN" speed -elapsed -seconds 1 sha256 2>&1 || true)
  CUR_KBS=$(printf '%s\n' "$CUR_RAW" \
    | awk '/^sha256/{gsub(/k$/,"",$7); printf "%.0f", $7+0}')
  [[ -z "$CUR_KBS" ]] && CUR_KBS=0

  RATIO=$(jq -n "${CUR_KBS} / ${BASELINE_KBS}")
  THROTTLE_FLAG=""
  if (( $(jq -n "if ${RATIO} < ${THROTTLE_THRESHOLD} then 1 else 0 end") )); then
    THROTTLE_FLAG=" !! THROTTLE"
  fi

  CPU_FREQ_MHZ="null"
  POWER_W="null"
  if $HAS_SUDO_N; then
    PM_OUT=$(sudo powermetrics -n 1 -i 200 \
      --samplers cpu_power --hide-cpu-duty-cycle 2>/dev/null || true)
    # Apple Silicon: "P0-Cluster HW active frequency: 3204 MHz" (or "P-Cluster"
    # on base chips) and "CPU Power: 4382 mW" — there is no Intel-style
    # "Package power:" line
    RAW_FREQ=$(printf '%s\n' "$PM_OUT" \
      | awk '/^P[0-9]*-Cluster HW active frequency:/{print $(NF-1)+0; exit}' \
      || printf '')
    [[ -n "$RAW_FREQ" ]] && CPU_FREQ_MHZ="$RAW_FREQ"
    RAW_WATTS=$(printf '%s\n' "$PM_OUT" \
      | awk '/^CPU Power:/{printf "%.2f", $3/1000; exit}' \
      || printf '')
    [[ -n "$RAW_WATTS" ]] && POWER_W="$RAW_WATTS"
  fi

  FREQ_DISPLAY="${CPU_FREQ_MHZ:-n/a}"
  WATTS_DISPLAY="${POWER_W:-n/a}"
  [[ "$FREQ_DISPLAY" == "null" ]] && FREQ_DISPLAY="n/a"
  [[ "$WATTS_DISPLAY" == "null" ]] && WATTS_DISPLAY="n/a"

  printf '  %-8s %-20s %-8s %-14s %-14s%s\n' \
    "${ELAPSED}s" "${CUR_KBS}" "$(printf '%.3f' "$RATIO")" \
    "$FREQ_DISPLAY" "$WATTS_DISPLAY" "$THROTTLE_FLAG"

  SAMPLE=$(jq -n \
    --arg     ts       "$(ts_iso)" \
    --argjson elapsed  "$ELAPSED" \
    --argjson sha_kbs  "$CUR_KBS" \
    --argjson base_kbs "$BASELINE_KBS" \
    --argjson ratio    "$RATIO" \
    --argjson freq     "$CPU_FREQ_MHZ" \
    --argjson watts    "$POWER_W" \
    '{ts: $ts, elapsed_s: $elapsed, sha256_kbs: $sha_kbs,
      baseline_kbs: $base_kbs, throttle_ratio: $ratio,
      cpu_freq_mhz: $freq, power_watts: $watts}')

  SAMPLES_JSON=$(jq --argjson s "$SAMPLE" '. + [$s]' <<< "$SAMPLES_JSON")
done

# Wait for stress to finish cleanly (it should have already timed out)
wait "$STRESS_PID" 2>/dev/null || true
STRESS_PID=""

# ---------------------------------------------------------------------------
# Throttle analysis
# ---------------------------------------------------------------------------
header "Throttle analysis"

MIN_RATIO=$(jq '[.[].throttle_ratio] | min' <<< "$SAMPLES_JSON")
MAX_RATIO=$(jq '[.[].throttle_ratio] | max' <<< "$SAMPLES_JSON")
AVG_RATIO=$(jq '[.[].throttle_ratio] | add / length' <<< "$SAMPLES_JSON")

THROTTLED="false"
if (( $(jq -n "if ${MIN_RATIO} < ${THROTTLE_THRESHOLD} then 1 else 0 end") )); then
  THROTTLED="true"
  warn "Throttling detected — min ratio: $(printf '%.3f' "$MIN_RATIO") (threshold: $THROTTLE_THRESHOLD)"
else
  ok "No throttling detected — min ratio: $(printf '%.3f' "$MIN_RATIO")"
fi

ok "Ratio range: $(printf '%.3f' "$MIN_RATIO") – $(printf '%.3f' "$MAX_RATIO")  avg: $(printf '%.3f' "$AVG_RATIO")"

# ---------------------------------------------------------------------------
# Write result file
# ---------------------------------------------------------------------------
jq -n \
  --argjson sysinfo    "$SYSINFO" \
  --argjson baseline   "$BASELINE_KBS" \
  --argjson ncpu       "$NCPU" \
  --argjson duration   "$DURATION" \
  --argjson interval   "$INTERVAL" \
  --arg     throttled  "$THROTTLED" \
  --argjson min_ratio  "$MIN_RATIO" \
  --argjson avg_ratio  "$AVG_RATIO" \
  --arg     threshold  "$THROTTLE_THRESHOLD" \
  --argjson samples    "$SAMPLES_JSON" \
  --arg     timestamp  "$(ts_iso)" \
  '{
    metadata: { suite: "stress", timestamp: $timestamp, suite_version: "1.0.0" },
    sysinfo: $sysinfo,
    config: { duration_s: $duration, interval_s: $interval, num_cores: $ncpu },
    baseline_sha256_kbs: $baseline,
    throttle_detection: {
      throttled: ($throttled == "true"),
      min_ratio: $min_ratio,
      avg_ratio: $avg_ratio,
      threshold_ratio: ($threshold | tonumber),
      method: "ratio vs early-load baseline (settled clocks, probe contending with stressors)"
    },
    samples: $samples
  }' > "$OUTFILE"

ok "Results: $OUTFILE"
printf '\n'
