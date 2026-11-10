#!/bin/bash
# Sanitizer replay: build spring-headless with clang's float-cast-overflow
# check and re-simulate a recorded game with it. Every float-to-integer
# conversion whose value does not fit the target type is reported with its
# source line. Such a conversion is undefined in C++, and x86 and arm64
# produce different results for it, so each report in synced code is a
# possible desync and is a finding until shown harmless.
#
# Run it on each engine merge, against a 1v1, a full team game and a Raptors
# or Scavengers replay if there are any for the engine version
# (scripts/find-fleet-replays.py <engine version>).
#
# Builds in build-sanitize/, never in build-engine/, and without the native AI
# libraries, so a replay that used one cannot be played here. The first build takes a
# while; later ones are incremental. This binary is for this check only: it is
# slower than the release build and is never packaged.
#
# Usage: scripts/sanitize-replay.sh <demo.sdfz> [replay-check.sh options...]
# Prints SANITIZE_REPLAY_OK when the replay stays in sync and no conversion in
# synced code was reported that is not already explained in
# testkit/sanitize/known-sites.txt, SANITIZE_REPLAY_FINDINGS (exit 1) otherwise. The
# full reports stay in logs/local/sanitize-<stamp>/.
set -uo pipefail
BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
case "$BAR" in *" "*) echo "FATAL: the checkout path contains a space: $BAR" >&2; exit 1;; esac
cd "$BAR"
DEMO=${1:?usage: sanitize-replay.sh <demo.sdfz> [replay-check.sh options...]}; shift
[ -f "$DEMO" ] || { echo "FATAL: no such demo: $DEMO"; exit 1; }
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
MESA_PREFIX="${MESA_PREFIX:-$BAR/deps/mesa-native}"
STATIC_PREFIX="$(scripts/build-static-libs.sh)" || exit 1
SHARED_PREFIX="$(scripts/build-shared-libs.sh)" || exit 1
SDL2_PREFIX="$(scripts/build-sdl2.sh)" || exit 1
export CPATH="$MESA_PREFIX/include"
export PREFER_STATIC_LIBS=TRUE PKG_CONFIG="pkg-config --static"
export PKG_CONFIG_LIBDIR="$STATIC_PREFIX/lib/pkgconfig:$SHARED_PREFIX/lib/pkgconfig:$SDL2_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
OUT="logs/local/sanitize-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
BUILD="$BAR/build-sanitize"
SAN="-fsanitize=float-cast-overflow -fno-omit-frame-pointer"

echo "=== build spring-headless with $SAN (log: $OUT/build.log)"
cmake --fresh -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RELWITHDEBINFO \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DAI_TYPES=NONE \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_C_FLAGS="$SAN" -DCMAKE_CXX_FLAGS="$SAN" \
  -DCMAKE_EXE_LINKER_FLAGS="$SAN" -DCMAKE_SHARED_LINKER_FLAGS="$SAN" \
  -DCMAKE_PREFIX_PATH="$STATIC_PREFIX;$SHARED_PREFIX;$SDL2_PREFIX" \
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DPREFER_STATIC_LIBS=TRUE \
  -DSPRING_MAC_LIBEGL="$MESA_PREFIX/lib/libEGL.dylib" -DOPENAL_SOFT_PREFIX="$SHARED_PREFIX" \
  > "$OUT/configure.log" 2>&1 || { echo "FATAL: configure failed ($OUT/configure.log)"; exit 1; }
ninja -C "$BUILD" -j"$(sysctl -n hw.ncpu)" spring-headless basecontent > "$OUT/build.log" 2>&1 \
  || { echo "FATAL: build failed ($OUT/build.log)"; grep -E '^FAILED|error:' "$OUT/build.log" | head; exit 1; }

echo "=== replay $DEMO"
# one report file per process; each report carries a stack trace
export UBSAN_OPTIONS="print_stacktrace=1:log_path=$BAR/$OUT/ubsan:halt_on_error=0"
scripts/replay-check.sh "$DEMO" --engine "$BUILD/spring-headless" --log "$OUT/engine.log" "$@" | tee "$OUT/replay.txt"
replay_rc=${PIPESTATUS[0]}

# every distinct reporting site, with how often it fired
cat "$OUT"/ubsan.* 2>/dev/null | awk '/runtime error:/ {
    loc = $1; sub(/^.*\/rts\//, "rts/", loc); sub(/:[0-9]+:$/, "", loc)
    msg = $0; sub(/^.*runtime error: /, "", msg); sub(/^[^ ]+ is outside/, "value is outside", msg)
    print loc "\t" msg }' | sort | uniq -c | sort -rn > "$OUT/sites.txt"
total=$(wc -l < "$OUT/sites.txt" | tr -d ' ')
# code that can reach synced state (the Lua VM runs synced gadgets too), less
# the sites already looked at and listed with their reason
KNOWN="$BAR/testkit/sanitize/known-sites.txt"
synced=$(grep -E 'rts/(Sim|System/Sync|Map|lib/lua|lib/streflop)/|rts/Lua/LuaSynced|rts/System/(float3|float4|SpringMath|FastMath|Matrix44f|myMath)' "$OUT/sites.txt" || true)
known=0
if [ -n "$synced" ] && [ -f "$KNOWN" ]; then
  rest=""
  while IFS= read -r line; do
    site=$(printf '%s' "$line" | awk '{print $2}')
    if grep -v '^#' "$KNOWN" | cut -f1 | grep -qx "$site"; then known=$((known+1)); else rest="$rest$line
"; fi
  done <<EOF_SITES
$synced
EOF_SITES
  synced=$(printf '%s' "$rest" | sed '/^$/d')
fi
echo "=== $total distinct conversion site(s) reported ($OUT/sites.txt)"
[ "$total" -gt 0 ] && sed 's/^/    /' "$OUT/sites.txt" | head -40
if [ "$replay_rc" -ne 0 ]; then
  echo "SANITIZE_REPLAY_FINDINGS: the replay did not stay in sync on the sanitizer build ($OUT/replay.txt)"; exit 1
fi
if [ -n "$synced" ]; then
  echo "SANITIZE_REPLAY_FINDINGS: $(printf '%s\n' "$synced" | wc -l | tr -d ' ') site(s) in code that can reach synced state:"
  printf '%s\n' "$synced" | sed 's/^/    /'
  exit 1
fi
echo "SANITIZE_REPLAY_OK ($total site(s) reported; in code that can reach synced state: $known, all listed in testkit/sanitize/known-sites.txt)"
