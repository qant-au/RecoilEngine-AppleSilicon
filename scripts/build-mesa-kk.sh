#!/bin/bash
# Build the Mesa Zink + KosmicKrisp graphics stack for the macOS port.
# The procedure for changing the pin or a patch is in docs/MAINTENANCE.md.
#
# You should NOT need to run this by hand: build-engine.sh and
# packaging/release-build.sh invoke it automatically and it is a no-op when the
# driver is already current (provenance stamp match).
#
# Reproducible from pinned upstream: clones freedesktop Mesa at a pinned commit,
# applies patches/mesa/*.patch, and builds. It records a provenance stamp
# ($MESA_PREFIX/.driver-provenance = pinned commit + patch sha256s + spirv tag
# + driver dependencies + macOS target + a hash of this script's commands)
# and skips the whole build when the installed driver already matches it.
#
# Env:
#   MESA_PREFIX        install prefix (default deps/mesa-native; release passes
#                      deps/mesa-native-release). Never silently clobbered — an
#                      unstamped, pre-existing driver is kept (see below).
#   MESA_PATCH_DIR     patches to apply after checkout (default patches/mesa)
#   MESA_FORCE_REBUILD=1  rebuild even if a driver is present
#
# Everything is checked with explicit artifact tests, not exit codes.
set -euo pipefail

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
case "$BAR" in *" "*) echo "FATAL: the checkout path contains a space, which the build flags and loops do not support: $BAR" >&2; exit 1;; esac
# Deployment target: the floor the shipped bundle declares (LSMinimumSystemVersion,
# packaging/release-build.sh). macOS 27.0 since 2026-11-08 (was 26.0, KosmicKrisp
# needs Metal 4). Without it clang defaults to the BUILD host's OS, so the floor
# silently follows whichever Mac built it. clang, swiftc, meson and cmake all read it.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
DEPS="$BAR/deps"
MESA_COMMIT="90a959ebba9dbb36f2ea5176091c15d6ebdd0af0"   # mesa-26.3.0-rc3 (was 8f272b1fe18e, 26.2.0-devel, 2026-06-13)
SPIRV_XLAT_TAG="v19.1.7"
SPIRV_XLAT_COMMIT="3fac86cf760a4a2510f3c1e76001ea799812a2f6"   # what that tag names
MESA_PREFIX="${MESA_PREFIX:-$DEPS/mesa-native}"           # driver install prefix
MESA_SRC="${MESA_SRC:-$DEPS/mesa-src}"
PATCH_DIR="${MESA_PATCH_DIR:-$BAR/patches/mesa}"
FORCE="${MESA_FORCE_REBUILD:-0}"
mkdir -p "$DEPS"
# Driver runtime deps from pinned source (Vulkan loader, SPIRV-Tools, zstd), built
# first: their provenance is part of the driver's stamp below.
DRIVER_DEPS="$("$BAR/scripts/build-driver-deps.sh")"

