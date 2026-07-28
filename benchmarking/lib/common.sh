#!/usr/bin/env bash

export GEEKBENCH_VERSION="${GEEKBENCH_VERSION:-6.7.1}"
export BLENDER_LAUNCHER_VERSION="${BLENDER_LAUNCHER_VERSION:-3.3.0}"
export BLENDER_VERSION="${BLENDER_VERSION:-4.5.0}"
export SUPERPOSITION_VERSION="${SUPERPOSITION_VERSION:-1.1}"
export BLENDER_SCENES="${BLENDER_SCENES:-monster junkshop classroom}"

TOOLS_DIR="$BENCH_ROOT/tools"
RESULTS_ROOT="$BENCH_ROOT/results"
export RESULTS_ROOT

DRY_RUN=false

geekbench_bin() { printf '%s/Geekbench-%s-Linux/geekbench6' "$TOOLS_DIR" "$GEEKBENCH_VERSION"; }
blender_cli() { printf '%s/benchmark-launcher-cli' "$TOOLS_DIR"; }
superposition_dir() { printf '%s/Unigine_Superposition-%s' "$TOOLS_DIR" "$SUPERPOSITION_VERSION"; }

log_step() { printf '==> %s\n' "$*"; }
log_warn() { printf 'warning: %s\n' "$*" >&2; }

run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

run_in_dir() {
  local dir="$1"
  shift
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] cd %s && %s\n' "$dir" "$*"
  else
    (cd "$dir" && "$@")
  fi
}

require_flag_value() {
  if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
    printf 'error: %s requires a value\n' "$1" >&2
    exit 1
  fi
}

validate_selection() {
  local list token tokens
  for list in "${ONLY:-}" "${SKIP:-}"; do
    [[ -z "$list" ]] && continue
    IFS=',' read -ra tokens <<< "$list"
    for token in "${tokens[@]}"; do
      case "$token" in
        geekbench|blender|superposition) ;;
        *)
          printf 'error: unknown benchmark %s (valid: geekbench, blender, superposition)\n' "$token" >&2
          exit 1
          ;;
      esac
    done
  done
}

detect_gpu_vendor() {
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    printf 'nvidia'
  elif [[ -d /sys/module/amdgpu ]]; then
    printf 'amd'
  else
    printf 'none'
  fi
}

have_display() { [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; }

want() {
  local name="$1"
  if [[ -n "${ONLY:-}" ]]; then
    [[ ",$ONLY," == *",$name,"* ]] || return 1
  fi
  [[ ",${SKIP:-}," == *",$name,"* ]] && return 1
  return 0
}
