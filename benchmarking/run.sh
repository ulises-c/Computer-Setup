#!/usr/bin/env bash
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_ROOT/lib/common.sh"

LABEL="$(hostname -s)"
export ONLY=""
export SKIP=""
DEVICE_TYPE=""

usage() {
  cat <<'USAGE'
Usage: run.sh [--label <name>] [--only <csv>] [--skip <csv>]
              [--device-type <OPTIX|CUDA|HIP|CPU>] [--dry-run]

Runs the installed benchmarks and writes raw logs plus a summary.md into
benchmarking/results/<label>-<timestamp>/.

  --label        results directory prefix (default: short hostname)
  --only         comma-separated subset of: geekbench, blender, superposition
  --skip         comma-separated benchmarks to skip
  --device-type  Blender GPU backend (default: auto — OPTIX on NVIDIA, HIP on AMD)
  --dry-run      print every command without executing
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) require_flag_value "$1" "${2:-}"; LABEL="$2"; shift ;;
    --only) require_flag_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    --skip) require_flag_value "$1" "${2:-}"; SKIP="$2"; shift ;;
    --device-type) require_flag_value "$1" "${2:-}"; DEVICE_TYPE="$2"; shift ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown flag %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
validate_selection

RESULTS_DIR="$RESULTS_ROOT/$LABEL-$(date +%Y%m%d-%H%M%S)"

run_logged() {
  local logfile="$1"
  shift
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] %s | tee %s\n' "$*" "$logfile"
    return 0
  fi
  "$@" 2>&1 | tee "$logfile"
}

write_machine_info() {
  local info="$RESULTS_DIR/machine-info.txt"
  [[ "$DRY_RUN" == true ]] && { printf '  [dry-run] write %s\n' "$info"; return 0; }
  {
    printf 'label: %s\n' "$LABEL"
    printf 'date: %s\n' "$(date -Iseconds)"
    printf 'os: %s\n' "$(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
    printf 'kernel: %s\n' "$(uname -r)"
    printf '\n--- CPU ---\n'
    lscpu
    printf '\n--- Memory ---\n'
    free -h
    printf '\n--- GPU ---\n'
    lspci | grep -iE 'vga|3d controller' || true
    if command -v nvidia-smi >/dev/null 2>&1; then
      nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader || true
    fi
    if [[ -d /sys/module/amdgpu ]]; then
      local amdgpu_version
      amdgpu_version="$(modinfo -F version amdgpu 2>/dev/null || true)"
      printf 'amdgpu module: %s\n' "${amdgpu_version:-in-tree}"
    fi
    if command -v glxinfo >/dev/null 2>&1; then
      printf '\n--- OpenGL ---\n'
      glxinfo -B 2>/dev/null || true
    fi
    if command -v vulkaninfo >/dev/null 2>&1; then
      printf '\n--- Vulkan ---\n'
      vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverInfo' || true
    fi
  } > "$info"
  log_step "Machine info written to $info"
}

run_geekbench() {
  local bin api
  bin="$(geekbench_bin)"
  if [[ ! -x "$bin" && "$DRY_RUN" == false ]]; then
    log_warn "Geekbench not installed, skipping (run ./install.sh)"
    return
  fi
  log_step "Geekbench $GEEKBENCH_VERSION — CPU (free tier uploads results)"
  run_logged "$RESULTS_DIR/geekbench-cpu.log" "$bin" --upload \
    || log_warn "Geekbench CPU run failed"
  for api in OpenCL Vulkan; do
    log_step "Geekbench — GPU $api"
    run_logged "$RESULTS_DIR/geekbench-gpu-${api,,}.log" "$bin" --gpu "$api" --upload \
      || log_warn "Geekbench GPU $api run failed (missing $api runtime?)"
  done
}

blender_gpu_device() {
  if [[ -n "$DEVICE_TYPE" ]]; then
    printf '%s' "$DEVICE_TYPE"
    return
  fi
  case "$(detect_gpu_vendor)" in
    nvidia) printf 'OPTIX' ;;
    amd) printf 'HIP' ;;
    none) printf '' ;;
  esac
}

run_blender_pass() {
  local device="$1" outfile="$2" scenes cmd
  read -ra scenes <<< "$BLENDER_SCENES"
  cmd=("$(blender_cli)" benchmark --blender-version "$BLENDER_VERSION"
    --device-type "$device" --json "${scenes[@]}")
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] cd %s && %s > %s\n' "$TOOLS_DIR" "${cmd[*]}" "$outfile"
    return 0
  fi
  (cd "$TOOLS_DIR" && "${cmd[@]}" > "$outfile") || { rm -f "$outfile"; return 1; }
}

