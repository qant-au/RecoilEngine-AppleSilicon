#!/bin/bash
# Window-free GPU check of the driver stack the app ships: builds
# test/macos/gpu-smoke.c against the Mesa driver in $MESA_PREFIX and runs it with
# the same driver selection the launcher uses (packaging/launcher.sh). Uses the
# real GPU through Metal; opens no window. Prints GPU_SMOKE_OK.
#
# Usage: scripts/gpu-smoke.sh        (MESA_PREFIX overrides deps/mesa-native)
set -uo pipefail
BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
MESA_PREFIX="${MESA_PREFIX:-$BAR/deps/mesa-native}"
DRIVER_DEPS="${DRIVER_DEPS:-$BAR/deps/driver-deps}"
OUT="$BAR/build-gpu-smoke"; mkdir -p "$OUT"
ICD=$(ls "$MESA_PREFIX"/share/vulkan/icd.d/*.json | head -1)
[ -f "$ICD" ] || { echo "FATAL: no KosmicKrisp ICD under $MESA_PREFIX"; exit 1; }

clang -O1 -Wall -I"$MESA_PREFIX/include" "$BAR/test/macos/gpu-smoke.c" \
  -L"$MESA_PREFIX/lib" -lEGL -Wl,-rpath,"$MESA_PREFIX/lib" -Wl,-rpath,"$DRIVER_DEPS/lib" \
  -o "$OUT/gpu-smoke" || { echo "FATAL: compile failed"; exit 1; }

# exactly the driver environment packaging/launcher.sh exports; keep in step with it
EGL_PLATFORM=surfaceless VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" \
  GALLIUM_DRIVER=zink MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.6 \
  "$OUT/gpu-smoke"
