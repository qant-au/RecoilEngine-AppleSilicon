#!/bin/bash
# Non-Mac regression check: build this tree for Linux and Windows the way
# upstream Recoil does (docker-build-v2), and run the unit tests on Linux.
# Run it before pushing any change outside rts/System/Platform/Mac, packaging/
# or scripts/: a Linux or Windows break is invisible from a macOS build (the
# port broke the Linux build with an SDL >= 2.0.18-only field, and the install
# step on every platform with a renamed README, before this check existed).
#
# Local only, by decision: GitHub Actions are disabled on this repository.
# Needs Docker and bash 4+ (on macOS: Homebrew bash). amd64 runs emulated on
# Apple Silicon, so a cold build takes a while; later runs are incremental.
#
# Usage: scripts/check-nonmac.sh [linux|windows|all]   (default all)
set -uo pipefail

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
cd "$BAR"
WHAT="${1:-all}"
BASH5=$(command -v /opt/homebrew/bin/bash || command -v bash)
"$BASH5" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' \
  || { echo "FATAL: docker-build-v2 needs bash 4+ (brew install bash)"; exit 2; }
JOBS="${JOBS:-$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc) - 2 ))}"
mkdir -p logs/local
FAIL=0
MIN_TESTS=30
CREG_UPSTREAM_GAP='between drawSorted & blockPreciseCol'

run() { # run <name> <args...>
  local name=$1; shift
  local log="logs/local/check-nonmac-$name.log"
  echo "=== $name: docker-build-v2/build.sh $* (log: $log)"
  if "$BASH5" docker-build-v2/build.sh --arch amd64 -j "$JOBS" "$@" > "$log" 2>&1; then
    echo "    OK"
  else
    echo "    FAILED:"; grep -E '^FAILED|error:|CMake Error' "$log" | head -8 | sed 's/^/      /'
    FAIL=1
  fi
}

case "$WHAT" in
  linux|all)
    # Tests first, on a configured but NOT installed tree: an install puts a
    # second copy of base/ under the build dir and unitsync then (correctly)
    # refuses "duplicate base content". check = engine-headless + every test_*
    # + ctest. testCreg is the one expected failure on 2026.07.04
    # (CSolidObject::paletteIndex, fixed upstream on master).
    rm -rf build-amd64-linux/install
    run linux-configure --configure linux
    log=logs/local/check-nonmac-linux-ctest.log
    echo "=== linux-ctest (log: $log)"
    "$BASH5" docker-build-v2/build.sh --arch amd64 --compile linux -t check > "$log" 2>&1
    rc=$?
    # the step counts only if ctest reported a result with every test in it
    summary=$(grep -E '[0-9]+% tests passed, [0-9]+ tests failed out of [0-9]+' "$log" | tail -1)
    echo "    ${summary:-no ctest result (exit $rc)}"
    total=$(echo "$summary" | sed -E 's/.*out of ([0-9]+).*/\1/')
    if [ -z "$summary" ] || [ "${total:-0}" -lt "$MIN_TESTS" ]; then
      echo "    FAILED: the unit tests did not all run (expected at least $MIN_TESTS)"; FAIL=1
    fi
    failed=$(sed -n '/The following tests FAILED/,$p' "$log" \
             | grep -oE '[0-9]+ - test[A-Za-z0-9_]+' | awk '{print $3}' | sort -u)
    unexpected=$(echo "$failed" | grep -vx testCreg || true)
    if [ -n "$unexpected" ]; then echo "    UNEXPECTED failures: $(echo $unexpected)"; FAIL=1; fi
    # testCreg is excused for the known upstream gap only (see run-unit-tests.sh)
    ours=$(grep 'Missing member' "$log" | grep -v "$CREG_UPSTREAM_GAP" \
           | sed -E 's/.*in class ([A-Za-z0-9_]+).*/\1/' | sort -u)
    if [ -n "$ours" ]; then echo "    UNEXPECTED: testCreg reports unregistered members in: $(echo $ours)"; FAIL=1; fi
    run linux-build linux
    ;;
esac
case "$WHAT" in
  windows|all) run windows-build windows ;;
esac
case "$WHAT" in linux|windows|all) ;; *) echo "usage: $0 [linux|windows|all]"; exit 2;; esac

[ "$FAIL" = 0 ] && echo "NONMAC_OK" || { echo "NONMAC_FAIL"; exit 1; }
