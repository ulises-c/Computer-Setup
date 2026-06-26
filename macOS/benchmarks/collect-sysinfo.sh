#!/usr/bin/env bash
# Outputs a JSON object with machine identity to stdout.
# No identifying info (serial number, UUID, username) — safe for public repos.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib.sh
source "$BENCH_DIR/lib.sh"

check_dep_required jq

sysctl_n() { sysctl -n "$1" 2>/dev/null || printf ''; }

HOSTNAME_SHORT=$(hostname -s)
CHIP=$(sysctl_n machdep.cpu.brand_string)
MODEL_ID=$(sysctl_n hw.model)
P_CORES=$(sysctl_n hw.perflevel0.physicalcpu)
E_CORES=$(sysctl_n hw.perflevel1.physicalcpu)
TOTAL_PHYS=$(sysctl_n hw.physicalcpu)
TOTAL_LOGICAL=$(sysctl_n hw.logicalcpu)
MEM_BYTES=$(sysctl_n hw.memsize)
MEMORY_GB=$(( MEM_BYTES / 1024 / 1024 / 1024 ))
MACOS_VER=$(sw_vers -productVersion)
MACOS_BUILD=$(sw_vers -buildVersion)
KERNEL=$(uname -r)

# NVMe model — parse from system_profiler, strip leading/trailing whitespace
SSD_MODEL=$(system_profiler SPNVMeDataType 2>/dev/null \
  | awk '/Model:/{$1=""; sub(/^ /,""); print; exit}' \
  || printf 'unknown')

jq -n \
  --arg  hostname      "$HOSTNAME_SHORT" \
  --arg  chip          "$CHIP" \
  --arg  model_id      "$MODEL_ID" \
  --argjson p_cores    "${P_CORES:-0}" \
  --argjson e_cores    "${E_CORES:-0}" \
  --argjson total_phys "${TOTAL_PHYS:-0}" \
  --argjson total_logi "${TOTAL_LOGICAL:-0}" \
  --argjson memory_gb  "${MEMORY_GB:-0}" \
  --arg  ssd_model     "$SSD_MODEL" \
  --arg  macos_ver     "$MACOS_VER" \
  --arg  macos_build   "$MACOS_BUILD" \
  --arg  kernel        "$KERNEL" \
  '{
    hostname:          $hostname,
    chip:              $chip,
    model_id:          $model_id,
    p_cores:           $p_cores,
    e_cores:           $e_cores,
    total_physical_cores: $total_phys,
    total_logical_cores:  $total_logi,
    memory_gb:         $memory_gb,
    ssd_model:         $ssd_model,
    macos_version:     $macos_ver,
    macos_build:       $macos_build,
    kernel:            $kernel
  }'
