#!/bin/bash
# collect-licenses.sh <dest-dir> — gather license texts for everything the
# bundle ships, from the actual source trees and dependency prefixes (no
# hand-copied texts that can drift). Fails if any expected text is missing or
# empty: nothing is skipped quietly, and no placeholder is ever written into
# the collection.
set -euo pipefail

DEST=${1:?dest dir}
BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
# Engine source: what the caller packaged (release-build.sh passes ENGINE_SRC),
# else the same derivation release-build.sh uses. This was hardcoded to
# $BAR/engine-2025.06.24, a tree that no longer exists, so a clean checkout
# failed here on the engine's own COPYING.
SRC="${ENGINE_SRC:-$([ -d "$BAR/rts" ] && echo "$BAR" || echo "$BAR/engine")}"
mkdir -p "$DEST"
fail=0

grab() { # grab <dest-name> <candidate paths...>
  local out=$DEST/$1; shift
  local p
  for p in "$@"; do
    if [ -s "$p" ]; then cp "$p" "$out"; return 0; fi
  done
  echo "MISSING license source for $out (searched: $*)"; fail=1
}

# section <title> <candidate paths...>: one titled text inside a collection.
# Writes to stdout; a missing text is reported on stderr and fails the run
# (the groups below run in this shell, so setting "fail" here is seen).
section() {
  local title=$1; shift
  local p
  for p in "$@"; do
    if [ -s "$p" ]; then echo "==== $title ===="; cat "$p"; echo; return 0; fi
  done
  echo "MISSING license text for $title (searched: $*)" >&2
  fail=1
}

brewdir() { brew --prefix "$1" 2>/dev/null || echo "/nonexistent"; }

grab GPL-2.0.txt            "$SRC/gpl-2.0.txt"
# the engine's own license statement and the notices for third-party code in
# its source tree (SOP.hpp, gflags, mingw-std-threads, ConcurrentQueue)
grab engine-third-party-notices.txt "$SRC/THIRD-PARTY-NOTICES.md"
# Third-party libraries built from pinned source (scripts/build-static-libs.sh,
# build-shared-libs.sh) carry their own licence texts in their prefixes.
STATIC_LIC="$BAR/deps/static/share/licenses"; SHARED_LIC="$BAR/deps/shared/share/licenses"
grab LGPL-2.1.txt           "$SHARED_LIC/openal-soft-LGPL-2.1.txt"
grab FTL.txt                "$SHARED_LIC/freetype-FTL.txt"
# SDL: the source-built SDL2 the bundle ships (build-sdl2.sh) first; Homebrew's
# "sdl2" is now sdl2-compat, whose licence text is not the shipped library's.
grab Zlib.txt               "$(ls "$BAR"/deps/SDL2-*/LICENSE.txt 2>/dev/null | tail -1)" "/opt/homebrew/opt/sdl2/LICENSE.txt" "$(brewdir sdl2)/LICENSE.txt" "$(brewdir sdl2)/share/licenses/sdl2/LICENSE.txt"
DRV_LIC="$BAR/deps/driver-deps/share/licenses"
# Apache-2.0: the Vulkan loader (shipped beside the engine) and SPIRV-Tools
# (inside the driver library) are under the same text
grab Apache-2.0.txt         "$DRV_LIC/Vulkan-Loader-Apache-2.0.txt" "$DRV_LIC/SPIRV-Tools-Apache-2.0.txt"
# curl text only required when a curl dylib is actually bundled (system
# libcurl needs no shipped text)
if ls "${BUNDLE_FRAMEWORKS:-/nonexistent}"/libcurl* >/dev/null 2>&1; then
  grab curl.txt             "$(brewdir curl)/COPYING" "/usr/share/curl/COPYING"
fi

