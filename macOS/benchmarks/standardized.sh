#!/usr/bin/env bash
# Standardized benchmark wrapper — runs Geekbench 6, Cinebench, and Blender
# Benchmark CLIs (whichever are installed) and records their scores.
#
# Each benchmark is best-effort: a missing app or an unparseable result is
# recorded as null with a note, never aborts the run. CLI output formats vary
# by version, so scores are captured from stdout and also saved raw for audit.
#
# Usage: bash standardized.sh [--cpu-only]
#   --cpu-only  skip GPU/compute sub-tests where the CLI allows it
#
# Geekbench note: the free tier uploads results to the public Geekbench Browser
# and returns a URL; a Pro license enables offline --export-json. Both handled.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

CPU_ONLY=false
[[ "${1:-}" == "--cpu-only" ]] && CPU_ONLY=true

check_dep_required jq
ensure_results_dir

SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
OUTFILE="$RESULTS_DIR/standardized_${HOSTNAME_SHORT}_$(ts_file).json"
RAWDIR="$RESULTS_DIR/standardized_${HOSTNAME_SHORT}_$(ts_file)_raw"

printf '\n'
ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB"
info "Raw CLI output saved to: $RAWDIR"
mkdir -p "$RAWDIR"

START_S=$SECONDS

# ---------------------------------------------------------------------------
# Geekbench 6
# ---------------------------------------------------------------------------
GEEKBENCH_JSON="null"
GB_BIN=$(find "/Applications/Geekbench 6.app/Contents/Resources" -maxdepth 1 -name 'geekbench6' -type f 2>/dev/null | head -1 || true)

if [[ -n "$GB_BIN" ]]; then
  header "Geekbench 6"
  GB_JSON_OUT="$RAWDIR/geekbench6.json"
  GB_RAW="$RAWDIR/geekbench6.txt"

  # Try Pro offline JSON export first; fall back to default (upload + URL)
  if "$GB_BIN" --cpu --export-json "$GB_JSON_OUT" >"$GB_RAW" 2>&1 && [[ -s "$GB_JSON_OUT" ]]; then
    GB_SINGLE=$(jq '.sections // [] | map(select(.name=="Single-Core")) | .[0].score // null' "$GB_JSON_OUT" 2>/dev/null || printf 'null')
    GB_MULTI=$(jq  '.sections // [] | map(select(.name=="Multi-Core"))  | .[0].score // null' "$GB_JSON_OUT" 2>/dev/null || printf 'null')
    GEEKBENCH_JSON=$(jq -n --argjson s "${GB_SINGLE:-null}" --argjson m "${GB_MULTI:-null}" \
      '{ single_core: $s, multi_core: $m, mode: "pro-json" }')
    ok "Geekbench CPU: single=${GB_SINGLE} multi=${GB_MULTI}"
  else
    # Free tier: parse the result URL from stdout
    "$GB_BIN" --cpu >"$GB_RAW" 2>&1 || true
    GB_URL=$(grep -oE 'https://browser\.geekbench\.com/[^ ]+' "$GB_RAW" | head -1 || true)
    if [[ -n "$GB_URL" ]]; then
      GEEKBENCH_JSON=$(jq -n --arg url "$GB_URL" '{ result_url: $url, mode: "free-upload", note: "scores in the Geekbench Browser" }')
      ok "Geekbench result: $GB_URL"
    else
      warn "Geekbench produced no parseable result — see $GB_RAW"
      GEEKBENCH_JSON=$(jq -n '{ error: "no score/url parsed" }')
    fi
  fi
else
  info "Geekbench 6 not installed (brew install --cask geekbench) — skipping"
fi

# ---------------------------------------------------------------------------
# Geekbench AI (banff CLI)
# ---------------------------------------------------------------------------
GEEKBENCH_AI_JSON="null"
GBAI_BIN=""
for cand in banff_aarch64 banff; do
  p="/Applications/Geekbench AI.app/Contents/Resources/$cand"
  [[ -x "$p" ]] && { GBAI_BIN="$p"; break; }
done

if [[ -n "$GBAI_BIN" ]]; then
  header "Geekbench AI"
  GBAI_RAW="$RAWDIR/geekbench_ai.txt"
  # Free CLI runs the inference benchmark and uploads; scores land in the
  # Geekbench AI Browser and the result URL is printed to stdout.
  "$GBAI_BIN" --ai >"$GBAI_RAW" 2>&1 || true
  GBAI_URL=$(grep -oE 'https://browser\.geekbench\.com/ai/[^ ]+' "$GBAI_RAW" | head -1 || true)
  if [[ -n "$GBAI_URL" ]]; then
    GEEKBENCH_AI_JSON=$(jq -n --arg url "$GBAI_URL" '{ result_url: $url, mode: "free-upload", note: "single/half/quantized scores in the Geekbench AI Browser" }')
    ok "Geekbench AI result: $GBAI_URL"
  else
    warn "Geekbench AI produced no parseable result — see $GBAI_RAW"
    GEEKBENCH_AI_JSON=$(jq -n '{ error: "no score/url parsed" }')
  fi
