#!/usr/bin/env bash
# oMLX concurrency benchmark — measures continuous-batching throughput.
#
# Starts a local oMLX inference server, sweeps concurrency levels by firing N
# parallel completion requests at its OpenAI-compatible API, and records
# aggregate tokens/sec at each level. Single-stream MLX/llama.cpp can't show
# this — aggregate throughput should climb with concurrency until the batch
# scheduler saturates, which is oMLX's whole point.
#
# Usage: bash omlx-bench.sh [--quick]
#
# Config (override via environment):
#   OMLX_MODEL_DIR  directory of MLX models to serve   (default: ~/models)
#   OMLX_MODEL      model id to request; auto-discovered from /v1/models if unset
#   OMLX_PORT       server port                          (default: 8000)
#   CONCURRENCY     space-separated levels to sweep      (default: "1 4 8 16")
#   N_GEN           tokens to generate per request       (default: 128)
#   READY_TIMEOUT   seconds to wait for model load       (default: 180)
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

OMLX_MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/models}"
OMLX_MODEL="${OMLX_MODEL:-}"
OMLX_PORT="${OMLX_PORT:-8000}"
CONCURRENCY="${CONCURRENCY:-1 4 8 16}"
N_GEN="${N_GEN:-128}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true
if $QUICK; then
  CONCURRENCY="1 4"
  N_GEN=64
fi

check_dep_required jq
check_dep_required curl
ensure_results_dir

# Resolve the omlx CLI: PATH first, then the menu-bar app's shim. May be empty
# if only the app is installed and already serving — we reuse that server then.
OMLX_BIN=""
if command -v omlx >/dev/null 2>&1; then
  OMLX_BIN="omlx"
elif [[ -x "$HOME/.omlx/bin/omlx" ]]; then
  OMLX_BIN="$HOME/.omlx/bin/omlx"
fi

BASE_URL="http://localhost:${OMLX_PORT}"
# max_concurrent_requests must cover the highest sweep level
MAXCONC=$(printf '%s\n' $CONCURRENCY | sort -n | tail -1)

SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
OUTFILE="$RESULTS_DIR/omlx_${HOSTNAME_SHORT}_$(ts_file).json"

WORKDIR=$(mktemp -d)
SERVER_PID=""
SERVER_LOG="$WORKDIR/server.log"

STARTED_SERVER=false
cleanup() {
  # Only tear down a server we started ourselves; leave the app's server alone.
  if $STARTED_SERVER && [[ -n "$SERVER_PID" ]]; then
    info "Stopping oMLX server (pid $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT
# exit so the sweep can't resume against the deleted WORKDIR after Ctrl-C;
# cleanup runs exactly once via the EXIT trap
trap 'exit 130' INT TERM

# perl gives sub-second wall-clock timing portably (bash 3.2 has no EPOCHREALTIME)
now_s() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.4f\n", time'
  else
    date +%s
  fi
}

printf '\n'
ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB"
ok "Sweep: concurrency [${CONCURRENCY}]  gen=${N_GEN} tok/req  max_concurrent=${MAXCONC}"

# ---------------------------------------------------------------------------
# Reuse a running server (e.g. the menu-bar app) or start our own
# ---------------------------------------------------------------------------
if curl -fsS "${BASE_URL}/v1/models" >/dev/null 2>&1; then
  header "Reusing oMLX server on ${BASE_URL}"
  info "A server is already running (likely the menu-bar app) — not starting another"
  warn "Its own --max-concurrent-requests caps batching; sweep levels above it just queue"
else
  [[ -n "$OMLX_BIN" ]] || die "no oMLX server on ${BASE_URL} and no omlx CLI found — launch the menu-bar app or install omlx"
  [[ -d "$OMLX_MODEL_DIR" ]] || die "model dir not found: $OMLX_MODEL_DIR — place MLX models under <dir>/<org>/<model>/ or set OMLX_MODEL_DIR"
  header "Starting oMLX server"
  "$OMLX_BIN" serve \
    --model-dir "$OMLX_MODEL_DIR" \
    --port "$OMLX_PORT" \
    --max-concurrent-requests "$MAXCONC" \
    >"$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  STARTED_SERVER=true
  info "Server pid: $SERVER_PID  (log: $SERVER_LOG)"