# LLVM and the SPIRV-LLVM-Translator are linked into the driver library
# (scripts/build-mesa-kk.sh builds against Homebrew's llvm@19; the libclc source
# pinned by scripts/build-libclc.sh carries the same LLVM project licence).
{
  section "LLVM 19 (Apache-2.0 with LLVM exceptions)" \
    "$(brewdir llvm@19)/LICENSE.TXT" "$(ls "$BAR"/deps/libclc-*.src/LICENSE.TXT 2>/dev/null | tail -1)"
  section "SPIRV-LLVM-Translator" "$BAR/deps/spirv-xlat/LICENSE.TXT"
} > "$DEST/LLVM.txt"

# MIT collection: mesa + vendored MIT components, concatenated with headers
{
  section "Mesa (Zink, KosmicKrisp)" "$BAR/deps/mesa-src/docs/license.rst" "$BAR/deps/mesa-src/LICENSE"
  # Lua's text is named COPYRIGHT, which a search for LICENSE* never found
  section "Lua"       "$SRC/rts/lib/lua/COPYRIGHT"
  section "fmt"       "$SRC/rts/lib/fmt/LICENSE"
  section "lunasvg"   "$SRC/rts/lib/lunasvg/LICENSE"
  section "smmalloc"  "$SRC/rts/lib/smmalloc/LICENSE"
  section "RmlUi"     "$SRC/rts/lib/RmlUi/LICENSE.txt"
  section "luasocket" "$SRC/rts/lib/luasocket/LICENSE"
  section "Fontconfig" "$SHARED_LIC/fontconfig.txt"
} > "$DEST/MIT-collection.txt"

# BSD collection (3-clause, and one 2-clause text)
{
  section "libogg"    "$STATIC_LIC/libogg.txt"
  section "libvorbis" "$STATIC_LIC/libvorbis.txt"
  section "zstd"      "$DRV_LIC/zstd-BSD.txt"
  section "assimp"    "$SRC/rts/lib/assimp/LICENSE"
  section "tracy"     "$SRC/rts/lib/tracy/LICENSE"
  section "gflags"    "$SRC/rts/lib/gflags/COPYING.txt"
  # moodycamel ConcurrentQueue is one header; its licence is the comment at its top
  CQ="$SRC/rts/System/ConcurrentQueue.h"
  CQ_TEXT=$(sed -n '/Simplified BSD license/,/SUCH DAMAGE/p' "$CQ" 2>/dev/null | sed -e 's|^// \{0,1\}||')
  [ -n "$CQ_TEXT" ] || { echo "MISSING license text for moodycamel ConcurrentQueue (in $CQ)" >&2; fail=1; }
  echo "==== moodycamel ConcurrentQueue (Simplified BSD, 2-clause) ===="
  printf '%s\n\n' "$CQ_TEXT"
} > "$DEST/BSD-3-Clause-collection.txt"

# Image, archive and compression libraries linked statically into the engine
# (the spring-static-libs set, scripts/build-static-libs.sh)
{
  section "libpng"     "$STATIC_LIC/libpng.txt"
  section "libjpeg (IJG, README legal section)" "$STATIC_LIC/libjpeg-README.txt"
  section "libtiff"    "$STATIC_LIC/libtiff.txt"
  section "giflib"     "$STATIC_LIC/giflib.txt"
  section "zlib"       "$STATIC_LIC/zlib.txt"
  section "minizip-ng" "$STATIC_LIC/minizip-ng.txt"
  section "xz-liblzma" "$STATIC_LIC/liblzma-0BSD.txt"
} > "$DEST/image-codecs-collection.txt"
# DevIL (LGPL-2.1), linked statically: its own copy of the licence text
grab LGPL-2.1-DevIL.txt     "$STATIC_LIC/DevIL-LGPL-2.1.txt"

if [ "$fail" -ne 0 ]; then
  echo "collect-licenses: FAILED"; exit 1
fi
echo "collect-licenses: OK ($(ls "$DEST" | wc -l | tr -d ' ') files)"