# ---- provenance: what driver SHOULD be at the prefix -----------------------
patch_list() { ls "$PATCH_DIR"/*.patch 2>/dev/null | sort; }
want_stamp() {
  echo "mesa_commit=$MESA_COMMIT"
  echo "spirv_xlat=$SPIRV_XLAT_TAG"
  echo "driver_deps=$(cat "$DEPS/driver-deps/.provenance" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  echo "macos_target=$MACOSX_DEPLOYMENT_TARGET"
  # the build recipe itself (meson options, link steps): this script without
  # its comment and blank lines, so a comment edit does not rebuild the driver
  echo "recipe=$(grep -v -E '^[[:space:]]*(#|$)' "$0" | shasum -a 256 | cut -d' ' -f1)"
  local p
  for p in $(patch_list); do
    echo "patch=$(basename "$p"):$(shasum -a 256 "$p" | cut -d' ' -f1)"
  done
  # recorded for transparency (not part of the cache key): the host toolchain
  echo "# llvm@19=$(brew list --versions llvm@19 2>/dev/null | tr ' ' '=' || echo unknown)"
}
STAMP_FILE="$MESA_PREFIX/.driver-provenance"
WANT="$(want_stamp)"
# cache key excludes the trailing '#'-comment (toolchain) line
key() { grep -v '^#'; }
NPATCH=$(patch_list | wc -l | tr -d ' ')

driver_present() { [ -f "$MESA_PREFIX/lib/libEGL.dylib" ] && [ -f "$MESA_PREFIX/lib/libvulkan_kosmickrisp.dylib" ]; }

# ---- idempotency: decide whether to (re)build ------------------------------
if driver_present && [ "$FORCE" != "1" ]; then
  if [ -f "$STAMP_FILE" ] && [ "$(key <"$STAMP_FILE")" = "$(printf '%s\n' "$WANT" | key)" ]; then
    echo "mesa driver up to date at $MESA_PREFIX ($MESA_COMMIT + $NPATCH patches) — skipping build"
    exit 0
  fi
  if [ ! -f "$STAMP_FILE" ]; then
    # a pre-existing hand-built driver (no stamp): do NOT clobber it silently
    # (deps/mesa-native may be a perf-experiment build), and do NOT claim a
    # provenance we did not establish — just use it and warn. A from-source
    # (re)build stamps it; force one with MESA_FORCE_REBUILD=1.
    echo "WARN: driver present at $MESA_PREFIX with no provenance stamp — using it, NOT rebuilding."
    echo "      Its exact provenance is unverified; MESA_FORCE_REBUILD=1 rebuilds from the pinned source."
    exit 0
  fi
  echo "mesa driver at $MESA_PREFIX is stale (pin/patches changed) — rebuilding from pinned source"
fi

echo "=== [1/4] Homebrew dependencies ==="
# Engine deps + Mesa build deps. Individually so one failure doesn't kill the rest.
# cmake/ninja: SPIRV-LLVM-Translator below and the engine build. gcc@15:
# gcc-dbl64-swap.sh. coreutils: gtimeout for build-engine.sh's libm gate.
for pkg in sdl2 libpng libjpeg-turbo libogg libvorbis freetype glm libomp \
           vulkan-headers vulkan-loader molten-vk devil ccache \
           meson pkg-config bison flex llvm@19 libclc glslang spirv-tools \
           p7zip openal-soft minizip cmake ninja gcc@15 coreutils; do
  brew list "$pkg" &>/dev/null || brew install "$pkg" || echo "WARN: brew install $pkg failed"
done

L19="$(brew --prefix llvm@19)"
test -d "$L19" || { echo "FATAL: llvm@19 missing"; exit 1; }

echo "=== [2/4] SPIRV-LLVM-Translator $SPIRV_XLAT_TAG (LLVM 19) ==="
if [ ! -f "$DEPS/spirv-xlat-install/lib/pkgconfig/LLVMSPIRVLib.pc" ]; then
  rm -rf "$DEPS/spirv-xlat"
  git clone --depth 1 --branch "$SPIRV_XLAT_TAG" \
    https://github.com/KhronosGroup/SPIRV-LLVM-Translator.git "$DEPS/spirv-xlat"
  # a tag can be moved: build only the commit this script was written against
  got=$(git -C "$DEPS/spirv-xlat" rev-parse HEAD)
  [ "$got" = "$SPIRV_XLAT_COMMIT" ] || {
    echo "FATAL: SPIRV-LLVM-Translator $SPIRV_XLAT_TAG is at $got, expected $SPIRV_XLAT_COMMIT"; exit 1; }
  cmake -S "$DEPS/spirv-xlat" -B "$DEPS/spirv-xlat/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS/spirv-xlat-install" \
    -DLLVM_DIR="$L19/lib/cmake/llvm" \
    -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-lto_library,$L19/lib/libLTO.dylib -L/opt/homebrew/lib" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-lto_library,$L19/lib/libLTO.dylib -L/opt/homebrew/lib"
  ninja -C "$DEPS/spirv-xlat/build" install
fi
test -f "$DEPS/spirv-xlat-install/lib/pkgconfig/LLVMSPIRVLib.pc" || { echo "FATAL: spirv-xlat install missing"; exit 1; }
echo "spirv-xlat OK"

# libclc for the pinned Mesa: Homebrew's libclc 23+ no longer ships libclc.pc
# or the spirv*-mesa3d- targets; build-libclc.sh builds LLVM 19's libclc when
# needed and prints its pkg-config dir (empty when Homebrew's still works).
CLC_PC="$("$BAR/scripts/build-libclc.sh")"
[ -n "$CLC_PC" ] && echo "libclc: $CLC_PC" || echo "libclc: Homebrew"

echo "=== [3/4] Mesa (zink + kosmickrisp) @ $MESA_COMMIT + $NPATCH patches ==="
if [ ! -d "$MESA_SRC/.git" ]; then
  git clone https://gitlab.freedesktop.org/mesa/mesa.git "$MESA_SRC"
fi
cd "$MESA_SRC"
# Land on the EXACT pinned commit; deepen if a shallow clone lacks it.
if ! git cat-file -e "${MESA_COMMIT}^{commit}" 2>/dev/null; then
  git fetch origin "$MESA_COMMIT" 2>/dev/null || \
  git fetch --unshallow origin 2>/dev/null || \
  git fetch origin 2>/dev/null || true
fi
# Reproducibility: a non-pinned driver is NOT acceptable — hard-fail, never fall back to HEAD.
git cat-file -e "${MESA_COMMIT}^{commit}" 2>/dev/null || {
  echo "FATAL: pinned mesa commit $MESA_COMMIT is unreachable; refusing to build a non-pinned driver."
  echo "       Check network / that the commit still exists on gitlab.freedesktop.org/mesa/mesa."
  exit 1
}
git checkout -f "$MESA_COMMIT"
git clean -fd   # drop previously-applied patches / stray files (ignored build dirs kept for ccache)
echo "mesa: pinned commit $MESA_COMMIT checked out; version $(cat VERSION)"
for p in $(patch_list); do
  echo "  applying $(basename "$p")"
  git apply --whitespace=nowarn "$p" || { echo "FATAL: patch $(basename "$p") did not apply to $MESA_COMMIT"; exit 1; }
done

python3 -m venv "$DEPS/mesa-venv"
# pinned versions with their published hashes: Mako generates C that is compiled
# into the driver
"$DEPS/mesa-venv/bin/pip" install --quiet --require-hashes -r "$BAR/scripts/mesa-venv-requirements.txt"

# Reproducibility: strip the absolute build-root prefix ($BAR, which
# contains deps/mesa-src) out of every embedded __FILE__ and DWARF debug path so
# the shipped driver dylibs embed no absolute build path. Maps
# $BAR -> "." for preprocessor (-ffile-prefix-map) and debug info
# (-fdebug-prefix-map), across C / C++ / Obj-C / Obj-C++. Path-string only.
# Link search: driver-deps (static zstd, SPIRV-Tools) only. Homebrew's static LLVM
# asks for -lzstd -lxml2 -lz; with -L/opt/homebrew/lib here -lzstd resolved to
# Homebrew's dylib. libxml2 and libz come from the macOS SDK.
cat > "$DEPS/plain-native.ini" <<INI
[binaries]
c = '/usr/bin/clang'
cpp = '/usr/bin/clang++'
objc = '/usr/bin/clang'
objcpp = '/usr/bin/clang++'

[built-in options]
c_args = ['-ffile-prefix-map=$BAR=.','-fdebug-prefix-map=$BAR=.']
cpp_args = ['-ffile-prefix-map=$BAR=.','-fdebug-prefix-map=$BAR=.']
objc_args = ['-ffile-prefix-map=$BAR=.','-fdebug-prefix-map=$BAR=.']
objcpp_args = ['-ffile-prefix-map=$BAR=.','-fdebug-prefix-map=$BAR=.']
c_link_args = ['-Wl,-lto_library,$L19/lib/libLTO.dylib','-L$DRIVER_DEPS/lib']
cpp_link_args = ['-Wl,-lto_library,$L19/lib/libLTO.dylib','-L$DRIVER_DEPS/lib']
objc_link_args = ['-Wl,-lto_library,$L19/lib/libLTO.dylib','-L$DRIVER_DEPS/lib']
objcpp_link_args = ['-Wl,-lto_library,$L19/lib/libLTO.dylib','-L$DRIVER_DEPS/lib']
INI

source "$DEPS/mesa-venv/bin/activate"
export PATH="$L19/bin:$DEPS/mesa-venv/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$PATH"
export LIBRARY_PATH="/opt/homebrew/lib"
# Mesa compiles its *install prefix* into the driver (SYSCONFDIR/DATADIR, used
# to locate drirc at runtime). The -ffile-prefix-map/-fdebug-prefix-map flags
# set above remap SOURCE paths only and do not touch it, so building straight
# into a $HOME-based prefix embeds the builder's username in libEGL,
# libgallium and libvulkan_kosmickrisp -- which is how v0.12 shipped
# /Users/<builder>/... inside notarized, publicly downloadable dylibs.
# Build against a neutral prefix and relocate at install time.
# Install names are rewritten to @rpath by packaging/release-build.sh either
# way, so the neutral prefix costs nothing at link time.
NEUTRAL_PREFIX="/opt/bar-driver"
STAGE="$DEPS/mesa-stage"

rm -rf build-native "$STAGE"
meson setup build-native --native-file "$DEPS/plain-native.ini" \
  --pkg-config-path "$DRIVER_DEPS/lib/pkgconfig,$DEPS/spirv-xlat-install/lib/pkgconfig${CLC_PC:+,$CLC_PC}" \
  --cmake-prefix-path "$DRIVER_DEPS" \
  -Dprefix="$NEUTRAL_PREFIX" -Dplatforms=macos \
  -Degl-native-platform=surfaceless -Degl=enabled -Dglx=disabled \
  -Dgallium-drivers=zink -Dvulkan-drivers=kosmickrisp \
  -Dmoltenvk-dir=/opt/homebrew/opt/molten-vk \
  -Dllvm=enabled -Dshared-llvm=disabled -Dbuildtype=release \
  -Dprefer_static=true  # take driver-deps' static zstd/SPIRV-Tools, never a Homebrew dylib
DESTDIR="$STAGE" ninja -C build-native install

# relocate the neutral prefix tree into the real install location
test -d "$STAGE$NEUTRAL_PREFIX" || { echo "FATAL: staged install missing $STAGE$NEUTRAL_PREFIX"; exit 1; }
# replace, never overlay: a previous version's libgallium-<ver>.dylib would
# otherwise stay beside the new one and be bundled too
rm -rf "$MESA_PREFIX"
mkdir -p "$MESA_PREFIX"
(cd "$STAGE$NEUTRAL_PREFIX" && tar cf - .) | (cd "$MESA_PREFIX" && tar xf -)
rm -rf "$STAGE"

# meson baked the neutral prefix into each dylib's install name (LC_ID_DYLIB)
# and into its inter-library dependencies. /opt/bar-driver does not exist on
# this machine, so unless these are repointed nothing OUTSIDE a bundle can load
# the driver — visreg, perf-bench, run-spring.sh and the certify replay all run
# the raw binary against $MESA_PREFIX. packaging/release-build.sh rewrites these
# to @rpath when it stages the .app, and its builder-path audit scans the
# resulting bundle, so the absolute path used here never reaches a shipped
# artifact.
for d in "$MESA_PREFIX"/lib/*.dylib; do
  [ -L "$d" ] && continue
  chmod u+w "$d"
  install_name_tool -id "$MESA_PREFIX/lib/$(basename "$d")" "$d" 2>/dev/null || true
  for dep in $(otool -L "$d" | tail -n +2 | awk '{print $1}' | grep "^$NEUTRAL_PREFIX/" || true); do
    install_name_tool -change "$dep" "$MESA_PREFIX/lib/$(basename "$dep")" "$d" 2>/dev/null || true
  done
done
echo "install names repointed from $NEUTRAL_PREFIX to $MESA_PREFIX"

# The ICD json's library_path is absolute and now names the neutral prefix,
# which does not exist. Repoint it at the real install location so non-bundled
# runs (visreg, perf-bench, run-spring.sh) can still load the driver; packaging
# rewrites this to a bundle-relative path when it stages the .app, so nothing
# absolute reaches a shipped artifact.
for j in "$MESA_PREFIX"/share/vulkan/icd.d/*.json; do
  [ -f "$j" ] || continue
  sed -i '' "s|\"library_path\": \".*\"|\"library_path\": \"$MESA_PREFIX/lib/libvulkan_kosmickrisp.dylib\"|" "$j"
done

echo "=== [4/4] Artifact verification ==="
test -f "$MESA_PREFIX/lib/libEGL.dylib" || { echo "FATAL: libEGL.dylib missing"; exit 1; }
test -f "$MESA_PREFIX/lib/libvulkan_kosmickrisp.dylib" || { echo "FATAL: kosmickrisp missing"; exit 1; }
file "$MESA_PREFIX/lib/libEGL.dylib" | grep -q arm64 || { echo "FATAL: libEGL not arm64"; exit 1; }
ls "$MESA_PREFIX/lib/"*.dylib
ls "$MESA_PREFIX/share/vulkan/icd.d/" 2>/dev/null || true

# A hygiene claim about a binary must be verified BY GREPPING THE
# BINARY, never inferred from the compiler flags. Any absolute /Users/ path
# compiled into a driver dylib is a leak the moment the bundle is notarized.
# NB: raw byte grep, not `strings` — `strings` reads only the text section and
# silently misses debug-map/symbol-table paths.
# /Users/ alone misses a checkout anywhere else, so this build's own roots are
# searched for as well.
LEAK_RE='/Users/'
for root in "$BAR" "$(cd "$BAR" && pwd -P)" "$HOME"; do
  [ "${#root}" -ge 4 ] || continue
  LEAK_RE="$LEAK_RE|$(printf '%s' "$root" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
done
leaks=0
for d in "$MESA_PREFIX"/lib/*.dylib; do
  # LC_ALL=C on sort too: in a UTF-8 locale sort aborts on the raw bytes grep
  # captures ("Illegal byte sequence") and the scan silently sees nothing.
  # Skip "$MESA_PREFIX/lib/..." strings: those are the install names repointed
  # above, which release-build.sh rewrites to @rpath and audits in the bundle.
  hits="$(LC_ALL=C grep -a -o -E "($LEAK_RE)[^ \"]{0,120}" "$d" 2>/dev/null | LC_ALL=C sort -u \
          | LC_ALL=C grep -v -F "$MESA_PREFIX/lib/" || true)"
  [ -z "$hits" ] || { n=$(echo "$hits" | wc -l | tr -d ' '); echo "FATAL: $(basename "$d") embeds $n builder path(s):"; echo "$hits" | head -5 | sed 's/^/    /'; leaks=$((leaks+n)); }
done
# The driver must load on the declared floor: fail if any dylib's minos is above it.
for d in "$MESA_PREFIX"/lib/*.dylib; do
  [ -L "$d" ] && continue
  m=$(vtool -show-build "$d" 2>/dev/null | awk '/minos/{print $2; exit}')
  [ "$m" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "FATAL: $(basename "$d") minos $m, want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
done
echo "driver deployment target: all dylibs minos $MACOSX_DEPLOYMENT_TARGET"
[ "$leaks" -eq 0 ] || { echo "FATAL: driver embeds $leaks builder-path string(s)"; exit 1; }
echo "driver path-leak scan: 0 /Users/ strings across $(ls "$MESA_PREFIX"/lib/*.dylib | wc -l | tr -d ' ') dylibs"

# stamp the provenance so subsequent builds are a no-op until the pin/patches change
printf '%s\n' "$WANT" > "$STAMP_FILE"
echo "driver provenance stamped: $STAMP_FILE"
echo "MESA_KK_STACK_OK"
