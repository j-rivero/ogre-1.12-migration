#!/usr/bin/env bash
# Run a single 90 s benchmark sample for one condition.
#
# Usage: collect_samples.sh <install_dir> <world_path> <run_dir>
#   <install_dir>  colcon install root for the condition
#   <world_path>   absolute path to the SDF world to load
#   <run_dir>      where to write rtf.csv, cpu.csv, gpu.csv, io.csv, cam_hz.csv,
#                  run_meta.json, gzsim.log
#
# 10 s warmup discarded. 80 s measured window. Hard kill at ~90 s.
set -euo pipefail

INSTALL_DIR="${1:?install_dir required}"
WORLD_PATH="${2:?world_path required}"
RUN_DIR="${3:?run_dir required}"

WARMUP_S=10
MEASURE_S=80
TOTAL_S=$((WARMUP_S + MEASURE_S))
WORLD_NAME=shapes
# BENCH_SENSOR_TOPIC overrides the topic whose Hz is sampled into cam_hz.csv.
# Default is the camera bench topic; lidar runs set it to /bench/lidar/scan.
CAMERA_TOPIC="${BENCH_SENSOR_TOPIC:-/bench/camera/image}"

mkdir -p "$RUN_DIR"

META="$RUN_DIR/run_meta.json"
GZSIM_LOG="$RUN_DIR/gzsim.log"

# CSV files
RTF_CSV="$RUN_DIR/rtf.csv"
CPU_CSV="$RUN_DIR/cpu.csv"
GPU_CSV="$RUN_DIR/gpu.csv"
IO_CSV="$RUN_DIR/io.csv"
CAM_CSV="$RUN_DIR/cam_hz.csv"

# Track sampler PIDs for cleanup.
SAMPLER_PIDS=()
GZSIM_PID=""

cleanup() {
  set +e
  echo "[collect_samples] cleanup"
  if [[ -n "$GZSIM_PID" ]]; then
    pkill -P "$GZSIM_PID" 2>/dev/null
    kill -TERM "$GZSIM_PID" 2>/dev/null
    sleep 1
    kill -KILL "$GZSIM_PID" 2>/dev/null
  fi
  for p in "${SAMPLER_PIDS[@]}"; do
    pkill -P "$p" 2>/dev/null
    kill -TERM "$p" 2>/dev/null
  done
  # Brute-force any leftovers from this run.
  pkill -f "ruby .*$WORLD_PATH" 2>/dev/null
  pkill -f "gz sim.*$WORLD_PATH" 2>/dev/null
  pkill -f "gz-sim-server" 2>/dev/null
  pkill -f "gz topic.*$CAMERA_TOPIC" 2>/dev/null
  pkill -f "gz topic.*world/$WORLD_NAME/stats" 2>/dev/null
  return 0
}
trap cleanup EXIT

echo "[collect_samples] sourcing $INSTALL_DIR/setup.bash"
# shellcheck disable=SC1091
set +u
source "$INSTALL_DIR/setup.bash"
set -u

# Belt-and-braces ldd check before running.
PLUGIN="$INSTALL_DIR/lib/gz-rendering/engine-plugins/libgz-rendering-ogre.so"
LINKED_OGRE=$(ldd "$PLUGIN" 2>/dev/null | awk '/libOgreMain.so/ {print $1; exit}')
echo "[collect_samples] linked ogre: $LINKED_OGRE"

T_START=$(date +%s)
echo "[collect_samples] launching gz sim"
# -s = server-only, -r = run on start, --headless-rendering for offscreen GL.
gz sim -s -r --headless-rendering -v 2 "$WORLD_PATH" \
  >"$GZSIM_LOG" 2>&1 &
GZSIM_PID=$!
echo "[collect_samples] gz-sim PID=$GZSIM_PID"

# Wait for the /world/<name>/stats topic to be alive before warmup starts.
WAIT_TIMEOUT=30
for ((i=0; i<WAIT_TIMEOUT; i++)); do
  if gz topic -l 2>/dev/null | grep -q "/world/$WORLD_NAME/stats"; then
    break
  fi
  if ! kill -0 "$GZSIM_PID" 2>/dev/null; then
    echo "[collect_samples] gz-sim died during startup; see $GZSIM_LOG" >&2
    exit 2
  fi
  sleep 1
