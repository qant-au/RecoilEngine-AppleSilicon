#!/bin/bash
# Build minizip (zlib 1.4 contrib/minizip, the same source Homebrew's minizip
# formula uses) into $DEPS/minizip-install at the bundle's deployment target.
#
# Why: Homebrew bottles carry the minos of the macOS they were bottled on. Its
# minizip came out minos 27.2 against a 27.0 floor, so the bundle would refuse
# to load on 27.0/27.1 while the build machine (dyld is lenient) ran it fine.
# Building from pinned source puts minizip on the same floor as the engine.
# Links the system libz from the macOS SDK, as the Homebrew build does.
#
# Prints the install prefix. Called by build-engine.sh.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$BAR/deps"
ZLIB_VER="1.4"
# sha256 of zlib-1.4.tar.gz, as pinned by Homebrew's minizip formula
# (brew info --json=v2 minizip -> urls.stable.checksum).
ZLIB_SHA256="02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584"
PREFIX="$DEPS/minizip-install"
LIB="$PREFIX/lib/libminizip.dylib"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"

# Reuse a previous build only if it was built for the current deployment target.
if [ -f "$LIB" ] && [ -f "$PREFIX/include/minizip/unzip.h" ] && [ -f "$PREFIX/lib/pkgconfig/minizip.pc" ] \
   && [ "$(vtool -show-build "$LIB" 2>/dev/null | awk '/minos/{print $2; exit}')" = "$TARGET" ]; then
  echo "$PREFIX"; exit 0
fi

{
  mkdir -p "$DEPS"
  SRCDIR="$DEPS/zlib-$ZLIB_VER"
  if [ ! -f "$SRCDIR/contrib/minizip/CMakeLists.txt" ]; then
    curl -fL --retry 3 -o "$DEPS/zlib-$ZLIB_VER.tar.gz" "https://zlib.net/zlib-$ZLIB_VER.tar.gz"
    echo "$ZLIB_SHA256  $DEPS/zlib-$ZLIB_VER.tar.gz" | shasum -a 256 -c - \
      || { echo "FATAL: zlib-$ZLIB_VER.tar.gz checksum mismatch" >&2; rm -f "$DEPS/zlib-$ZLIB_VER.tar.gz"; exit 1; }
    tar -xzf "$DEPS/zlib-$ZLIB_VER.tar.gz" -C "$DEPS"
  fi
  # Compiled directly rather than through minizip's CMakeLists, which (standalone)
  # demands zlib's own CMake package: we link the SDK's system libz, exactly as
  # Homebrew's autotools build does, so nothing extra is bundled. Same library
  # name and versions as Homebrew's (libminizip.1.dylib, compat/current 2.0.0).
  # ioapi.h maps the *64 file calls to the native ones on __APPLE__.
  M="$SRCDIR/contrib/minizip"
  rm -rf "$PREFIX"; mkdir -p "$PREFIX/lib" "$PREFIX/include/minizip"
  REAL="$PREFIX/lib/libminizip.1.dylib"
  clang -dynamiclib -O2 -fvisibility=default -mmacosx-version-min="$TARGET" \
    -ffile-prefix-map="$BAR"=. -fdebug-prefix-map="$BAR"=. \
    -DHAVE_HIDDEN -DHAVE_UNISTD_H=1 \
    "$M/ioapi.c" "$M/mztools.c" "$M/unzip.c" "$M/zip.c" -lz \
    -install_name "$REAL" -compatibility_version 2.0.0 -current_version 2.0.0 \
    -o "$REAL"
  ln -sf libminizip.1.dylib "$PREFIX/lib/libminizip.dylib"
  for h in crypt.h ints.h ioapi.h mztools.h unzip.h zip.h skipset.h; do
    cp "$M/$h" "$PREFIX/include/minizip/"
  done
  # pkg-config file: pr-downloader finds minizip via pkg_check_modules, not
  # FindMinizip, so without this it links Homebrew's copy beside ours.
  mkdir -p "$PREFIX/lib/pkgconfig"
  printf '%s\n' "prefix=$PREFIX" 'libdir=${prefix}/lib' 'includedir=${prefix}/include' '' \
    'Name: minizip' 'Description: zlib contrib/minizip (built by build-minizip.sh)' \
    "Version: $ZLIB_VER" 'Libs: -L${libdir} -lminizip' 'Libs.private: -lz' 'Cflags: -I${includedir}' \
    > "$PREFIX/lib/pkgconfig/minizip.pc"
  # The absolute install name above is deliberate, as in build-sdl2.sh:
  # release-build.sh copies the dylib the engine names and re-ids it to @rpath.
} >&2

test -f "$LIB" || { echo "FATAL: minizip build did not produce $LIB" >&2; exit 1; }
echo "$PREFIX"