run_blender() {
  local gpu_device
  if [[ ! -x "$(blender_cli)" && "$DRY_RUN" == false ]]; then
    log_warn "Blender benchmark not installed, skipping (run ./install.sh)"
    return
  fi
  log_step "Blender Open Data — CPU"
  run_blender_pass CPU "$RESULTS_DIR/blender-cpu.json" \
    || log_warn "Blender CPU run failed"
  gpu_device="$(blender_gpu_device)"
  if [[ -z "$gpu_device" ]]; then
    log_warn "No GPU detected, skipping Blender GPU pass"
    return
  fi
  if [[ "$gpu_device" == CPU ]]; then
    return
  fi
  log_step "Blender Open Data — GPU ($gpu_device)"
  run_blender_pass "$gpu_device" "$RESULTS_DIR/blender-gpu.json" \
    || log_warn "Blender GPU run failed"
}

run_superposition() {
  local dir automation_dir args logs
  dir="$(superposition_dir)"
  automation_dir="$HOME/.Superposition/automation"
  if [[ ! -d "$dir" && "$DRY_RUN" == false ]]; then
    log_warn "Superposition not installed, skipping (run ./install.sh)"
    return
  fi
  # Free edition has no batch CLI; these engine args replicate what the GUI
  # launcher passes, same approach as the pts/unigine-super test profile.
  args=(-project_name Superposition -data_path ../
    -engine_config ../data/superposition/unigine.cfg
    -system_script superposition/system_script.cpp
    -sound_app null -video_app opengl
    -video_mode -1 -video_width 1920 -video_height 1080 -video_fullscreen 0
    -shaders_quality 1 -textures_quality 1
    -console_command "config_readonly 1 && world_load superposition/superposition"
    -mode 2 -preset 0)
  log_step "Unigine Superposition — 1080p medium, windowed"
  if [[ "$DRY_RUN" == true ]]; then
    printf '  [dry-run] cd %s/bin && ./superposition %s\n' "$dir" "${args[*]}"
    return 0
  fi
  if ! have_display; then
    log_warn "No display session, skipping Superposition (run from the desktop, not SSH)"
    return
  fi
  rm -f "$automation_dir"/log*.txt
  (cd "$dir/bin" && ./superposition "${args[@]}") || log_warn "Superposition run failed"
  logs=("$automation_dir"/log*.txt)
  if [[ -e "${logs[0]}" ]]; then
    cat "${logs[@]}" > "$RESULTS_DIR/superposition.log"
  else
    log_warn "No Superposition automation logs found"
  fi
}

summarize_geekbench() {
  local log
  for log in "$RESULTS_DIR"/geekbench-*.log; do
    [[ -f "$log" ]] || continue
    printf '### %s\n\n```\n' "$(basename "$log" .log)"
    grep -E 'Score|browser\.geekbench\.com' "$log" || printf 'no scores found in log\n'
    printf '```\n\n'
  done
}

summarize_blender() {
  local json
  for json in "$RESULTS_DIR"/blender-*.json; do
    [[ -f "$json" ]] || continue
    printf '### %s (samples/minute)\n\n' "$(basename "$json" .json)"
    jq -r '.[] | "- \(.scene.label): \(.stats.samples_per_minute)"' "$json" 2>/dev/null \
      || printf 'could not parse %s\n' "$(basename "$json")"
    printf '\n'
  done
}

summarize_superposition() {
  [[ -f "$RESULTS_DIR/superposition.log" ]] || return 0
  printf '### superposition\n\n```\n'
  grep -iE 'fps|score' "$RESULTS_DIR/superposition.log" || printf 'no scores found in log\n'
  printf '```\n\n'
}

write_summary() {
  local summary="$RESULTS_DIR/summary.md"
  [[ "$DRY_RUN" == true ]] && { printf '  [dry-run] write %s\n' "$summary"; return 0; }
  {
    printf '# Benchmark summary — %s\n\n' "$LABEL"
    printf 'Run: %s\n\n' "$(date -Iseconds)"
    printf 'Raw logs and machine-info.txt are alongside this file.\n\n'
    summarize_geekbench
    summarize_blender
    summarize_superposition
  } > "$summary"
  log_step "Summary written to $summary"
}

if [[ "$DRY_RUN" == false ]]; then
  mkdir -p "$RESULTS_DIR"
fi
write_machine_info
want geekbench && run_geekbench
want blender && run_blender
want superposition && run_superposition
write_summary
log_step "Done. Results in $RESULTS_DIR"
