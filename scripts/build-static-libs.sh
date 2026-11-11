#!/bin/bash
# Static third-party libraries for the macOS engine, built the way upstream
# Recoil builds them for its Linux release.
#
# Source of truth: https://github.com/beyond-all-reason/spring-static-libs
# (_scripts/download_sources.sh for versions + sha256, _scripts/make_static_libs.sh
# for build flags). The Linux engine the BAR fleet runs is linked statically
# against exactly these; mirroring them is how the macOS engine gets the same
# image decoding, archive handling and audio decoding as Linux and Windows,
# instead of whatever Homebrew bottles happen to be installed.
#
# Ported: zlib 1.3.1, libpng 1.6.50, giflib 5.2.2, jpeg 9f, libtiff 4.7.0,
# DevIL 1.8.0 (IL, ILU, ILUT), libogg 1.3.6, libvorbis 1.3.7, xz 5.8.1,
# minizip-ng 4.0.10. Same sha256 pins and feature flags.
# Not ported (Linux-only or provided by macOS): libunwind, GLEW, OpenSSL,
# nghttp2, libpsl, curl, libuuid. zlib-ng is upstream's non-generic variant;
# the generic build (zlib 1.3.1) is the one ported.
#
# Built at MACOSX_DEPLOYMENT_TARGET, isolated from Homebrew (no /opt/homebrew
# include, library or CMake prefix is consulted), into $DEPS/static, with a
# provenance stamp; a no-op when the stamp matches. Prints the prefix.
#
# Usage: scripts/build-static-libs.sh        (STATIC_LIBS_FORCE=1 rebuilds)
set -euo pipefail

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
case "$BAR" in *" "*) echo "FATAL: the checkout path contains a space, which the build flags and loops do not support: $BAR" >&2; exit 1;; esac
DEPS="$BAR/deps"
PREFIX="${STATIC_PREFIX:-$DEPS/static}"
DL="$DEPS/static-src"
WORK="$DEPS/static-build"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
UPSTREAM_RECIPE="spring-static-libs@master (2026-03-24)"
GCS_CACHE_BASE=https://storage.googleapis.com/recoil-linux-static-build-sources-17834

# name|url|sha256  (from spring-static-libs _scripts/download_sources.sh)
SOURCES='
zlib-1.3.1.tar.gz|https://zlib.net/fossils/zlib-1.3.1.tar.gz|9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
libpng-1.6.50.tar.gz|https://downloads.sourceforge.net/project/libpng/libpng16/1.6.50/libpng-1.6.50.tar.gz|708f4398f996325819936d447f982e0db90b6b8212b7507e7672ea232210949a
giflib-5.2.2.tar.gz|https://downloads.sourceforge.net/project/giflib/giflib-5.x/giflib-5.2.2.tar.gz|be7ffbd057cadebe2aa144542fd90c6838c6a083b5e8a9048b8ee3b66b29d5fb
jpegsrc.v9f.tar.gz|https://www.ijg.org/files/jpegsrc.v9f.tar.gz|04705c110cb2469caa79fb71fba3d7bf834914706e9641a4589485c1f832565b
tiff-4.7.0.tar.gz|https://download.osgeo.org/libtiff/tiff-4.7.0.tar.gz|67160e3457365ab96c5b3286a0903aa6e78bdc44c4bc737d2e486bcecb6ba976
DevIL-1.8.0.tar.gz|https://downloads.sourceforge.net/project/openil/DevIL/1.8.0/DevIL-1.8.0.tar.gz|0075973ee7dd89f0507873e2580ac78336452d29d34a07134b208f44e2feb709
libogg-1.3.6.tar.gz|https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.gz|83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638
libvorbis-1.3.7.tar.gz|https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz|0e982409a9c3fc82ee06e08205b1355e5c6aa4c36bca58146ef399621b0ce5ab
xz-5.8.1.tar.gz|https://github.com/tukaani-project/xz/releases/download/v5.8.1/xz-5.8.1.tar.gz|507825b599356c10dca1cd720c9d0d0c9d5400b9de300af00e4d1ea150795543
minizip-ng-4.0.10.tar.gz|https://github.com/nmoinvaz/minizip/archive/refs/tags/4.0.10.tar.gz|c362e35ee973fa7be58cc5e38a4a6c23cc8f7e652555daf4f115a9eb2d3a6be7
'