done

if ! gz topic -l 2>/dev/null | grep -q "/world/$WORLD_NAME/stats"; then
  echo "[collect_samples] timed out waiting for /world/$WORLD_NAME/stats" >&2
  exit 2
fi

T_READY=$(date +%s)
echo "[collect_samples] world stats topic alive (took $((T_READY - T_START))s)"
echo "[collect_samples] warmup ${WARMUP_S}s..."
sleep "$WARMUP_S"

if ! kill -0 "$GZSIM_PID" 2>/dev/null; then
  echo "[collect_samples] gz-sim died during warmup; see $GZSIM_LOG" >&2
  exit 2
fi

T_MEASURE_START=$(date +%s)
echo "[collect_samples] starting samplers (measured window ${MEASURE_S}s)"

# --- Sampler: RTF (parse WorldStatistics from gz topic --json-output) ---
{
  echo "t_unix,sim_time_s,real_time_s,rtf,iterations,paused"
  timeout "$((MEASURE_S + 3))" gz topic -e -t "/world/$WORLD_NAME/stats" --json-output -d "$MEASURE_S" 2>/dev/null | \
    python3 -u -c '
import sys, json, time
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    sim = msg.get("simTime", {}) or msg.get("sim_time", {}) or {}
    real = msg.get("realTime", {}) or msg.get("real_time", {}) or {}
    rtf = msg.get("realTimeFactor", msg.get("real_time_factor", ""))
    it = msg.get("iterations", "")
    paused = msg.get("paused", "")
    sim_s = float(sim.get("sec", 0)) + float(sim.get("nsec", 0)) / 1e9
    real_s = float(real.get("sec", 0)) + float(real.get("nsec", 0)) / 1e9
    print(f"{int(time.time())},{sim_s:.6f},{real_s:.6f},{rtf},{it},{paused}", flush=True)
'
} >"$RTF_CSV" &
SAMPLER_PIDS+=($!)

# --- Sampler: CPU (pidstat for the gz-sim server PID) ---
{
  echo "t_unix,pid,cpu_pct_user,cpu_pct_system,cpu_pct_total,rss_kb"
  for ((i=0; i<MEASURE_S; i++)); do
    if ! kill -0 "$GZSIM_PID" 2>/dev/null; then
      break
    fi
    line=$(awk '{
      utime=$14; stime=$15; rss_pages=$24;
      printf "%s %s %s", utime, stime, rss_pages
    }' "/proc/$GZSIM_PID/stat" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      utime=$(echo "$line" | awk '{print $1}')
      stime=$(echo "$line" | awk '{print $2}')
      rss_pages=$(echo "$line" | awk '{print $3}')
      rss_kb=$((rss_pages * 4))
      now=$(date +%s)
      if [[ -n "${prev_utime:-}" ]]; then
        clk_tck=$(getconf CLK_TCK)
        d_user=$((utime - prev_utime))
        d_sys=$((stime - prev_stime))
        # 1-second window, % of one core = (delta_ticks / clk_tck) * 100
        pct_user=$(awk -v d="$d_user" -v t="$clk_tck" 'BEGIN{printf "%.2f", d/t*100}')
        pct_sys=$(awk -v d="$d_sys" -v t="$clk_tck" 'BEGIN{printf "%.2f", d/t*100}')
        pct_tot=$(awk -v u="$pct_user" -v s="$pct_sys" 'BEGIN{printf "%.2f", u+s}')
        echo "$now,$GZSIM_PID,$pct_user,$pct_sys,$pct_tot,$rss_kb"
      fi
      prev_utime=$utime
      prev_stime=$stime
    fi
    sleep 1
  done
} >"$CPU_CSV" &
SAMPLER_PIDS+=($!)

