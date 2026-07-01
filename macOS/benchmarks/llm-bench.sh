#!/usr/bin/env bash
# Local LLM benchmark — runs the same model through Apple MLX and llama.cpp
# and records prompt-processing (prefill) and generation (decode) tokens/sec.
# Lets you compare two runtimes on one machine, and one runtime across machines.
#
# Usage: bash llm-bench.sh [--quick] [--mlx-only|--llama-only]
#
# Config (override via environment):
#   MLX_MODEL    HF repo for the MLX runtime    (default: gemma-4-12B-it-8bit)
#   GGUF_REPO    HF repo for the llama.cpp GGUF  (default: ggml-org gemma 12b)
#   GGUF_QUANT   GGUF quant tag                  (default: Q8_0)
#   N_PROMPT     prompt tokens for prefill test  (default: 512)
#   N_GEN        tokens to generate              (default: 128)
#   REPS         repetitions to average          (default: 3)
#
# Note: MLX 8-bit and GGUF Q8_0 are different quantization schemes — close in
# size/quality but not bit-identical. The tokens/sec rates remain comparable.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

MLX_MODEL="${MLX_MODEL:-mlx-community/gemma-4-12B-it-8bit}"
GGUF_REPO="${GGUF_REPO:-ggml-org/gemma-4-12b-it-GGUF}"
GGUF_QUANT="${GGUF_QUANT:-Q8_0}"
N_PROMPT="${N_PROMPT:-512}"
N_GEN="${N_GEN:-128}"
REPS="${REPS:-3}"

QUICK=false
RUN_MLX=true
RUN_LLAMA=true
for arg in "$@"; do
  case "$arg" in
    --quick)      QUICK=true ;;
    --mlx-only)   RUN_LLAMA=false ;;
    --llama-only) RUN_MLX=false ;;
    *) die "unknown flag: $arg" ;;
  esac
done

if $QUICK; then
  N_GEN=64
  REPS=1
fi

check_dep_required jq
check_dep_required curl
ensure_results_dir

HAS_MLX=false;   check_dep mlx_lm.generate && HAS_MLX=true
HAS_LLAMA=false; check_dep llama-bench    && HAS_LLAMA=true

$RUN_MLX   && ! $HAS_MLX   && { warn "mlx_lm.generate not found (brew install mlx-lm) — skipping MLX"; RUN_MLX=false; }
$RUN_LLAMA && ! $HAS_LLAMA && { warn "llama-bench not found (brew install llama.cpp) — skipping llama.cpp"; RUN_LLAMA=false; }

$RUN_MLX || $RUN_LLAMA || die "neither MLX nor llama.cpp available — nothing to benchmark"

SYSINFO=$("$BENCH_DIR/collect-sysinfo.sh")
HOSTNAME_SHORT=$(printf '%s' "$SYSINFO" | jq -r '.hostname')
OUTFILE="$RESULTS_DIR/llm_${HOSTNAME_SHORT}_$(ts_file).json"

printf '\n'
ok "System: $(printf '%s' "$SYSINFO" | jq -r '.chip') | $(printf '%s' "$SYSINFO" | jq -r '.memory_gb')GB"
ok "Config: prompt=${N_PROMPT} gen=${N_GEN} reps=${REPS}"
$RUN_MLX   && info "MLX model:       $MLX_MODEL"
$RUN_LLAMA && info "llama.cpp model: ${GGUF_REPO}:${GGUF_QUANT}"
warn "First run downloads model weights (~13GB per runtime) — this can take a while"

START_S=$SECONDS

# Build a sizeable prompt for the prefill measurement (~N_PROMPT tokens).
build_prompt() {
  local n="$1" out="" i sentence
  sentence="The quick brown fox jumps over the lazy dog while the engineer benchmarks the system. "
  # ~14 tokens per sentence; repeat to roughly reach n tokens
  local reps=$(( n / 12 + 1 ))
  for (( i = 0; i < reps; i++ )); do out+="$sentence"; done
  printf '%s' "$out"
}
PROMPT=$(build_prompt "$N_PROMPT")

# ---------------------------------------------------------------------------
# MLX
# ---------------------------------------------------------------------------
MLX_JSON="null"
if $RUN_MLX; then
  header "MLX runtime ($MLX_MODEL)"
  MLX_SAMPLES="[]"
  MLX_OK=true
  for (( r = 1; r <= REPS; r++ )); do
    info "Run $r/$REPS..."
    OUT=$(mlx_lm.generate \
      --model "$MLX_MODEL" \
      --prompt "$PROMPT" \
      --max-tokens "$N_GEN" \
      2>&1) || { warn "mlx_lm.generate failed — check model id / network"; MLX_OK=false; break; }

    PP=$(printf '%s\n' "$OUT" | grep -E '^Prompt:'     | grep -oE '[0-9.]+ tokens-per-sec' | grep -oE '[0-9.]+' | head -1)
    TG=$(printf '%s\n' "$OUT" | grep -E '^Generation:' | grep -oE '[0-9.]+ tokens-per-sec' | grep -oE '[0-9.]+' | head -1)
    MEM=$(printf '%s\n' "$OUT" | grep -E 'Peak memory:' | grep -oE '[0-9.]+ GB' | grep -oE '[0-9.]+' | head -1)

    [[ -z "$PP"  ]] && PP="null"
    [[ -z "$TG"  ]] && TG="null"
    [[ -z "$MEM" ]] && MEM="null"
    info "  prompt=${PP} tok/s  generation=${TG} tok/s  peak=${MEM}GB"

    MLX_SAMPLES=$(jq \
      --argjson pp "$PP" --argjson tg "$TG" --argjson mem "$MEM" \
      '. + [{pp_tps: $pp, tg_tps: $tg, peak_gb: $mem}]' <<< "$MLX_SAMPLES")
  done

  if $MLX_OK; then
    MLX_JSON=$(jq -n \
      --arg     model   "$MLX_MODEL" \
      --argjson samples "$MLX_SAMPLES" \
      '{
        runtime: "mlx",
        model: $model,
        pp_tps_avg: ([$samples[].pp_tps | select(. != null)] | if length>0 then add/length else null end),
        tg_tps_avg: ([$samples[].tg_tps | select(. != null)] | if length>0 then add/length else null end),
        peak_gb_max: ([$samples[].peak_gb | select(. != null)] | if length>0 then max else null end),
        samples: $samples
      }')
    ok "MLX avg: prompt=$(jq -r '.pp_tps_avg // "n/a"' <<< "$MLX_JSON") tok/s  generation=$(jq -r '.tg_tps_avg // "n/a"' <<< "$MLX_JSON") tok/s"
  fi
