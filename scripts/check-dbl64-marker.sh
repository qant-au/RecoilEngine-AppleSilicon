#!/bin/bash
# Tie an engine binary to the streflop double-precision (dbl-64) libm the build
# verified. The libm parity gate in build-engine.sh tests the archive; this
# looks at what was actually linked. Run it on an unstripped binary.
#
# Each object recompiled by scripts/gcc-dbl64-swap.sh carries a marker string
# that no clang-built object has. A binary passes when either
#   - it holds the marker: its dbl-64 functions are the gcc-built ones, or
#   - it links no dbl-64 function at all: there is nothing for the swap to
#     reach (the case for every engine binary on 2026.09.02, on macOS and on
#     the x86 Linux build alike: the engine only calls the float functions).
# It fails when a dbl-64 function is linked without the marker.
# Usage: check-dbl64-marker.sh <binary>...
set -uo pipefail
RC=0
for bin in "$@"; do
  name=$(basename "$bin")
  syms=$(nm "$bin" 2>/dev/null | c++filt | grep "streflop_libm::")
  marker=$(LC_ALL=C grep -a -c "streflop-dbl64-gcc-swap " "$bin" 2>/dev/null)
  doubles=$(printf "%s\n" "$syms" | grep -c "(double")
  if [ "${marker:-0}" -ge 1 ]; then
    echo "dbl-64 check: $name links $doubles double libm function(s), from the gcc-built objects"
  elif [ -z "$syms" ]; then
    echo "FATAL: $bin has no streflop symbols to inspect (stripped?); run this before stripping"
    RC=1
  elif [ "$doubles" -eq 0 ]; then
    echo "dbl-64 check: $name links no double libm function (float only), so the swap does not reach it"
  else
    echo "FATAL: $bin links $doubles double libm function(s) but not from the gcc-built"
    echo "  objects: its double-precision libm is not the fleet's."
    RC=1
  fi
done
exit $RC
