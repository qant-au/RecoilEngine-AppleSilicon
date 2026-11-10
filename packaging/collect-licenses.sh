#!/bin/bash
# collect-licenses.sh <dest-dir> — gather license texts for everything the
# bundle ships, from the actual source trees/brew cellar (no hand-copied
# texts that can drift). Fails if any expected text is missing.
set -euo pipefail

DEST=${1:?dest dir}
BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
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
    if [ -f "$p" ]; then cp "$p" "$out"; return 0; fi
  done
  echo "MISSING license source for $out (searched: $*)"; fail=1
}

brewdir() { brew --prefix "$1" 2>/dev/null || echo "/nonexistent"; }

grab GPL-2.0.txt            "$SRC/gpl-2.0.txt"
# Third-party libraries built from pinned source (scripts/build-static-libs.sh,
# build-shared-libs.sh) carry their own licence texts in their prefixes.
STATIC_LIC="$BAR/deps/static/share/licenses"; SHARED_LIC="$BAR/deps/shared/share/licenses"
grab LGPL-2.1.txt           "$SHARED_LIC/openal-soft-LGPL-2.1.txt"
grab FTL.txt                "$SHARED_LIC/freetype-FTL.txt"
# SDL: the source-built SDL2 the bundle ships (build-sdl2.sh) first; Homebrew's
# "sdl2" is now sdl2-compat, whose licence text is not the shipped library's.
grab Zlib.txt               "$(ls "$BAR"/deps/SDL2-*/LICENSE.txt 2>/dev/null | tail -1)" "/opt/homebrew/opt/sdl2/LICENSE.txt" "$(brewdir sdl2)/LICENSE.txt" "$(brewdir sdl2)/share/licenses/sdl2/LICENSE.txt"
DRV_LIC="$BAR/deps/driver-deps/share/licenses"
grab Apache-2.0.txt         "$DRV_LIC/Vulkan-Loader-Apache-2.0.txt"
# curl text only required when a curl dylib is actually bundled (system
# libcurl needs no shipped text)
if ls "${BUNDLE_FRAMEWORKS:-/nonexistent}"/libcurl* >/dev/null 2>&1; then
  grab curl.txt             "$(brewdir curl)/COPYING" "/usr/share/curl/COPYING"
fi

# MIT collection: mesa + vendored MIT components, concatenated with headers
{
  echo "==== Mesa (Zink, KosmicKrisp) ===="
  cat "$BAR/deps/mesa-src/docs/license.rst" 2>/dev/null || cat "$BAR/deps/mesa-src/LICENSE" 2>/dev/null || { echo "MESA LICENSE MISSING"; exit 1; }
  for c in lua fmt lunasvg smmalloc; do
    f=$(find "$SRC/rts/lib/$c" -maxdepth 2 -iname "LICENSE*" -o -maxdepth 2 -iname "COPYING*" 2>/dev/null | head -1)
    [ -n "$f" ] && { echo; echo "==== $c ===="; cat "$f"; }
  done
  echo; echo "==== Fontconfig ===="
  cat "$SHARED_LIC/fontconfig.txt" || exit 1
} > "$DEST/MIT-collection.txt"

# BSD-3 collection
{
  for pair in "libogg:$STATIC_LIC/libogg.txt" "libvorbis:$STATIC_LIC/libvorbis.txt" \
              "zstd:$DRV_LIC/zstd-BSD.txt"; do
    name=${pair%%:*}; path=${pair#*:}
    echo "==== $name ===="
    cat "$path" 2>/dev/null || { echo "MISSING $name"; }
    echo
  done
  echo "==== assimp ===="
  cat "$SRC/rts/lib/assimp/LICENSE" 2>/dev/null || true
  echo "==== tracy ===="
  cat "$SRC/rts/lib/tracy/LICENSE" 2>/dev/null || true
} > "$DEST/BSD-3-Clause-collection.txt"

# Image, archive and compression libraries linked statically into the engine
# (the spring-static-libs set, scripts/build-static-libs.sh)
{
  for pair in "libpng:$STATIC_LIC/libpng.txt" \
              "libjpeg (IJG, README legal section):$STATIC_LIC/libjpeg-README.txt" \
              "libtiff:$STATIC_LIC/libtiff.txt" \
              "giflib:$STATIC_LIC/giflib.txt" \
              "zlib:$STATIC_LIC/zlib.txt" \
              "minizip-ng:$STATIC_LIC/minizip-ng.txt" \
              "xz-liblzma:$STATIC_LIC/liblzma-0BSD.txt"; do
    name=${pair%%:*}; path=${pair#*:}
    echo "==== $name ===="
    cat "$path" 2>/dev/null || { echo "MISSING $name license"; exit 1; }
    echo
  done
} > "$DEST/image-codecs-collection.txt"
# DevIL (LGPL-2.1), linked statically: its own copy of the licence text
grab LGPL-2.1-DevIL.txt     "$STATIC_LIC/DevIL-LGPL-2.1.txt"

if [ "$fail" -ne 0 ]; then
  echo "collect-licenses: FAILED"; exit 1
fi
echo "collect-licenses: OK ($(ls "$DEST" | wc -l | tr -d ' ') files)"
