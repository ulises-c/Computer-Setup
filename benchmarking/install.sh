#!/usr/bin/env bash
set -euo pipefail

BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BENCH_ROOT/lib/common.sh"

export ONLY=""
export SKIP=""
FORCE=false

usage() {
  cat <<'USAGE'
Usage: install.sh [--dry-run] [--force] [--only <geekbench,blender,superposition>]

Downloads and installs the automated benchmarks into benchmarking/tools/.
Prints manual steps for OCCT and SPECviewperf at the end.

  --dry-run   print every download/command without executing
  --force     re-download even if a tool is already installed
  --only      comma-separated subset of: geekbench, blender, superposition
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    --only) require_flag_value "$1" "${2:-}"; ONLY="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown flag %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
validate_selection

install_prereqs() {
  local pkg missing=()
  for pkg in curl jq mesa-utils vulkan-tools pciutils; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    log_step "Prerequisites already installed"
    return
  fi
  log_step "Installing prerequisites (${missing[*]})"
  run_cmd sudo apt-get update
  run_cmd sudo apt-get install -y "${missing[@]}"
}

fetch() {
  local url="$1" dest="$2"
  if [[ -f "$dest" && "$FORCE" == false ]]; then
    log_step "Using existing $(basename "$dest") (use --force to re-download)"
  else
    run_cmd curl -fL --retry 3 -o "$dest" "$url"
    log_checksum "$dest"
  fi
}

log_checksum() {
  local file="$1"
  if [[ "$DRY_RUN" == false && -f "$file" ]]; then
    printf '  sha256: %s\n' "$(sha256sum "$file" | cut -d' ' -f1)"
  fi
}

install_geekbench() {
  local bin tarball
  bin="$(geekbench_bin)"
  if [[ -x "$bin" && "$FORCE" == false ]]; then
    log_step "Geekbench $GEEKBENCH_VERSION already installed (use --force to re-download)"
    return
  fi
  log_step "Installing Geekbench $GEEKBENCH_VERSION"
  tarball="$TOOLS_DIR/Geekbench-$GEEKBENCH_VERSION-Linux.tar.gz"
  fetch "https://cdn.geekbench.com/Geekbench-$GEEKBENCH_VERSION-Linux.tar.gz" "$tarball"
  run_cmd tar -xzf "$tarball" -C "$TOOLS_DIR"
  run_cmd "$bin" --version
}

install_blender() {
  local cli tarball scenes
  cli="$(blender_cli)"
  if [[ -x "$cli" && "$FORCE" == false ]]; then
    log_step "Blender benchmark launcher already installed (use --force to re-download)"
  else
    log_step "Installing Blender benchmark launcher $BLENDER_LAUNCHER_VERSION"
    tarball="$TOOLS_DIR/benchmark-launcher-cli-$BLENDER_LAUNCHER_VERSION-linux.tar.gz"
    fetch "https://download.blender.org/release/BlenderBenchmark2.0/launcher/benchmark-launcher-cli-$BLENDER_LAUNCHER_VERSION-linux.tar.gz" "$tarball"
    run_cmd tar -xzf "$tarball" -C "$TOOLS_DIR"
  fi
  log_step "Downloading Blender $BLENDER_VERSION and benchmark scenes (multi-GB)"
  read -ra scenes <<< "$BLENDER_SCENES"
  run_in_dir "$TOOLS_DIR" "$cli" blender download "$BLENDER_VERSION"
  run_in_dir "$TOOLS_DIR" "$cli" scenes download --blender-version "$BLENDER_VERSION" "${scenes[@]}"
}

install_superposition() {
  local dir runfile
  dir="$(superposition_dir)"
  if [[ -d "$dir" && "$FORCE" == false ]]; then
    log_step "Unigine Superposition $SUPERPOSITION_VERSION already installed (use --force to re-download)"
    return
  fi
  log_step "Installing Unigine Superposition $SUPERPOSITION_VERSION (~1.6 GB)"
  runfile="$TOOLS_DIR/Unigine_Superposition-$SUPERPOSITION_VERSION.run"
  fetch "https://assets.unigine.com/d/Unigine_Superposition-$SUPERPOSITION_VERSION.run" "$runfile"
  run_cmd chmod +x "$runfile"
  run_in_dir "$TOOLS_DIR" "$runfile" --nox11
}

print_manual_steps() {
  cat <<'MANUAL'

Manual benchmarks (not automated — details and license caveats in benchmarking/README.md):

  OCCT (stress & thermals): GUI install from https://www.ocbase.com/download
  SPECviewperf 2020 Linux Edition: registration + ~80 GB, see README
MANUAL
}

run_cmd mkdir -p "$TOOLS_DIR"
install_prereqs
want geekbench && install_geekbench
want blender && install_blender
want superposition && install_superposition
print_manual_steps
log_step "Install complete. Run ./run.sh to benchmark."
