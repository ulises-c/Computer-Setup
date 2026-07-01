#!/usr/bin/env bash
# Compare two result JSON files side-by-side. Auto-detects the suite type
# (benchmark | standardized | llm | omlx | stress) from .metadata.suite and
# renders the appropriate metric table with absolute delta, % difference, and
# a winner.
#
# Usage: bash compare.sh <result_a.json> <result_b.json>
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

[[ $# -eq 2 ]] || die "Usage: bash compare.sh <result_a.json> <result_b.json>"
FILE_A="$1"; FILE_B="$2"
[[ -f "$FILE_A" ]] || die "File not found: $FILE_A"
[[ -f "$FILE_B" ]] || die "File not found: $FILE_B"
check_dep_required jq

SUITE_A=$(jq -r '.metadata.suite // "benchmark"' "$FILE_A")
SUITE_B=$(jq -r '.metadata.suite // "benchmark"' "$FILE_B")
[[ "$SUITE_A" == "$SUITE_B" ]] || die "suite mismatch: A is '$SUITE_A', B is '$SUITE_B' — compare like with like"

# ---------------------------------------------------------------------------
# Per-suite row definitions. Each prints a jq array of
#   {label, a, b, delta, pct, winner, unit}
# ---------------------------------------------------------------------------
rows_for_suite() {
  local suite="$1"
  local common='
    def safenum(v): if v == null or v == "null" then 0 else (v | tonumber) end;
    def pct(av; bv): if av == 0 then null else ((bv - av) / av * 100) end;
    def win(d; hib): if d == 0 then "tie"
      elif hib and d > 0 then "B" elif (hib|not) and d < 0 then "B" else "A" end;
    def row(lbl; av; bv; hib; unit):
      (bv - av) as $d
      | {label: lbl, a: av, b: bv, delta: $d,
         pct: (pct(av; bv) // "null"),
         winner: win($d; hib), unit: unit};
  '
  case "$suite" in
    benchmark)
      jq -n --slurpfile a "$FILE_A" --slurpfile b "$FILE_B" "$common"'
      [ row("cpu single sha256 (KB/s)"; safenum($a[0].cpu_single.sha256_16k_kbs); safenum($b[0].cpu_single.sha256_16k_kbs); true; "KB/s"),
        row("cpu single mean (ms)";     safenum($a[0].cpu_single.sha256_mean_ms);  safenum($b[0].cpu_single.sha256_mean_ms);  false; "ms"),
        row("cpu multi sha256 (KB/s)";  safenum($a[0].cpu_multi.sha256_16k_kbs);   safenum($b[0].cpu_multi.sha256_16k_kbs);   true; "KB/s"),
        row("memory STREAM (MB/s)";     safenum($a[0].memory_bw.stream_mbs);       safenum($b[0].memory_bw.stream_mbs);       true; "MB/s"),
        row("storage seq write (MB/s)"; safenum($a[0].storage.seq_write_mbs);      safenum($b[0].storage.seq_write_mbs);      true; "MB/s"),
        row("storage seq read (MB/s)";  safenum($a[0].storage.seq_read_mbs);       safenum($b[0].storage.seq_read_mbs);       true; "MB/s"),
        row("storage rand write (IOPS)";safenum($a[0].storage.rand_write_iops);    safenum($b[0].storage.rand_write_iops);    true; "IOPS"),
        row("storage rand read (IOPS)"; safenum($a[0].storage.rand_read_iops);     safenum($b[0].storage.rand_read_iops);     true; "IOPS") ]'
      ;;
    llm)
      jq -n --slurpfile a "$FILE_A" --slurpfile b "$FILE_B" "$common"'
      [ row("MLX prompt (tok/s)";       safenum($a[0].mlx.pp_tps_avg);       safenum($b[0].mlx.pp_tps_avg);       true; "tok/s"),
        row("MLX generation (tok/s)";   safenum($a[0].mlx.tg_tps_avg);       safenum($b[0].mlx.tg_tps_avg);       true; "tok/s"),
        row("llama.cpp prompt (tok/s)"; safenum($a[0].llama_cpp.pp_tps_avg); safenum($b[0].llama_cpp.pp_tps_avg); true; "tok/s"),
        row("llama.cpp gen (tok/s)";    safenum($a[0].llama_cpp.tg_tps_avg); safenum($b[0].llama_cpp.tg_tps_avg); true; "tok/s") ]'
      ;;
    standardized)
      jq -n --slurpfile a "$FILE_A" --slurpfile b "$FILE_B" "$common"'
      [ row("Geekbench single";   safenum($a[0].geekbench6.single_core);            safenum($b[0].geekbench6.single_core);            true; ""),
        row("Geekbench multi";    safenum($a[0].geekbench6.multi_core);             safenum($b[0].geekbench6.multi_core);             true; ""),
        row("Cinebench single";   safenum($a[0].cinebench.cpu_single);              safenum($b[0].cinebench.cpu_single);              true; ""),
        row("Cinebench multi";    safenum($a[0].cinebench.cpu_multi);               safenum($b[0].cinebench.cpu_multi);               true; ""),
        row("Blender (samp/min)"; safenum($a[0].blender_benchmark.total_samples_per_minute); safenum($b[0].blender_benchmark.total_samples_per_minute); true; "s/min") ]'
      ;;
    omlx)
      jq -n --slurpfile a "$FILE_A" --slurpfile b "$FILE_B" "$common"'
      [ row("single-stream (tok/s)"; safenum($a[0].single_stream_tps);  safenum($b[0].single_stream_tps);  true; "tok/s"),
        row("peak aggregate (tok/s)";safenum($a[0].peak_aggregate_tps); safenum($b[0].peak_aggregate_tps); true; "tok/s"),
        row("batching speedup (x)";  safenum($a[0].batching_speedup);   safenum($b[0].batching_speedup);   true; "x") ]'
      ;;
    stress)
      jq -n --slurpfile a "$FILE_A" --slurpfile b "$FILE_B" "$common"'
      [ row("loaded baseline (KB/s)"; safenum($a[0].baseline_sha256_kbs);           safenum($b[0].baseline_sha256_kbs);           true; "KB/s"),
        row("min throttle ratio";     safenum($a[0].throttle_detection.min_ratio);  safenum($b[0].throttle_detection.min_ratio);  true; ""),
        row("avg throttle ratio";     safenum($a[0].throttle_detection.avg_ratio);  safenum($b[0].throttle_detection.avg_ratio);  true; "") ]'
      ;;
    *)
      die "unknown suite: $suite"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