# ---- provenance ---------------------------------------------------------------
want_stamp() { echo "recipe=$UPSTREAM_RECIPE"; echo "target=$TARGET"; echo "$SOURCES" | grep -v '^$' | cut -d'|' -f1,3; shasum -a 256 "$0" | cut -d' ' -f1; }
STAMP="$PREFIX/.provenance"
if [ "${STATIC_LIBS_FORCE:-0}" != 1 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(want_stamp)" ]; then
  echo "$PREFIX"; exit 0
fi

{
mkdir -p "$DL"
rm -rf "$WORK" "$PREFIX"; mkdir -p "$WORK" "$PREFIX/include" "$PREFIX/lib"

fetch() { # fetch <name> <url> <sha256>: origin first, upstream's GCS mirror second
  local f="$DL/$1"
  if [ -s "$f" ] && echo "$3  $f" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
  rm -f "$f"
  curl -fsSL --retry 3 -o "$f" "$2" 2>/dev/null || true
  if ! { [ -s "$f" ] && echo "$3  $f" | shasum -a 256 -c - >/dev/null 2>&1; }; then
    rm -f "$f"; curl -fsSL --retry 3 -o "$f" "$GCS_CACHE_BASE/$1"
  fi
  echo "$3  $f" | shasum -a 256 -c - >/dev/null || { echo "FATAL: checksum mismatch for $1"; exit 1; }
}
while IFS='|' read -r name url sha; do [ -n "$name" ] && fetch "$name" "$url" "$sha"; done <<< "$SOURCES"

extract() { # extract <name> -> cd into a fresh source dir
  local d="$WORK/${1%%.tar.gz}"; rm -rf "$d"; mkdir -p "$d"
  tar -xzf "$DL/$1" -C "$d" --strip-components=1; cd "$d"
}

# Isolation from Homebrew: nothing outside the SDK and $PREFIX may be found.
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export MACOSX_DEPLOYMENT_TARGET="$TARGET"
# upstream MYCFLAGS minus x86 tuning: arm64 gets -ffp-contract=off as in its aarch64 lane
CF="-fPIC -DPIC -O3 -fno-omit-frame-pointer -ffp-contract=off -mmacosx-version-min=$TARGET -ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
export CFLAGS="$CF -I$PREFIX/include" CXXFLAGS="$CF -I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
  -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
  -DCMAKE_FIND_FRAMEWORK=NEVER -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
J=$(sysctl -n hw.ncpu)

echo "=== zlib 1.3.1"
extract zlib-1.3.1.tar.gz
./configure --static --prefix "$PREFIX" 
make -j"$J"; make install

echo "=== libpng 1.6.50"
extract libpng-1.6.50.tar.gz
cmake -S . -B build "${CMAKE_COMMON[@]}" -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF -DZLIB_ROOT="$PREFIX"
ninja -C build install

echo "=== giflib 5.2.2"
extract giflib-5.2.2.tar.gz
make -j"$J" libgif.a CFLAGS="$CF -std=gnu99 -Wall"
cp gif_lib.h "$PREFIX/include/"; cp libgif.a "$PREFIX/lib/"

echo "=== jpeg 9f"
extract jpegsrc.v9f.tar.gz
./configure --prefix "$PREFIX" --enable-shared=no --enable-static=yes 
make -j"$J"; make install

echo "=== libtiff 4.7.0"
extract tiff-4.7.0.tar.gz
# upstream: --disable-lzma --disable-jbig (+ docs/tests/tools/contrib); the rest
# are disabled explicitly because Ubuntu's build box simply lacked them
./configure --prefix "$PREFIX" --enable-shared=no --enable-static=yes \
  --disable-lzma --disable-jbig --disable-docs --disable-tests --disable-tools --disable-contrib \
  --disable-webp --disable-zstd --disable-lerc --disable-libdeflate --disable-jpeg12 --disable-cxx \
  --with-zlib-include-dir="$PREFIX/include" --with-zlib-lib-dir="$PREFIX/lib" \
  --with-jpeg-include-dir="$PREFIX/include" --with-jpeg-lib-dir="$PREFIX/lib"
make -j"$J"; make install

echo "=== DevIL 1.8.0 (IL, ILU, ILUT)"
extract DevIL-1.8.0.tar.gz
cd DevIL/src-IL
# upstream builds with gcc -fpermissive, which downgrades DevIL assigning ints to
# jpeg 9's enum `boolean` to a warning; clang has no -fpermissive. Predefining
# TRUE/FALSE selects jmorecfg.h's own `typedef int boolean` branch instead
# (ABI-identical: the enum is int-sized).
DEVIL_CF="$CF -DTRUE=1 -DFALSE=0 -Wno-register -Wno-c++11-narrowing"
cmake -S . -B build "${CMAKE_COMMON[@]}" -DCMAKE_C_FLAGS="$DEVIL_CF" -DCMAKE_CXX_FLAGS="$DEVIL_CF" \
  -DBUILD_SHARED_LIBS=0 \
  -DGIF_INCLUDE_DIR="$PREFIX/include" -DGIF_LIBRARY="$PREFIX/lib/libgif.a" \
  -DPNG_PNG_INCLUDE_DIR="$PREFIX/include" -DPNG_LIBRARY_RELEASE="$PREFIX/lib/libpng.a" \
  -DJPEG_INCLUDE_DIR="$PREFIX/include" -DJPEG_LIBRARY="$PREFIX/lib/libjpeg.a" \
  -DTIFF_INCLUDE_DIR="$PREFIX/include" -DTIFF_LIBRARY_RELEASE="$PREFIX/lib/libtiff.a" \
  -DZLIB_INCLUDE_DIR="$PREFIX/include" -DZLIB_LIBRARY_RELEASE="$PREFIX/lib/libz.a"
ninja -C build install
cd ../src-ILU
sed -i '' 's/ILU SHARED/ILU/g' CMakeLists.txt
cmake -S . -B build "${CMAKE_COMMON[@]}"; ninja -C build install
cd ../src-ILUT
sed -i '' 's/ILUT SHARED/ILUT/g' CMakeLists.txt
cmake -S . -B build "${CMAKE_COMMON[@]}"; ninja -C build install

echo "=== libogg 1.3.6"
extract libogg-1.3.6.tar.gz
./configure --prefix "$PREFIX" --enable-shared=no --enable-static=yes 
make -j"$J"; make install

echo "=== libvorbis 1.3.7"
extract libvorbis-1.3.7.tar.gz
# configure adds -force_cpusubtype_ALL on Darwin, which the current linker rejects
sed -i '' 's/-force_cpusubtype_ALL//g' configure
./configure --prefix "$PREFIX" --enable-shared=no --enable-static=yes --disable-oggtest --with-ogg="$PREFIX" \
  
make -j"$J"; make install

echo "=== xz 5.8.1"
extract xz-5.8.1.tar.gz
./configure --prefix "$PREFIX" --enable-shared=no --enable-static=yes \
  --disable-xz --disable-xzdec --disable-scripts --disable-doc --disable-nls \
  --disable-lzmadec --disable-lzmainfo
make -j"$J"; make install

echo "=== minizip-ng 4.0.10"
# MZ_LIBCOMP=OFF: on Apple minizip-ng defaults to libcompression for deflate;
# Linux decompresses through zlib, so this does too (same code path, 1:1).
extract minizip-ng-4.0.10.tar.gz
cmake -S . -B build "${CMAKE_COMMON[@]}" \
  -DMZ_COMPAT=ON -DMZ_COMPAT_VERSION=110 -DMZ_LIBBSD=OFF -DMZ_PKCRYPT=OFF -DMZ_OPENSSL=OFF \
  -DMZ_SIGNING=OFF -DMZ_WZAES=OFF -DMZ_BZIP2=OFF -DMZ_ZSTD=OFF -DMZ_ICONV=OFF -DMZ_FETCH_LIBS=OFF \
  -DMZ_LIBCOMP=OFF -DMZ_ZLIB=ON \
  -DZLIB_LIBRARY="$PREFIX/lib/libz.a" -DZLIB_INCLUDE_DIR="$PREFIX/include" \
  -DLIBLZMA_LIBRARIES="$PREFIX/lib/liblzma.a" -DLIBLZMA_STATIC_LIBRARIES="$PREFIX/lib/liblzma.a" \
  -DLIBLZMA_INCLUDEDIR="$PREFIX/include" -DLIBLZMA_liblzma_INCLUDEDIR="$PREFIX/include" \
  -DINSTALL_INC_DIR="$PREFIX/include/minizip"
ninja -C build install

# ---- verify ---------------------------------------------------------------------
cd "$BAR"
for a in libz libpng libgif libjpeg libtiff libIL libILU libILUT libogg libvorbis libvorbisfile liblzma; do
  ls "$PREFIX/lib/$a".a >/dev/null 2>&1 || { echo "FATAL: missing $a.a"; exit 1; }
done
ls "$PREFIX"/lib/libminizip*.a >/dev/null 2>&1 || { echo "FATAL: missing libminizip.a"; exit 1; }
if ls "$PREFIX"/lib/*.dylib >/dev/null 2>&1; then echo "FATAL: a shared library was built: $(ls "$PREFIX"/lib/*.dylib)"; exit 1; fi
if grep -rl '/opt/homebrew' "$PREFIX/lib/pkgconfig" "$PREFIX/lib/cmake" 2>/dev/null | head -1 | grep -q .; then
  echo "FATAL: a Homebrew path leaked into the static prefix:"; grep -rl '/opt/homebrew' "$PREFIX/lib/pkgconfig" "$PREFIX/lib/cmake"; exit 1
fi
# licence texts, from the exact sources built (collect-licenses.sh ships them;
# these libraries are linked statically into the engine, so their notices must
# travel with it even though no separate file is bundled)
L="$PREFIX/share/licenses"; mkdir -p "$L"; W="$WORK"
cp "$W/zlib-1.3.1/LICENSE" "$L/zlib.txt"
cp "$W/libpng-1.6.50/LICENSE" "$L/libpng.txt"
cp "$W/giflib-5.2.2/COPYING" "$L/giflib.txt"
cp "$W/jpegsrc.v9f/README" "$L/libjpeg-README.txt"
cp "$W/tiff-4.7.0/LICENSE.md" "$L/libtiff.txt"
cp "$W/DevIL-1.8.0/DevIL/COPYING" "$L/DevIL-LGPL-2.1.txt"
cp "$W/libogg-1.3.6/COPYING" "$L/libogg.txt"
cp "$W/libvorbis-1.3.7/COPYING" "$L/libvorbis.txt"
cp "$W/xz-5.8.1/COPYING.0BSD" "$L/liblzma-0BSD.txt"
cp "$W/minizip-ng-4.0.10/LICENSE" "$L/minizip-ng.txt"
want_stamp > "$STAMP"
echo "static libs OK: $(ls "$PREFIX"/lib/*.a | wc -l | tr -d ' ') archives in $PREFIX (target $TARGET)"
} >&2

echo "$PREFIX"
