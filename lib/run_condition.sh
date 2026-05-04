#!/usr/bin/env bash
# Run N benchmark samples for one condition.
#
# Usage: run_condition.sh <install_dir> <world_path> <results_root> <condition_name> [n_runs]
set -euo pipefail

INSTALL_DIR="${1:?install_dir required}"
WORLD_PATH="${2:?world_path required}"
RESULTS_ROOT="${3:?results_root required}"
COND_NAME="${4:?condition_name required}"
N_RUNS="${5:-5}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECT="$PROJECT_ROOT/bench/lib/collect_samples.sh"

COND_DIR="$RESULTS_ROOT/$COND_NAME"
mkdir -p "$COND_DIR"

echo "[run_condition] $COND_NAME: $N_RUNS runs into $COND_DIR"

failed=0
for ((i=1; i<=N_RUNS; i++)); do
  RUN_DIR=$(printf "%s/run_%02d" "$COND_DIR" "$i")
  echo "[run_condition] $COND_NAME run $i/$N_RUNS -> $RUN_DIR"
  if "$COLLECT" "$INSTALL_DIR" "$WORLD_PATH" "$RUN_DIR"; then
    echo "[run_condition] $COND_NAME run $i OK"
  else
    rc=$?
    echo "[run_condition] $COND_NAME run $i FAILED (rc=$rc)"
    failed=$((failed + 1))
  fi
  # Brief pause between runs so GPU/CPU settle and any orphan procs die.
  sleep 5
done

echo "[run_condition] $COND_NAME: completed; failures=$failed/$N_RUNS"
if (( failed >= (N_RUNS / 2 + 1) )); then
  echo "[run_condition] $COND_NAME: majority failed; aborting condition" >&2
  exit 1
fi
