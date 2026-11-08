#!/bin/bash
# Build real SDL2 (the version the v0.13 release bundles) into
# $DEPS/sdl2-install when Homebrew's "sdl2" is the sdl2-compat shim.
#
# Why: Homebrew replaced its sdl2 formula with sdl2-compat, an SDL2 ABI shim
# over SDL3 that dlopen()s libSDL3.dylib at runtime. release-build.sh bundles
# only what otool -L reports, so the shim would ship without SDL3 and the app
# would fail to start (the hardened runtime ignores DYLD_* fallbacks). It
# would also swap the windowing/input backend under the port's many SDL
# workarounds. v0.13 ships SDL2 2.32.10 (libSDL2-2.0.0.dylib 3201.10.0).
#
# Prints the install prefix for CMAKE_PREFIX_PATH (empty when Homebrew's
# sdl2 is a real SDL2). Called by build-engine.sh.
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$BAR/deps"
SDL2_VER="2.32.10"
# sha256 of the release tarball, from the digest GitHub publishes for the
# release-2.32.10 asset (gh release view release-2.32.10 -R libsdl-org/SDL).
SDL2_SHA256="5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165"
PREFIX="$DEPS/sdl2-install"
LIB="$PREFIX/lib/libSDL2-2.0.0.dylib"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"

# Always built here, even where Homebrew still ships a real SDL2: the bundle must
# not depend on what a bottle happens to be.
# Reuse a previous build only if it was built for the current deployment target;
# otherwise the bundle would carry an SDL with a different minos than the engine.
if [ -f "$LIB" ] && [ -f "$PREFIX/lib/cmake/SDL2/SDL2Config.cmake" ] \
   && [ "$(vtool -show-build "$LIB" 2>/dev/null | awk '/minos/{print $2; exit}')" = "$TARGET" ]; then
  echo "$PREFIX"; exit 0
fi

{
  mkdir -p "$DEPS"
  SRCDIR="$DEPS/SDL2-$SDL2_VER"
  if [ ! -f "$SRCDIR/CMakeLists.txt" ]; then
    curl -fL --retry 3 -o "$DEPS/SDL2-$SDL2_VER.tar.gz" \
      "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VER/SDL2-$SDL2_VER.tar.gz"
    echo "$SDL2_SHA256  $DEPS/SDL2-$SDL2_VER.tar.gz" | shasum -a 256 -c - \
      || { echo "FATAL: SDL2-$SDL2_VER.tar.gz checksum mismatch" >&2; rm -f "$DEPS/SDL2-$SDL2_VER.tar.gz"; exit 1; }
    tar -xzf "$DEPS/SDL2-$SDL2_VER.tar.gz" -C "$DEPS"
  fi
  rm -rf "$SRCDIR/build"
  # prefix maps: keep the builder's path out of SDL's __FILE__ strings
  # (release-build.sh's builder-path audit, LESSON-41)
  PREFIX_MAP="-ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
  cmake -S "$SRCDIR" -B "$SRCDIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
    -DCMAKE_C_FLAGS="$PREFIX_MAP" -DCMAKE_OBJC_FLAGS="$PREFIX_MAP" \
    -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF
  ninja -C "$SRCDIR/build" install
  # SDL installs with an @rpath id; release-build.sh resolves unbundled @rpath
  # deps via /opt/homebrew/lib, which would pick the sdl2-compat shim again.
  # An absolute id makes the bundler copy THIS dylib (and re-id it to @rpath).
  install_name_tool -id "$LIB" "$LIB"
} >&2

test -f "$LIB" || { echo "FATAL: SDL2 build did not produce $LIB" >&2; exit 1; }
echo "$PREFIX"
