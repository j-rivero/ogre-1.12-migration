#!/usr/bin/env bash
# Build ogre 1.9.1 from ws/reference/ogre into a custom prefix so the
# main-branch (1.9) gz-rendering build can link against it without
# disturbing the system libogre-1.12-dev install.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OGRE_SRC="$PROJECT_ROOT/ws/reference/ogre"
OGRE_BUILD="$OGRE_SRC/build-1.9"
OGRE_PREFIX="$OGRE_SRC/install-1.9"
OGRE_TAG="v1.9.1"

LIB_PROBE="$OGRE_PREFIX/lib/libOgreMain.so"

if [[ -f "$LIB_PROBE" ]]; then
  echo "[build_ogre_19] $LIB_PROBE already exists — skipping build."
  exit 0
fi

echo "[build_ogre_19] checking out $OGRE_TAG in $OGRE_SRC"
cd "$OGRE_SRC"
git checkout --quiet "$OGRE_TAG"

# Disable the Samples subdirectory entirely. In 1.9, `add_subdirectory(Samples)`
# in the top-level CMakeLists.txt is unconditional, and Samples/CMakeLists.txt
# blows up if OIS is missing even when OGRE_BUILD_SAMPLES=OFF. We don't need
# samples for the benchmark, so just skip the subdirectory. Idempotent.
TOP_CMAKE="$OGRE_SRC/CMakeLists.txt"
if grep -q '^add_subdirectory(Samples)$' "$TOP_CMAKE"; then
  echo "[build_ogre_19] disabling Samples subdirectory in top CMakeLists.txt"
  sed -i 's|^add_subdirectory(Samples)$|# add_subdirectory(Samples)  # disabled by bench/build_ogre_19.sh|' "$TOP_CMAKE"
fi

mkdir -p "$OGRE_BUILD"
cd "$OGRE_BUILD"

echo "[build_ogre_19] configuring"
cmake "$OGRE_SRC" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$OGRE_PREFIX" \
  -DOGRE_BUILD_SAMPLES=OFF \
  -DOGRE_BUILD_TOOLS=OFF \
  -DOGRE_BUILD_TESTS=OFF \
  -DOGRE_INSTALL_DOCS=OFF \
  -DOGRE_INSTALL_SAMPLES=OFF \
  -DOGRE_INSTALL_SAMPLES_SOURCE=OFF \
  -DOGRE_BUILD_RENDERSYSTEM_D3D9=OFF \
  -DOGRE_BUILD_RENDERSYSTEM_D3D11=OFF \
  -DOGRE_BUILD_PLUGIN_BSP=OFF \
  -DOGRE_BUILD_PLUGIN_OCTREE=ON \
  -DOGRE_BUILD_COMPONENT_OVERLAY=ON \
  -DOGRE_BUILD_COMPONENT_PAGING=ON \
  -DOGRE_BUILD_COMPONENT_TERRAIN=ON \
  -DOGRE_BUILD_COMPONENT_RTSHADERSYSTEM=ON \
  -DOIS_INCLUDE_DIR=/usr/include \
  -DCMAKE_CXX_FLAGS="-Wno-error -fpermissive"

echo "[build_ogre_19] building (-j5)"
make -j5

echo "[build_ogre_19] installing to $OGRE_PREFIX"
make install

echo "[build_ogre_19] done. libOgreMain at $LIB_PROBE"
ls -lh "$OGRE_PREFIX/lib/" | head -20
