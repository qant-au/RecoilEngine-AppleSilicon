#!/bin/bash
# streflop cross-architecture sync test: build tools/sync-test natively (NEON on
# Apple Silicon), run the reference suite, and require a bit-exact match with
# the committed x86 SSE reference and the committed NEON reference.
#
# This is the macOS-local equivalent of upstream's "STREFLOP Float Sync Test"
# workflow (.github/workflows/streflop-float-test.yml), which we do not run:
# GitHub Actions are disabled on this repository by decision. CPU-only, seconds.
#
# Called by `build-engine.sh --with-synctest` and `release-build.sh
# --with-synctest` as: ENGINE_SRC=<tree> run-synctest.sh --build-dir <dir>
# Usage: scripts/run-synctest.sh [--build-dir DIR] [-n N]   (default N=10000)
# Prints SYNCTEST_OK on success.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="${ENGINE_SRC:-$BAR}"
BUILD="$BAR/build-synctest"
N=10000
while [ $# -gt 0 ]; do
  case "$1" in
    --build-dir) BUILD=$2; shift 2;;
    -n) N=$2; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
REF="$SRC/tools/sync-test/reference"

cmake -S "$SRC/tools/sync-test" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release >/dev/null
ninja -C "$BUILD" streflop-float-test >/dev/null
( cd "$BUILD" && ./streflop-float-test -n "$N" synctest_local >/dev/null )

FAIL=0
for ref in streflop_results_SSE_x86_64 streflop_results_NEON_arm64; do
  [ -f "$REF/$ref.bin" ] || { echo "FATAL: missing reference $REF/$ref.bin"; exit 1; }
  out=$(python3 "$SRC/tools/sync-test/compare_results.py" "$REF/$ref.bin" "$BUILD/synctest_local.bin" 2>&1)
  verdict=$(echo "$out" | grep -E '^RESULT:' | tail -1)
  common=$(echo "$out" | grep -E 'Common tests:' | awk '{print $3}')
  echo "vs $ref: $verdict (common tests: ${common:-?})"
  echo "$verdict" | grep -q 'BIT-EXACT MATCH' || { echo "$out" | tail -20; FAIL=1; }
done
[ "$FAIL" = 0 ] && echo "SYNCTEST_OK" || { echo "SYNCTEST_FAIL"; exit 1; }
