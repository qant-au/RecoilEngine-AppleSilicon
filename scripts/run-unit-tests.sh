#!/bin/bash
# Engine unit tests (ctest) on macOS, built against the same third-party
# libraries the shipped engine uses (static spring-static-libs set, source-built
# freetype/fontconfig/OpenAL/SDL2, the Mesa driver), never Homebrew's.
#
# Builds in build-tests/, NOT build-engine/: a bare ninja in build-engine/ undoes
# the gcc-swapped libm objects (see build-engine.sh). AI_TYPES=NONE.
# Expected on 2026.07.04: 28/29, the one failure testCreg (upstream's
# unregistered CSolidObject::paletteIndex, fixed on Recoil master).
#
# Usage: scripts/run-unit-tests.sh [ctest args...]     prints UNIT_TESTS_OK
set -uo pipefail
BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$BAR"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
MESA_PREFIX="${MESA_PREFIX:-$BAR/deps/mesa-native}"
STATIC_PREFIX="$(scripts/build-static-libs.sh)" || exit 1
SHARED_PREFIX="$(scripts/build-shared-libs.sh)" || exit 1
SDL2_PREFIX="$(scripts/build-sdl2.sh)" || exit 1
export CPATH="$MESA_PREFIX/include"
export PREFER_STATIC_LIBS=TRUE PKG_CONFIG="pkg-config --static"
export PKG_CONFIG_LIBDIR="$STATIC_PREFIX/lib/pkgconfig:$SHARED_PREFIX/lib/pkgconfig:$SDL2_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
mkdir -p logs/local

cmake --fresh -S . -B build-tests -G Ninja -DCMAKE_BUILD_TYPE=RELWITHDEBINFO \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DAI_TYPES=NONE \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_PREFIX_PATH="$STATIC_PREFIX;$SHARED_PREFIX;$SDL2_PREFIX" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DPREFER_STATIC_LIBS=TRUE \
  -DSPRING_MAC_LIBEGL="$MESA_PREFIX/lib/libEGL.dylib" -DOPENAL_SOFT_PREFIX="$SHARED_PREFIX" \
  > logs/local/unit-tests-configure.log 2>&1 || { echo "FATAL: configure failed (logs/local/unit-tests-configure.log)"; exit 1; }
ninja -C build-tests -j"$(sysctl -n hw.ncpu)" tests spring-headless basecontent \
  > logs/local/unit-tests-build.log 2>&1 || { echo "FATAL: build failed (logs/local/unit-tests-build.log)"; grep -E '^FAILED|error:' logs/local/unit-tests-build.log | head; exit 1; }
(cd build-tests && ctest --timeout 900 "$@") > logs/local/unit-tests.log 2>&1
grep -E 'tests passed' logs/local/unit-tests.log
unexpected=$(sed -n '/The following tests FAILED/,$p' logs/local/unit-tests.log \
  | grep -oE '[0-9]+ - test[A-Za-z0-9_]+' | awk '{print $3}' | sort -u | grep -vx testCreg || true)
if [ -n "$unexpected" ]; then echo "UNIT_TESTS_FAIL: $(echo $unexpected)"; exit 1; fi
echo "UNIT_TESTS_OK"
