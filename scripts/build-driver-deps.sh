#!/bin/bash
# Runtime dependencies of the Mesa driver, built from sha256-pinned upstream
# sources instead of Homebrew bottles:
#
#   Vulkan-Headers + Vulkan-Loader  vulkan-sdk-1.4.363.0  (loader as a dylib:
#                                    zink dlopen()s libvulkan.1.dylib by name)
#   SPIRV-Headers + SPIRV-Tools     vulkan-sdk-1.4.363.0  (static, linked into
#                                    the driver; no separate dylib to bundle)
#   zstd                            1.5.7                 (static, the shader
#                                    cache compressor)
#
# Versions and sha256 match the Homebrew formulae of 2026-11-08 (which pin these
# upstream tags). Built at MACOSX_DEPLOYMENT_TARGET, isolated from Homebrew, into
# $DEPS/driver-deps; provenance-stamped. Prints the prefix. Called by
# build-mesa-kk.sh; release-build.sh bundles the loader from here.
#
# Usage: scripts/build-driver-deps.sh        (DRIVER_DEPS_FORCE=1 rebuilds)
set -euo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEPS="$BAR/deps"
PREFIX="$DEPS/driver-deps"
DL="$DEPS/driver-deps-src"; WORK="$DEPS/driver-deps-build"
TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
SDK_TAG=vulkan-sdk-1.4.363.0

SOURCES="
Vulkan-Headers-$SDK_TAG.tar.gz|https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/$SDK_TAG.tar.gz|4a078be12bef21cfebc09d878b77a63cff9d68f899254a0b00d0e37ef73e7f7e
Vulkan-Loader-$SDK_TAG.tar.gz|https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/$SDK_TAG.tar.gz|941eff558fc74f248745fb7df367640cf89a8457f216dae498a74ae14b6ba6f7
SPIRV-Headers-$SDK_TAG.tar.gz|https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/$SDK_TAG.tar.gz|5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9
SPIRV-Tools-$SDK_TAG.tar.gz|https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/$SDK_TAG.tar.gz|e6c83a215538fbfd265ccf398d3877985055df1273dbed73912bd05307664688
zstd-1.5.7.tar.gz|https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz|37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
"
want_stamp() { echo "target=$TARGET"; echo "$SOURCES" | grep -v '^$' | cut -d'|' -f1,3; shasum -a 256 "$0" | cut -d' ' -f1; }
STAMP="$PREFIX/.provenance"
if [ "${DRIVER_DEPS_FORCE:-0}" != 1 ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$(want_stamp)" ]; then
  echo "$PREFIX"; exit 0
fi

{
mkdir -p "$DL"; rm -rf "$WORK" "$PREFIX"; mkdir -p "$WORK" "$PREFIX"
fetch() {
  local f="$DL/$1"
  if [ -s "$f" ] && echo "$3  $f" | shasum -a 256 -c - >/dev/null 2>&1; then return; fi
  rm -f "$f"; curl -fsSL --retry 3 -o "$f" "$2"
  echo "$3  $f" | shasum -a 256 -c - >/dev/null || { echo "FATAL: checksum mismatch for $1"; exit 1; }
}
while IFS='|' read -r name url sha; do [ -n "$name" ] && fetch "$name" "$url" "$sha"; done <<< "$SOURCES"
src() { local d="$WORK/$2"; mkdir -p "$d"; tar -xzf "$DL/$1" -C "$d" --strip-components=1; echo "$d"; }

unset CPATH LIBRARY_PATH PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET="$TARGET"
CF="-O2 -mmacosx-version-min=$TARGET -ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
CM=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET"
    -DCMAKE_C_FLAGS="$CF" -DCMAKE_CXX_FLAGS="$CF" -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

echo "=== Vulkan-Headers $SDK_TAG"
D=$(src "Vulkan-Headers-$SDK_TAG.tar.gz" vulkan-headers)
cmake -S "$D" -B "$D/build" "${CM[@]}"; ninja -C "$D/build" install

echo "=== Vulkan-Loader $SDK_TAG"
D=$(src "Vulkan-Loader-$SDK_TAG.tar.gz" vulkan-loader)
cmake -S "$D" -B "$D/build" "${CM[@]}" -DVULKAN_HEADERS_INSTALL_DIR="$PREFIX" \
  -DBUILD_TESTS=OFF -DUPDATE_DEPS=OFF -DBUILD_WSI_XCB_SUPPORT=OFF -DBUILD_WSI_XLIB_SUPPORT=OFF \
  -DBUILD_WSI_WAYLAND_SUPPORT=OFF -DCMAKE_FIND_FRAMEWORK=FIRST \
  -DSYSCONFDIR=/etc  # else the install prefix (a builder path) is compiled in as a search dir; the app names its ICD via VK_ICD_FILENAMES
ninja -C "$D/build" install

echo "=== SPIRV-Headers + SPIRV-Tools $SDK_TAG (static)"
H=$(src "SPIRV-Headers-$SDK_TAG.tar.gz" spirv-headers)
cmake -S "$H" -B "$H/build" "${CM[@]}" -DSPIRV_HEADERS_ENABLE_TESTS=OFF; ninja -C "$H/build" install
D=$(src "SPIRV-Tools-$SDK_TAG.tar.gz" spirv-tools)
cmake -S "$D" -B "$D/build" "${CM[@]}" -DSPIRV-Headers_SOURCE_DIR="$H" \
  -DBUILD_SHARED_LIBS=OFF -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON \
  -DSPIRV_WERROR=OFF -DSPIRV_TOOLS_BUILD_STATIC=ON
ninja -C "$D/build" install

echo "=== zstd 1.5.7 (static)"
D=$(src zstd-1.5.7.tar.gz zstd)
cmake -S "$D/build/cmake" -B "$D/b" "${CM[@]}" -DZSTD_BUILD_SHARED=OFF -DZSTD_BUILD_STATIC=ON \
  -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
ninja -C "$D/b" install

# Only the loader is a dylib; give it an absolute id here (release-build.sh
# bundles it and rewrites it to @rpath).
L=$(cd "$PREFIX/lib" && readlink -f libvulkan.1.dylib)
install_name_tool -id "$PREFIX/lib/libvulkan.1.dylib" "$L"

# ---- verify ---------------------------------------------------------------------
cd "$BAR"
for f in libSPIRV-Tools.a libzstd.a libvulkan.1.dylib; do
  [ -e "$PREFIX/lib/$f" ] || { echo "FATAL: missing $f"; exit 1; }
done
if ls "$PREFIX"/lib/libSPIRV-Tools*.dylib "$PREFIX"/lib/libzstd*.dylib >/dev/null 2>&1; then
  echo "FATAL: SPIRV-Tools or zstd was built shared"; exit 1
fi
m=$(vtool -show-build "$L" | awk '/minos/{print $2; exit}')
[ "$m" = "$TARGET" ] || { echo "FATAL: libvulkan minos $m, want $TARGET"; exit 1; }
L2="$PREFIX/share/licenses"; mkdir -p "$L2"
cp "$WORK/vulkan-loader/LICENSE.txt" "$L2/Vulkan-Loader-Apache-2.0.txt"
cp "$WORK/spirv-tools/LICENSE" "$L2/SPIRV-Tools-Apache-2.0.txt"
cp "$WORK/zstd/LICENSE" "$L2/zstd-BSD.txt"
want_stamp > "$STAMP"
echo "driver deps OK: $PREFIX"
} >&2
echo "$PREFIX"
