#!/bin/bash
# Shared third-party libraries for the macOS app: the ones the Linux release takes
# from the operating system rather than from spring-static-libs (see
# build-static-libs.sh). On macOS there is no system copy, and Homebrew bottles
# drift with every bottling, so they are built here from sha256-pinned upstream
# releases at MACOSX_DEPLOYMENT_TARGET:
#
#   freetype 2.15.0   (zlib + png, both from the static prefix; no bzip2/brotli/harfbuzz)
#   fontconfig 2.18.3 (expat from the macOS SDK; no NLS, docs, tools or tests)
#   openal-soft 1.25.2 (CoreAudio backend; Apple's OpenAL.framework lacks alext/efx)
#
# SDL2 has its own script (build-sdl2.sh). Versions and sha256 match the Homebrew
# formulae of 2026-11-08, which pin upstream release tarballs.
#
# Built against a neutral prefix (/opt/bar-thirdparty, as Mesa is) and staged into
# $DEPS/shared, with absolute install names there; release-build.sh rewrites them
# to @rpath in the bundle. Provenance-stamped; a no-op when current. Needs the
# static prefix (build-static-libs.sh). Prints $DEPS/shared.
#
# Usage: scripts/build-shared-libs.sh       (SHARED_LIBS_FORCE=1 rebuilds)
set -euo pipefail

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
case "$BAR" in *" "*) echo "FATAL: the checkout path contains a space, which the build flags and loops do not support: $BAR" >&2; exit 1;; esac
DEPS="$BAR/deps"
PREFIX="$DEPS/shared"
STATIC="${STATIC_PREFIX:-$DEPS/static}"
NEUTRAL=/opt/bar-thirdparty
DL="$DEPS/shared-src"; WORK="$DEPS/shared-build"; STAGE="$DEPS/shared-stage"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"