# --- Sampler: GPU (nvidia-smi) ---
{
  echo "t_unix,gpu_util_pct,mem_util_pct,mem_used_mb,power_w,temp_c"
  timeout "$MEASURE_S" nvidia-smi \
    --query-gpu=utilization.gpu,utilization.memory,memory.used,power.draw,temperature.gpu \
    --format=csv,noheader,nounits -lms 1000 \
    | while IFS=, read -r gpu_util mem_util mem_used power temp; do
        # strip whitespace
        gpu_util=$(echo "$gpu_util" | tr -d ' ')
        mem_util=$(echo "$mem_util" | tr -d ' ')
        mem_used=$(echo "$mem_used" | tr -d ' ')
        power=$(echo "$power" | tr -d ' ')
        temp=$(echo "$temp" | tr -d ' ')
        echo "$(date +%s),$gpu_util,$mem_util,$mem_used,$power,$temp"
      done
} >"$GPU_CSV" &
SAMPLER_PIDS+=($!)

# --- Sampler: IO (iostat) ---
{
  echo "t_unix,device,r_iops,w_iops,r_mb_s,w_mb_s,util_pct"
  timeout "$MEASURE_S" iostat -xy -o JSON 1 2>/dev/null \
    | python3 -u -c '
import sys, json, time
buf = ""
for line in sys.stdin:
    buf += line
    # iostat -o JSON streams a single big JSON object only at end. Fall back:
    # we parse line-oriented output instead. Bail out, will be replaced below.
    pass
' >/dev/null 2>&1 || true
  # iostat JSON streaming is finicky; use plain mode + awk instead.
  timeout "$MEASURE_S" iostat -xy 1 2>/dev/null \
    | awk '
      BEGIN { in_dev = 0 }
      /^Device/ { in_dev = 1; next }
      in_dev && NF == 0 { in_dev = 0; next }
      in_dev {
        device=$1; r_iops=$2; w_iops=$3; rkbs=$4; wkbs=$5; util=$NF
        printf "%d,%s,%s,%s,%.3f,%.3f,%s\n", systime(), device, r_iops, w_iops, rkbs/1024, wkbs/1024, util
        fflush()
      }
    '
} >"$IO_CSV" &
SAMPLER_PIDS+=($!)

# --- Sampler: camera publish Hz (gz topic -f / --frequency) ---
# `gz topic -f` emits lines like "interval [N]:    2.81s" (inter-message gap).
# We convert each interval to instantaneous Hz (1/dt) and write one row per.
{
  echo "t_unix,interval_s,hz_inst"
  timeout "$((MEASURE_S + 3))" gz topic -f -t "$CAMERA_TOPIC" -d "$MEASURE_S" 2>&1 \
    | stdbuf -oL grep -E "^interval \[" \
    | while IFS= read -r line; do
        dt=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+' | tail -1 || true)
        if [[ -n "$dt" ]]; then
          hz=$(awk -v d="$dt" 'BEGIN{ if (d > 0) printf "%.4f", 1.0/d; else print "0" }')
          echo "$(date +%s),$dt,$hz"
        fi
      done
} >"$CAM_CSV" &
SAMPLER_PIDS+=($!)

# Wait for samplers (or gz-sim death).
SAMPLERS_END_BY=$((T_MEASURE_START + MEASURE_S + 5))
gzsim_died_at=""
while (( $(date +%s) < SAMPLERS_END_BY )); do
  if ! kill -0 "$GZSIM_PID" 2>/dev/null; then
    gzsim_died_at=$(date +%s)
    echo "[collect_samples] gz-sim died at $gzsim_died_at"
    break
  fi
  sleep 1
done

# Wait briefly for samplers to flush.
for p in "${SAMPLER_PIDS[@]}"; do
  wait "$p" 2>/dev/null || true
done

T_END=$(date +%s)
echo "[collect_samples] measure window done (elapsed $((T_END - T_MEASURE_START))s)"

# Write run metadata.
cat >"$META" <<EOF
{
  "install_dir": "$INSTALL_DIR",
  "world_path": "$WORLD_PATH",
  "linked_ogre": "$LINKED_OGRE",
  "warmup_s": $WARMUP_S,
  "measure_s": $MEASURE_S,
  "t_start": $T_START,
  "t_ready": $T_READY,
  "t_measure_start": $T_MEASURE_START,
  "t_end": $T_END,
  "gzsim_died_at": "$gzsim_died_at"
}
EOF

echo "[collect_samples] done; outputs in $RUN_DIR"
