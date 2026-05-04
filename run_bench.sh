#!/usr/bin/env bash
# Top-level benchmark driver.
#
# 1) Build ogre 1.9.1 from reference (skipped if already installed).
# 2) Generate the 3k_shapes_camera world.
# 3) Build both conditions:
#      - main_ogre19  : gz-rendering main + ogre 1.9 from local prefix
#      - ogre112      : gz-rendering jrivero/ogre112 + system ogre 1.12
# 4) Run 5 samples per condition.
# 5) Aggregate -> summary.csv + report.md.
#
# Usage:
#   run_bench.sh [--skip-build] [--skip-bench] [--n-runs N] [--force]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$PROJECT_ROOT/bench/lib"
WS="$PROJECT_ROOT/ws"
OGRE_19_PREFIX="$WS/reference/ogre/install-1.9"

N_RUNS=5
SKIP_BUILD=0
SKIP_BENCH=0
FORCE=0
WORLD_NAME="3k_shapes_camera"
SENSOR_TYPE="camera"

while (( $# > 0 )); do
  case "$1" in
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-bench) SKIP_BENCH=1; shift ;;
    --n-runs)     N_RUNS="$2"; shift 2 ;;
    --force)      FORCE=1; shift ;;
    --world)      WORLD_NAME="$2"; shift 2 ;;
    --sensor)     SENSOR_TYPE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^#//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$SENSOR_TYPE" in
  camera) export BENCH_SENSOR_TOPIC="/bench/camera/image" ;;
  lidar)  export BENCH_SENSOR_TOPIC="/bench/lidar/scan" ;;
  *) echo "[run_bench] --sensor must be camera|lidar" >&2; exit 2 ;;
esac
echo "[run_bench] sensor=$SENSOR_TYPE  topic=$BENCH_SENSOR_TOPIC"

WORLD="$PROJECT_ROOT/bench/worlds/${WORLD_NAME}.sdf"

TS=$(date +"%Y-%m-%d-%H%M")
RESULTS_ROOT="$PROJECT_ROOT/bench/results/$TS"
mkdir -p "$RESULTS_ROOT"

# --- Sanity checks ---
echo "[run_bench] env checks (use --force to bypass)"
if ! command -v nvidia-smi >/dev/null; then
  echo "[run_bench] nvidia-smi missing" >&2; exit 2
fi
if ! command -v iostat >/dev/null; then
  echo "[run_bench] iostat missing — install sysstat" >&2; exit 2
fi

# Refuse to run if another process holds the GPU >5% util.
gpu_users=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l)
if (( gpu_users > 0 )) && (( ! FORCE )); then
  echo "[run_bench] GPU has $gpu_users compute apps running:"
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null
  echo "[run_bench] re-run with --force to bypass" >&2
  exit 2
fi

# Refuse to run if 1-min load average is too high.
load1=$(awk '{print $1}' /proc/loadavg)
if (( ! FORCE )) && awk -v l="$load1" 'BEGIN{exit !(l > 2.0)}'; then
  echo "[run_bench] 1-min load average $load1 > 2.0; system busy"
  echo "[run_bench] re-run with --force to bypass" >&2
  exit 2
fi
echo "[run_bench] env OK; load1=$load1"

# --- Stage 1: ogre 1.9 build (idempotent) ---
if (( ! SKIP_BUILD )); then
  echo "[run_bench] ensuring ogre 1.9 build"
  "$LIB/build_ogre_19.sh"
fi

# --- Stage 2: world generation (always regenerate) ---
# Re-derive N_SHAPES and OUT_NAME from WORLD_NAME so build_world.sh produces
# the world the runner expects. Pattern: <NN>_shapes_<sensor> or 3k_shapes_<sensor>.
echo "[run_bench] generating world ($WORLD_NAME)"
WORLD_N_SHAPES=0
if [[ "$WORLD_NAME" =~ ^([0-9]+)_shapes_(camera|lidar)$ ]]; then
  WORLD_N_SHAPES="${BASH_REMATCH[1]}"
fi
SENSOR_TYPE="$SENSOR_TYPE" N_SHAPES="$WORLD_N_SHAPES" OUT_NAME="$WORLD_NAME" \
  "$LIB/build_world.sh"

# --- Stage 3: condition builds ---
if (( ! SKIP_BUILD )); then
  echo "[run_bench] building condition main_ogre19"
  "$LIB/build_condition.sh" main "$OGRE_19_PREFIX" "$WS/build-1.9"

  echo "[run_bench] building condition ogre112"
  "$LIB/build_condition.sh" jrivero/ogre112 - "$WS/build-1.12"
fi

# Sanity: install dirs exist and are linked correctly.
INSTALL_19="$WS/build-1.9/install"
INSTALL_12="$WS/build-1.12/install"
for d in "$INSTALL_19" "$INSTALL_12"; do
  if [[ ! -f "$d/lib/gz-rendering/engine-plugins/libgz-rendering-ogre.so" ]]; then
    echo "[run_bench] missing build artifact in $d" >&2
    exit 2
  fi
done

# --- Stage 4: benchmark runs ---
if (( ! SKIP_BENCH )); then
  echo "[run_bench] running condition main_ogre19"
  "$LIB/run_condition.sh" "$INSTALL_19" "$WORLD" "$RESULTS_ROOT" main_ogre19 "$N_RUNS" || true

  echo "[run_bench] running condition ogre112"
  "$LIB/run_condition.sh" "$INSTALL_12" "$WORLD" "$RESULTS_ROOT" ogre112 "$N_RUNS" || true
fi

# --- Stage 5: aggregate ---
echo "[run_bench] aggregating"
python3 "$LIB/aggregate.py" "$RESULTS_ROOT"

echo
echo "[run_bench] done."
echo "[run_bench] results: $RESULTS_ROOT"
echo "[run_bench] report:  $RESULTS_ROOT/report.md"