else
  info "Geekbench AI not installed (brew install --cask geekbench-ai) — skipping"
fi

# ---------------------------------------------------------------------------
# Cinebench
# ---------------------------------------------------------------------------
CINEBENCH_JSON="null"
CB_BIN=$(find /Applications -maxdepth 3 -name 'Cinebench' -type f -path '*Contents/MacOS*' 2>/dev/null | head -1 || true)

if [[ -n "$CB_BIN" ]]; then
  header "Cinebench"
  CB_RAW="$RAWDIR/cinebench.txt"
  # CLI runs the multi-threaded CPU test and prints "CB <score>"
  "$CB_BIN" g_CinebenchCpuXTest=true >"$CB_RAW" 2>&1 || true
  CB_MULTI=$(grep -oE 'CB[[:space:]]+[0-9]+' "$CB_RAW" | grep -oE '[0-9]+' | tail -1 || true)
  [[ -z "$CB_MULTI" ]] && CB_MULTI="null"

  CB_SINGLE="null"
  if ! $CPU_ONLY; then
    "$CB_BIN" g_CinebenchCpu1Test=true >>"$CB_RAW" 2>&1 || true
    CB_SINGLE=$(grep -oE 'CB[[:space:]]+[0-9]+' "$CB_RAW" | grep -oE '[0-9]+' | tail -1 || true)
    [[ -z "$CB_SINGLE" ]] && CB_SINGLE="null"
  fi

  CINEBENCH_JSON=$(jq -n --argjson s "$CB_SINGLE" --argjson m "$CB_MULTI" \
    '{ cpu_single: $s, cpu_multi: $m, note: "CLI score format varies by Cinebench version — verify against raw output" }')
  ok "Cinebench CPU: single=${CB_SINGLE} multi=${CB_MULTI}"
else
  info "Cinebench not installed (brew install --cask cinebench) — skipping"
fi

# ---------------------------------------------------------------------------
# Blender Benchmark
# ---------------------------------------------------------------------------
BLENDER_JSON="null"
BB_BIN=$(find "/Applications/Blender Benchmark.app" -name 'benchmark-launcher-cli' -type f 2>/dev/null | head -1 || true)

if [[ -n "$BB_BIN" && ! $CPU_ONLY ]]; then
  header "Blender Benchmark (Metal GPU)"
  BB_RAW="$RAWDIR/blender.json"
  # Resolve latest available Blender version, then run the standard scenes on Metal
  BB_VER=$("$BB_BIN" blender list 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || true)
  if [[ -n "$BB_VER" ]]; then
    info "Blender $BB_VER — downloading runtime + scenes (first run only)..."
    "$BB_BIN" benchmark monster junkshop classroom \
      --blender-version "$BB_VER" \
      --device-type METAL \
      --json >"$BB_RAW" 2>/dev/null || true
    if [[ -s "$BB_RAW" ]]; then
      # samples_per_minute per scene; sum for an overall figure
      BB_TOTAL=$(jq '[.[].stats.samples_per_minute // empty] | if length>0 then add else null end' "$BB_RAW" 2>/dev/null || printf 'null')
      BLENDER_JSON=$(jq -n --argjson t "${BB_TOTAL:-null}" --slurpfile raw "$BB_RAW" \
        '{ total_samples_per_minute: $t, scenes: ($raw[0] | map({scene: .scene.label, samples_per_minute: .stats.samples_per_minute})) }' 2>/dev/null \
        || jq -n --argjson t "${BB_TOTAL:-null}" '{ total_samples_per_minute: $t }')
      ok "Blender total: ${BB_TOTAL} samples/min"
    else
      warn "Blender Benchmark produced no output — see $BB_RAW"
    fi
  else
    warn "Could not resolve a Blender version from the launcher"
  fi
elif [[ -z "$BB_BIN" ]]; then
  info "Blender Benchmark not installed (brew install --cask blender-benchmark) — skipping"
fi

# ---------------------------------------------------------------------------
# Write results
# ---------------------------------------------------------------------------
header "Writing results"
DURATION_S=$(( SECONDS - START_S ))

jq -n \
  --argjson sysinfo     "$SYSINFO" \
  --argjson geekbench   "$GEEKBENCH_JSON" \
  --argjson geekbenchai "$GEEKBENCH_AI_JSON" \
  --argjson cinebench   "$CINEBENCH_JSON" \
  --argjson blender     "$BLENDER_JSON" \
  --arg     ts          "$(ts_iso)" \
  --argjson dur         "$DURATION_S" \
  '{
    metadata: { suite: "standardized", timestamp: $ts, duration_s: $dur, suite_version: "1.0.0" },
    sysinfo: $sysinfo,
    geekbench6: $geekbench,
    geekbench_ai: $geekbenchai,
    cinebench: $cinebench,
    blender_benchmark: $blender
  }' > "$OUTFILE"

ok "Done in ${DURATION_S}s"
ok "Results: $OUTFILE"
printf '\n'