SOURCES='
freetype-2.15.0.tar.xz|https://downloads.sourceforge.net/project/freetype/freetype2/2.15.0/freetype-2.15.0.tar.xz|93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5
fontconfig-2.18.3.tar.gz|https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.18.3/fontconfig-2.18.3.tar.gz|9ae01e1d53acdef56010c5451cd34aa41d325b2faccd8606448d8fa01b2496b3
openal-soft-1.25.2.tar.bz2|https://openal-soft.org/openal-releases/openal-soft-1.25.2.tar.bz2|1dbaac44e7579d5bc8847ca8db4b2e8b9fd3961041f35ee20def4958301e1089
'
want_stamp() { echo "target=$TARGET"; echo "$SOURCES" | grep -v '^$' | cut -d'|' -f1,3; shasum -a 256 "$0" | cut -d' ' -f1; cat "$STATIC/.provenance" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }
STAMP="$PREFIX/.provenance"
if [ "${SHARED_LIBS_FORCE:-0}" != 1 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(want_stamp)" ]; then
  echo "$PREFIX"; exit 0
fi
[ -f "$STATIC/lib/libpng.a" ] || { echo "FATAL: static prefix missing (run scripts/build-static-libs.sh)" >&2; exit 1; }

{
mkdir -p "$DL"; rm -rf "$WORK" "$STAGE" "$PREFIX"; mkdir -p "$WORK" "$STAGE" "$PREFIX"
fetch() {
  local f="$DL/$1"
  if [ -s "$f" ] && echo "$3  $f" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
  rm -f "$f"; curl -fsSL --retry 3 -o "$f" "$2"
  echo "$3  $f" | shasum -a 256 -c - >/dev/null || { echo "FATAL: checksum mismatch for $1"; exit 1; }
}
while IFS='|' read -r name url sha; do [ -n "$name" ] && fetch "$name" "$url" "$sha"; done <<< "$SOURCES"
extract() { local d="$WORK/$2"; rm -rf "$d"; mkdir -p "$d"; tar -xf "$DL/$1" -C "$d" --strip-components=1; cd "$d"; }

unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH
SDK="$(xcrun --sdk macosx --show-sdk-path)"
PCDIR="$WORK/pkgconfig"; mkdir -p "$PCDIR"
# expat ships in the SDK without a .pc file
printf '%s\n' "Name: expat" "Description: SDK expat" "Version: 2.7.0" "Libs: -lexpat" "Cflags: -I$SDK/usr/include" > "$PCDIR/expat.pc"
export PKG_CONFIG_LIBDIR="$PCDIR:$STATIC/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""
export MACOSX_DEPLOYMENT_TARGET="$TARGET"
CF="-O2 -mmacosx-version-min=$TARGET -ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
  -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" -DCMAKE_INSTALL_PREFIX="$NEUTRAL"
  -DCMAKE_PREFIX_PATH="$STAGE$NEUTRAL;$STATIC" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
  -DCMAKE_FIND_FRAMEWORK=NEVER -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

echo "=== freetype 2.15.0"
extract freetype-2.15.0.tar.xz freetype
cmake -S . -B build "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_HARFBUZZ=ON \
  -DFT_REQUIRE_PNG=ON -DFT_REQUIRE_ZLIB=ON \
  -DPNG_PNG_INCLUDE_DIR="$STATIC/include" -DPNG_LIBRARY="$STATIC/lib/libpng.a" \
  -DZLIB_INCLUDE_DIR="$STATIC/include" -DZLIB_LIBRARY="$STATIC/lib/libz.a"
ninja -C build
DESTDIR="$STAGE" ninja -C build install
# the staged .pc names the neutral prefix; give the next builds a copy that points
# into the staging dir instead
sed "s|$NEUTRAL|$STAGE$NEUTRAL|g" "$STAGE$NEUTRAL/lib/pkgconfig/freetype2.pc" > "$PCDIR/freetype2.pc"

echo "=== fontconfig 2.18.3"
extract fontconfig-2.18.3.tar.gz fontconfig
# the engine passes its own config on macOS (CFontTexture.cpp), so the compiled-in
# sysconfdir is never consulted; it stays a neutral non-user path
meson setup build --prefix="$NEUTRAL" --buildtype=release --default-library=shared \
  -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled \
  -Dc_args="$CF" -Dc_link_args="-mmacosx-version-min=$TARGET" --wrap-mode=nofallback
ninja -C build
DESTDIR="$STAGE" ninja -C build install

echo "=== openal-soft 1.25.2"
extract openal-soft-1.25.2.tar.bz2 openal-soft
cmake -S . -B build "${CMAKE_COMMON[@]}" -DLIBTYPE=SHARED \
  -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL_CONFIG=OFF \
  -DALSOFT_INSTALL_HRTF_DATA=OFF -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_INSTALL_UTILS=OFF \
  -DALSOFT_BACKEND_PORTAUDIO=OFF -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_JACK=OFF \
  -DALSOFT_BACKEND_SDL2=OFF -DALSOFT_BACKEND_SDL3=OFF -DALSOFT_REQUIRE_COREAUDIO=ON \
  -DHAVE_WFUNCTION_EFFECTS=OFF \
  -DCMAKE_FIND_FRAMEWORK=FIRST  # CoreAudio/AudioToolbox are frameworks; HAVE_WFUNCTION_EFFECTS=OFF: its -Werror=function-effects fails under clang 21 in the CoreAudio callback casts
ninja -C build
DESTDIR="$STAGE" ninja -C build install

# ---- relocate: neutral prefix -> $PREFIX, absolute install names there ---------
(cd "$STAGE$NEUTRAL" && tar cf - lib include) | (cd "$PREFIX" && tar xf -)
for d in "$PREFIX"/lib/*.dylib; do
  [ -L "$d" ] && continue
  chmod u+w "$d"
  # keep each library's own install name (libfreetype.6.dylib, not the real file's
  # libfreetype.6.20.7.dylib): otherwise the engine and fontconfig name the same
  # library differently and the bundle carries, and loads, two copies
  install_name_tool -id "$PREFIX/lib/$(basename "$(otool -D "$d" | tail -1)")" "$d" 2>/dev/null
  for dep in $(otool -L "$d" | tail -n +2 | awk '{print $1}' | grep -E "^($NEUTRAL/|@rpath/)" || true); do
    install_name_tool -change "$dep" "$PREFIX/lib/$(basename "$dep")" "$d" 2>/dev/null
  done
done
for pc in "$PREFIX"/lib/pkgconfig/*.pc; do sed -i '' "s|$NEUTRAL|$PREFIX|g" "$pc"; done
find "$PREFIX/lib/cmake" -name '*.cmake' -exec sed -i '' "s|$NEUTRAL|$PREFIX|g" {} + 2>/dev/null || true

# ---- verify -----------------------------------------------------------------------
cd "$BAR"
for l in libfreetype libfontconfig libopenal; do
  f=$(ls "$PREFIX"/lib/$l*.dylib 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "FATAL: $l not built"; exit 1; }
done
for d in "$PREFIX"/lib/*.dylib; do
  [ -L "$d" ] && continue
  m=$(vtool -show-build "$d" | awk '/minos/{print $2; exit}')
  [ "$m" = "$TARGET" ] || { echo "FATAL: $(basename "$d") minos $m, want $TARGET"; exit 1; }
  if otool -L "$d" | tail -n +2 | awk '{print $1}' | grep -qE '^/(opt/homebrew|usr/local)/'; then
    echo "FATAL: $(basename "$d") links a Homebrew library:"; otool -L "$d"; exit 1
  fi
done
L="$PREFIX/share/licenses"; mkdir -p "$L"
cp "$WORK/freetype/docs/FTL.TXT" "$L/freetype-FTL.txt"
cp "$WORK/fontconfig/COPYING" "$L/fontconfig.txt"
cp "$WORK/openal-soft/COPYING" "$L/openal-soft-LGPL-2.1.txt"
want_stamp > "$STAMP"
echo "shared libs OK: $(cd "$PREFIX/lib" && ls *.dylib | tr '\n' ' ')"
} >&2
echo "$PREFIX"
