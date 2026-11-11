#!/bin/bash
# Engine unit tests (ctest) on macOS, built against the same third-party
# libraries the shipped engine uses (static spring-static-libs set, source-built
# freetype/fontconfig/OpenAL/SDL2, the Mesa driver), never Homebrew's.
#
# Builds in build-tests/, NOT build-engine/: a bare ninja in build-engine/ undoes
# the gcc-swapped libm objects (see build-engine.sh). AI_TYPES=NONE.
# Expected on 2026.09.02: 29 of 30, the one failure testCreg, for one known
# upstream gap (an unregistered CProjectile member, reported as a missing byte
# "between drawSorted & blockPreciseCol" in every projectile class). testCreg is
# excused for that message only; any other class it reports fails the run.
#
# Usage: scripts/run-unit-tests.sh [ctest args...]     prints UNIT_TESTS_OK
set -uo pipefail
MIN_TESTS=30
CREG_UPSTREAM_GAP='between drawSorted & blockPreciseCol'
BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
cd "$BAR"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
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
rc=$?
# OK is only printed for a run that produced a result: ctest's own summary line
# must be there, and a full run (no extra ctest args) must hold every test.
summary=$(grep -E '[0-9]+% tests passed, [0-9]+ tests failed out of [0-9]+' logs/local/unit-tests.log | tail -1)
[ -n "$summary" ] || { echo "UNIT_TESTS_FAIL: ctest printed no result (exit $rc, logs/local/unit-tests.log)"; exit 1; }
echo "$summary"
total=$(echo "$summary" | sed -E 's/.*out of ([0-9]+).*/\1/')
if [ $# -eq 0 ] && [ "$total" -lt "$MIN_TESTS" ]; then
  echo "UNIT_TESTS_FAIL: only $total tests ran (expected at least $MIN_TESTS)"; exit 1
fi
failed=$(sed -n '/The following tests FAILED/,$p' logs/local/unit-tests.log \
  | grep -oE '[0-9]+ - test[A-Za-z0-9_]+' | awk '{print $3}' | sort -u)
unexpected=$(echo "$failed" | grep -vx testCreg || true)
if [ -n "$unexpected" ]; then echo "UNIT_TESTS_FAIL: $(echo $unexpected)"; exit 1; fi
if [ "$rc" -ne 0 ] && [ -z "$failed" ]; then
  echo "UNIT_TESTS_FAIL: ctest exit $rc with no failed test listed (logs/local/unit-tests.log)"; exit 1
fi
# testCreg is excused only for the known upstream gap. Any other class it
# reports is a registration gap of ours and fails the run.
if echo "$failed" | grep -qx testCreg; then
  ours=$(grep 'Missing member' build-tests/Testing/Temporary/LastTest.log 2>/dev/null \
    | grep -v "$CREG_UPSTREAM_GAP" | sed -E 's/.*in class ([A-Za-z0-9_]+).*/\1/' | sort -u)
  if [ -n "$ours" ]; then echo "UNIT_TESTS_FAIL: testCreg reports unregistered members in: $(echo $ours)"; exit 1; fi
fi
echo "UNIT_TESTS_OK"