fi

# ---------------------------------------------------------------------------
# Wait for readiness — poll /v1/models until a model is listed
# ---------------------------------------------------------------------------
info "Waiting for model load (timeout ${READY_TIMEOUT}s)..."
DISCOVERED=""
for (( t = 0; t < READY_TIMEOUT; t += 3 )); do
  if $STARTED_SERVER && ! kill -0 "$SERVER_PID" 2>/dev/null; then
    warn "Server exited early — last log lines:"
    tail -20 "$SERVER_LOG" >&2 || true
    die "oMLX server failed to start"
  fi
  MODELS=$(curl -fsS "${BASE_URL}/v1/models" 2>/dev/null || true)
  if [[ -n "$MODELS" ]]; then
    DISCOVERED=$(printf '%s' "$MODELS" | jq -r '.data[0].id // empty' 2>/dev/null || true)
    [[ -n "$DISCOVERED" ]] && break
  fi
  sleep 3
done
if [[ -z "$DISCOVERED" ]]; then
  if $STARTED_SERVER; then
    tail -20 "$SERVER_LOG" >&2 || true
    die "no model available after ${READY_TIMEOUT}s — check $SERVER_LOG and that MLX models live under $OMLX_MODEL_DIR"
  else
    die "reused server on ${BASE_URL} lists no models — load a model in the oMLX app first"
  fi
fi

MODEL="${OMLX_MODEL:-$DISCOVERED}"
ok "Serving model: $MODEL"

# ---------------------------------------------------------------------------
# Request body (shared across all requests)
# ---------------------------------------------------------------------------
BODY="$WORKDIR/body.json"
jq -n --arg model "$MODEL" --argjson n "$N_GEN" \
  '{
    model: $model,
    messages: [
      {role: "user", content: "Write a detailed technical explanation of how continuous batching improves LLM inference throughput on Apple Silicon. Be thorough."}
    ],
    max_tokens: $n,
    temperature: 0.0,
    stream: false
  }' > "$BODY"

fire_one() {
  # $1 = output file for this request's JSON response; returns curl's status
  # so callers can count failures instead of silently scoring them as 0 tokens
  if ! curl -fsS -X POST "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    --data @"$BODY" \
    -o "$1" 2>/dev/null; then
    printf '{"error":"request failed"}' > "$1"
    return 1
  fi
}

# Warmup (loads weights into the hot cache, primes the scheduler)
header "Warmup"
fire_one "$WORKDIR/warmup.json" || true
WU_TOKENS=$(jq '.usage.completion_tokens // 0' "$WORKDIR/warmup.json")
[[ "$WU_TOKENS" -gt 0 ]] || warn "warmup returned no tokens — check $WORKDIR/warmup.json"
ok "Warmup complete (${WU_TOKENS} tokens)"

# ---------------------------------------------------------------------------
# Concurrency sweep
# ---------------------------------------------------------------------------
header "Concurrency sweep"
printf '  %-12s %-14s %-18s %-14s\n' "Concurrency" "Wall (s)" "Total tokens" "Aggregate tok/s"
printf '  %s\n' "------------------------------------------------------------"

