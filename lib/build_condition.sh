#!/usr/bin/env bash
# Build one benchmark "condition" — a (gz-rendering branch, ogre prefix) pair.
#
# Usage: build_condition.sh <branch> <ogre_prefix_or_->  <build_root>
#   <branch>            git branch to switch ws/src/gz-rendering to
#   <ogre_prefix_or_->  prefix for ogre install, or "-" to use system ogre
#   <build_root>        e.g. ws/build-1.9 (build/install dirs created underneath)
#
# Sibling-roots (build-1.9, install-1.9) keep ws/build/ and ws/install/ untouched.
# After build, asserts the linked libOgreMain version matches the prefix.
set -euo pipefail

BRANCH="${1:?branch required}"
OGRE_PREFIX="${2:?ogre_prefix required (or - for system)}"
BUILD_ROOT="${3:?build_root required}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS="$PROJECT_ROOT/ws"
GZR_SRC="$WS/src/gz-rendering"

BUILD_DIR="$BUILD_ROOT/build"
INSTALL_DIR="$BUILD_ROOT/install"
LOG_DIR="$PROJECT_ROOT/bench/results/build-logs"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR" "$LOG_DIR"

LOG_FILE="$LOG_DIR/condition-$(basename "$BUILD_ROOT").log"
echo "[build_condition] branch=$BRANCH  ogre_prefix=$OGRE_PREFIX  build_root=$BUILD_ROOT"
echo "[build_condition] log -> $LOG_FILE"

# This script switches the gz-rendering branch in-place, so only one
# instance may run at a time. Serialize via a lock on the gz-rendering tree.
LOCK_FILE="$GZR_SRC/.bench-build.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[build_condition] another build is in progress (lock $LOCK_FILE)" >&2
  exit 3
fi

# Save current branch state so we can restore on exit.
ORIG_BRANCH=$(cd "$GZR_SRC" && git rev-parse --abbrev-ref HEAD)
trap 'echo "[build_condition] restoring gz-rendering to $ORIG_BRANCH"; (cd "$GZR_SRC" && git checkout --quiet "$ORIG_BRANCH") || true' EXIT

(cd "$GZR_SRC" && git checkout --quiet "$BRANCH")

# Compose CMAKE_PREFIX_PATH: include ogre prefix if given.
EXTRA_PREFIX_PATH=""
if [[ "$OGRE_PREFIX" != "-" ]]; then
  EXTRA_PREFIX_PATH="$OGRE_PREFIX"
fi

(
  set -x
  cd "$WS"
  unset AMENT_PREFIX_PATH COLCON_PREFIX_PATH GZ_CONFIG_PATH GZ_GUI_PLUGIN_PATH \
    GZ_SIM_RESOURCE_PATH GZ_SIM_SYSTEM_PLUGIN_PATH PKG_CONFIG_PATH \
    LD_LIBRARY_PATH 2>/dev/null || true

  if [[ -n "$EXTRA_PREFIX_PATH" ]]; then
    export CMAKE_PREFIX_PATH="$EXTRA_PREFIX_PATH${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export PKG_CONFIG_PATH="$EXTRA_PREFIX_PATH/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$EXTRA_PREFIX_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi

  colcon build \
    --packages-select gz-rendering gz-sensors gz-gui gz-sim \
    --build-base "$BUILD_DIR" \
    --install-base "$INSTALL_DIR" \
    --event-handlers console_cohesion+ \
    --cmake-args \
      -DBUILD_TESTING=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
) >"$LOG_FILE" 2>&1

# Linkage assertion: the built gz-rendering-ogre plugin should link against
# the expected ogre version. For ogre_prefix="-" (system), we expect 1.12.x;
# otherwise we extract the SONAME from $OGRE_PREFIX/lib/libOgreMain.so*.
PLUGIN="$INSTALL_DIR/lib/gz-rendering/engine-plugins/libgz-rendering-ogre.so"
if [[ ! -f "$PLUGIN" ]]; then
  echo "[build_condition] ERROR: $PLUGIN not produced; see $LOG_FILE" >&2
  exit 1
fi

LINKED=$(ldd "$PLUGIN" 2>/dev/null | awk '/libOgreMain.so/ {print $1; exit}')
echo "[build_condition] gz-rendering-ogre links against: $LINKED"

if [[ "$OGRE_PREFIX" == "-" ]]; then
  EXPECTED=1.12
else
  # Take the SONAME of the just-built libOgreMain.
  EXPECTED=$(ls "$OGRE_PREFIX"/lib/libOgreMain.so.* 2>/dev/null \
             | head -n1 | sed -E 's/.*libOgreMain\.so\.([0-9]+\.[0-9]+).*/\1/')
fi

if [[ "$LINKED" != *"$EXPECTED"* ]]; then
  echo "[build_condition] ERROR: linked $LINKED does not match expected $EXPECTED" >&2
  exit 1
fi

echo "[build_condition] OK: linkage matches expected ogre $EXPECTED"