label_a=$(jq -r '"[A] " + .sysinfo.chip + " — " + .sysinfo.hostname' "$FILE_A")
label_b=$(jq -r '"[B] " + .sysinfo.chip + " — " + .sysinfo.hostname' "$FILE_B")

printf '\n\033[1m%s comparison\033[0m\n' "$SUITE_A"
printf '  A: %s  (%s)\n' "$label_a" "$(jq -r '.metadata.timestamp' "$FILE_A")"
printf '  B: %s  (%s)\n' "$label_b" "$(jq -r '.metadata.timestamp' "$FILE_B")"
printf '\n'

ROWS=$(rows_for_suite "$SUITE_A")

# ---------------------------------------------------------------------------
# Render table
# ---------------------------------------------------------------------------
COL_W=32; VAL_W=16
printf '\033[1m%-*s %*s %*s %10s %9s  %s\033[0m\n' \
  "$COL_W" "Metric" "$VAL_W" "A" "$VAL_W" "B" "Delta" "%" "Win"
printf '%s\n' "$(printf '─%.0s' $(seq 1 96))"

fmt_val() {
  local v="$1" abs
  abs=$(printf '%.0f' "${v#-}")
  if (( abs >= 10000 )); then
    printf '%s' "$v" | awk '{printf "%\047.0f", $1}' 2>/dev/null || printf '%.0f' "$v"
  elif (( abs >= 100 )); then
    printf '%.0f' "$v"
  else
    printf '%.1f' "$v"
  fi
}

printf '%s\n' "$ROWS" | jq -r '.[] | [.label, .a, .b, .delta, .pct, .winner, .unit] | @tsv' \
| while IFS=$'\t' read -r label av bv delta pct winner unit; do
  [[ "$av" == "0" && "$bv" == "0" ]] && continue

  AV_FMT=$(fmt_val "$av"); BV_FMT=$(fmt_val "$bv"); DELTA_FMT=$(fmt_val "$delta")
  [[ "$delta" =~ ^[^-] ]] && DELTA_FMT="+${DELTA_FMT}"
  PCT_FMT="n/a"; [[ "$pct" != "null" ]] && PCT_FMT=$(printf '%+.1f%%' "$pct")

  case "$winner" in
    A)   WIN_MARK="\033[33mA\033[0m" ;;
    B)   WIN_MARK="\033[32mB\033[0m" ;;
    *)   WIN_MARK="tie" ;;
  esac
  # A metric measured on only one machine is missing data, not a win
  [[ "$av" == "0" || "$bv" == "0" ]] && WIN_MARK="n/a"

  U=""; [[ -n "$unit" ]] && U=" $unit"
  printf "%-${COL_W}s %${VAL_W}s %${VAL_W}s %10s %9s  %b\n" \
    "$label" "${AV_FMT}${U}" "${BV_FMT}${U}" "$DELTA_FMT" "$PCT_FMT" "$WIN_MARK"
done

printf '\n'
# Rows where either side is 0 (metric missing on one machine) are incomparable
# and stay out of the tally
WINS_A=$(jq '[.[] | select(.winner=="A" and .a!=0 and .b!=0)] | length' <<< "$ROWS")
WINS_B=$(jq '[.[] | select(.winner=="B" and .a!=0 and .b!=0)] | length' <<< "$ROWS")
TIES=$(jq   '[.[] | select(.winner=="tie" and .a!=0 and .b!=0)] | length' <<< "$ROWS")
printf 'A wins: %s   B wins: %s   Ties: %s\n\n' "$WINS_A" "$WINS_B" "$TIES"