fi

# ---------------------------------------------------------------------------
# llama.cpp
# ---------------------------------------------------------------------------
LLAMA_JSON="null"
if $RUN_LLAMA; then
  header "llama.cpp runtime (${GGUF_REPO}:${GGUF_QUANT})"

  # llama-bench only takes local model paths (--hf-repo belongs to
  # llama-cli/llama-server), so resolve the quant's .gguf filename via the HF
  # API and download it once to a local cache.
  GGUF_PATH=""
  GGUF_FILE=$(curl -fsS "https://huggingface.co/api/models/${GGUF_REPO}" 2>/dev/null \
    | jq -r --arg q "$GGUF_QUANT" \
        '[.siblings[].rfilename | select(test("(?i)" + $q + "\\.gguf$"))] | first // empty' \
    || true)
  if [[ -z "$GGUF_FILE" ]]; then
    warn "no single-file ${GGUF_QUANT}.gguf found in ${GGUF_REPO} — skipping llama.cpp"
    warn "Override with: GGUF_REPO=<user/repo> GGUF_QUANT=<Q8_0|Q4_K_M> bash llm-bench.sh"
  else
    GGUF_CACHE="${GGUF_CACHE:-$HOME/.cache/llama.cpp}"
    mkdir -p "$GGUF_CACHE"
    GGUF_PATH="$GGUF_CACHE/${GGUF_FILE##*/}"
    if [[ ! -f "$GGUF_PATH" ]]; then
      info "Downloading ${GGUF_REPO}/${GGUF_FILE} to ${GGUF_CACHE}..."
      curl -fL --progress-bar -o "$GGUF_PATH" \
        "https://huggingface.co/${GGUF_REPO}/resolve/main/${GGUF_FILE}" \
        || { rm -f "$GGUF_PATH"; GGUF_PATH=""; warn "GGUF download failed — skipping llama.cpp"; }
    fi
  fi

  if [[ -n "$GGUF_PATH" ]]; then
    info "Running llama-bench (-p ${N_PROMPT} -n ${N_GEN} -r ${REPS})..."
    LB_ERR=$(mktemp)
    if LB_OUT=$(llama-bench -m "$GGUF_PATH" \
        -p "$N_PROMPT" -n "$N_GEN" -r "$REPS" \
        -o json 2>"$LB_ERR") && [[ -n "$LB_OUT" ]]; then

      # pp test has n_prompt>0,n_gen==0; tg test has n_gen>0,n_prompt==0
      PP_TPS=$(jq '[.[] | select((.n_prompt|tonumber) > 0 and (.n_gen|tonumber) == 0) | .avg_ts | tonumber?] | if length>0 then add/length else null end' <<< "$LB_OUT")
      TG_TPS=$(jq '[.[] | select((.n_gen|tonumber) > 0 and (.n_prompt|tonumber) == 0) | .avg_ts | tonumber?] | if length>0 then add/length else null end' <<< "$LB_OUT")

      LLAMA_JSON=$(jq -n \
        --arg     repo "${GGUF_REPO}:${GGUF_QUANT}" \
        --argjson pp   "${PP_TPS:-null}" \
        --argjson tg   "${TG_TPS:-null}" \
        '{ runtime: "llama.cpp", model: $repo, pp_tps_avg: $pp, tg_tps_avg: $tg }')
      ok "llama.cpp avg: prompt=$(jq -r '.pp_tps_avg // "n/a"' <<< "$LLAMA_JSON") tok/s  generation=$(jq -r '.tg_tps_avg // "n/a"' <<< "$LLAMA_JSON") tok/s"
    else
      warn "llama-bench failed — last stderr lines:"
      tail -5 "$LB_ERR" >&2 || true
    fi
    rm -f "$LB_ERR"
  fi
fi

# ---------------------------------------------------------------------------
# Write results
# ---------------------------------------------------------------------------
header "Writing results"
DURATION_S=$(( SECONDS - START_S ))

jq -n \
  --argjson sysinfo "$SYSINFO" \
  --argjson mlx     "$MLX_JSON" \
  --argjson llama   "$LLAMA_JSON" \
  --argjson nprompt "$N_PROMPT" \
  --argjson ngen    "$N_GEN" \
  --argjson reps    "$REPS" \
  --arg     ts      "$(ts_iso)" \
  --argjson dur     "$DURATION_S" \
  '{
    metadata: { suite: "llm", timestamp: $ts, duration_s: $dur, suite_version: "1.0.0" },
    sysinfo: $sysinfo,
    config: { n_prompt: $nprompt, n_gen: $ngen, reps: $reps },
    mlx: $mlx,
    llama_cpp: $llama
  }' > "$OUTFILE"

ok "Done in ${DURATION_S}s"
ok "Results: $OUTFILE"
printf '\n'