SWEEP_JSON="[]"
for C in $CONCURRENCY; do
  PIDS=()
  T0=$(now_s)
  for (( i = 0; i < C; i++ )); do
    fire_one "$WORKDIR/resp_${C}_${i}.json" &
    PIDS+=("$!")
  done
  FAILED=0
  for p in "${PIDS[@]}"; do wait "$p" || FAILED=$(( FAILED + 1 )); done
  T1=$(now_s)

  WALL=$(jq -n "$T1 - $T0")
  TOTAL_TOK=0
  for (( i = 0; i < C; i++ )); do
    tk=$(jq '.usage.completion_tokens // 0' "$WORKDIR/resp_${C}_${i}.json")
    TOTAL_TOK=$(( TOTAL_TOK + tk ))
  done
  AGG_TPS=$(jq -n "if $WALL > 0 then $TOTAL_TOK / $WALL else 0 end")

  printf '  %-12s %-14s %-18s %-14s\n' \
    "$C" "$(printf '%.2f' "$WALL")" "$TOTAL_TOK" "$(printf '%.1f' "$AGG_TPS")"
  (( FAILED > 0 )) && warn "concurrency ${C}: ${FAILED}/${C} requests failed — level excluded from peak/speedup"

  SWEEP_JSON=$(jq \
    --argjson c "$C" --argjson wall "$WALL" \
    --argjson tok "$TOTAL_TOK" --argjson tps "$AGG_TPS" \
    --argjson failed "$FAILED" \
    '. + [{concurrency: $c, wall_s: $wall, total_completion_tokens: $tok, aggregate_tps: $tps, failed_requests: $failed}]' \
    <<< "$SWEEP_JSON")
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# Levels with failed requests understate throughput — keep them out of the
# headline numbers
SINGLE_TPS=$(jq '[.[] | select(.concurrency == 1 and .failed_requests == 0) | .aggregate_tps] | first // null' <<< "$SWEEP_JSON")
PEAK=$(jq '[.[] | select(.failed_requests == 0)] | if length > 0 then max_by(.aggregate_tps) else null end' <<< "$SWEEP_JSON")
PEAK_TPS=$(jq '.aggregate_tps // null' <<< "$PEAK")
PEAK_CONC=$(jq '.concurrency // null' <<< "$PEAK")
SPEEDUP="null"
if [[ "$SINGLE_TPS" != "null" && "$PEAK_TPS" != "null" ]]; then
  SPEEDUP=$(jq -n "if $SINGLE_TPS > 0 then $PEAK_TPS / $SINGLE_TPS else null end")
fi

header "Summary"
if [[ "$SINGLE_TPS" == "null" ]]; then
  ok "Single-stream:   n/a (no clean concurrency=1 sample)"
else
  ok "Single-stream:   $(printf '%.1f' "$SINGLE_TPS") tok/s"
fi
if [[ "$PEAK_TPS" == "null" ]]; then
  warn "every sweep level had failed requests — peak/speedup not recorded"
else
  ok "Peak aggregate:  $(printf '%.1f' "$PEAK_TPS") tok/s @ concurrency ${PEAK_CONC}"
fi
[[ "$SPEEDUP" != "null" ]] && ok "Batching speedup: $(printf '%.2fx' "$SPEEDUP")"

# ---------------------------------------------------------------------------
# Write results
# ---------------------------------------------------------------------------
jq -n \
  --argjson sysinfo "$SYSINFO" \
  --arg     model   "$MODEL" \
  --argjson maxc    "$MAXCONC" \
  --argjson ngen    "$N_GEN" \
  --argjson single  "${SINGLE_TPS:-null}" \
  --argjson peak    "$PEAK_TPS" \
  --argjson peakc   "$PEAK_CONC" \
  --argjson speedup "${SPEEDUP:-null}" \
  --argjson sweep   "$SWEEP_JSON" \
  --arg     ts      "$(ts_iso)" \
  '{
    metadata: { suite: "omlx", timestamp: $ts, suite_version: "1.0.0" },
    sysinfo: $sysinfo,
    config: { model: $model, max_concurrent_requests: $maxc, n_gen: $ngen },
    single_stream_tps: $single,
    peak_aggregate_tps: $peak,
    peak_concurrency: $peakc,
    batching_speedup: $speedup,
    sweep: $sweep
  }' > "$OUTFILE"

ok "Results: $OUTFILE"
printf '\n'
