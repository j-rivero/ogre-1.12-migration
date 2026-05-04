#!/usr/bin/env bash
# Generate bench/worlds/<name>.sdf from gz-sim's shapes_population.sdf.erb
# (when N_SHAPES is set) or 3k_shapes.sdf (when not), and inject:
#   - gz-sim-sensors-system plugin (so camera sensors render)
#   - a camera-bearing static model with a 1280x720 @ 30 Hz camera sensor
#
# Env / args:
#   N_SHAPES   number of each-shape rows to emit (so total = ~3 * N_SHAPES);
#              omit / 0 = use the prebuilt 3k_shapes.sdf as-is (3000 total).
#   OUT_NAME   basename of output (default: 3k_shapes_camera or N_shapes_camera)
set -euo pipefail

N_SHAPES="${N_SHAPES:-0}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ERB_TPL="$PROJECT_ROOT/ws/src/gz-sim/examples/worlds/shapes_population.sdf.erb"
SRC_3K="$PROJECT_ROOT/ws/src/gz-sim/examples/worlds/3k_shapes.sdf"
OUT_DIR="$PROJECT_ROOT/bench/worlds"
mkdir -p "$OUT_DIR"

if (( N_SHAPES > 0 )); then
  OUT_NAME="${OUT_NAME:-${N_SHAPES}_shapes_camera}"
  TMP_ERB=$(mktemp --suffix=.erb)
  trap 'rm -f "$TMP_ERB"' EXIT
  # Replace the hardcoded `n = 1000` in the template with our N_SHAPES.
  sed "s/^      n = 1000$/      n = ${N_SHAPES}/" "$ERB_TPL" >"$TMP_ERB"
  if ! grep -q "n = ${N_SHAPES}" "$TMP_ERB"; then
    echo "[build_world] could not patch ERB count (template format changed?)" >&2
    exit 1
  fi
  SRC_WORLD=$(mktemp --suffix=.sdf)
  trap 'rm -f "$TMP_ERB" "$SRC_WORLD"' EXIT
  erb -T 1 "$TMP_ERB" >"$SRC_WORLD"
else
  OUT_NAME="${OUT_NAME:-3k_shapes_camera}"
  SRC_WORLD="$SRC_3K"
fi

OUT_WORLD="$OUT_DIR/${OUT_NAME}.sdf"

if [[ ! -f "$SRC_WORLD" ]]; then
  echo "[build_world] missing source $SRC_WORLD" >&2
  exit 1
fi

python3 - "$SRC_WORLD" "$OUT_WORLD" <<'PY'
import sys, re

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

sensors_plugin = '''    <plugin
      filename="gz-sim-sensors-system"
      name="gz::sim::systems::Sensors">
      <render_engine>ogre</render_engine>
      <background_color>0.8 0.8 0.8 1.0</background_color>
    </plugin>
'''

camera_model = '''    <model name="bench_camera_rig">
      <static>true</static>
      <pose>0 0 30 0 0.4 0</pose>
      <link name="link">
        <sensor name="bench_camera" type="camera">
          <update_rate>30</update_rate>
          <topic>/bench/camera/image</topic>
          <camera>
            <horizontal_fov>1.396</horizontal_fov>
            <image>
              <width>1280</width>
              <height>720</height>
              <format>R8G8B8</format>
            </image>
            <clip>
              <near>0.1</near>
              <far>2000</far>
            </clip>
          </camera>
          <always_on>true</always_on>
          <visualize>false</visualize>
        </sensor>
      </link>
    </model>
'''

pattern = re.compile(
    r'(<plugin\s+filename="gz-sim-scene-broadcaster-system"[^<]*'
    r'name="gz::sim::systems::SceneBroadcaster"[^<]*>\s*</plugin>)',
    re.DOTALL,
)
new_text, n = pattern.subn(r'\1\n' + sensors_plugin.rstrip(), text, count=1)
if n != 1:
    sys.exit("could not locate scene-broadcaster plugin block to anchor sensors plugin")

idx = new_text.rfind('</world>')
if idx < 0:
    sys.exit("could not locate </world>")
new_text = new_text[:idx] + camera_model + new_text[idx:]

with open(dst, 'w') as f:
    f.write(new_text)
PY

grep -q 'gz-sim-sensors-system' "$OUT_WORLD" || { echo "sensors plugin missing in $OUT_WORLD"; exit 1; }
grep -q 'bench_camera' "$OUT_WORLD" || { echo "bench_camera missing in $OUT_WORLD"; exit 1; }

n_models=$(grep -c '<model name=' "$OUT_WORLD" || true)
echo "[build_world] wrote $OUT_WORLD ($(wc -l <"$OUT_WORLD") lines, $n_models <model> blocks)"
