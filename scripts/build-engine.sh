#!/bin/bash
# Build the Recoil engine with the macOS layer against the local Mesa
# KosmicKrisp stack. Targets, tests and variables: docs/BUILDING.md.
#
# Usage: build-engine.sh [--with-synctest] [--with-visreg]
#
# Tests are OPT-IN (the build itself always runs its fast artifact gates:
# libm parity hashes, arch checks). Run tests with the build for major
# changes / large commits, or standalone at any time:
#   --with-synctest  streflop cross-arch bit-exactness (~seconds, CPU-only)
#                    standalone: scripts/run-synctest.sh
#   --with-visreg    visual regression vs baselines (~2 min), on the last built
#                    app bundle. standalone: scripts/visreg.sh
# Env equivalents: WITH_SYNCTEST=1 WITH_VISREG=1.
set -euo pipefail

WITH_SYNCTEST="${WITH_SYNCTEST:-0}"
WITH_VISREG="${WITH_VISREG:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --with-synctest) WITH_SYNCTEST=1; shift;;
    --with-visreg)   WITH_VISREG=1; shift;;
    --with-perf)     echo "--with-perf: there is no perf gate yet (scripts/visreg.sh has none)"; exit 2;;
    *) echo "unknown arg: $1 (see header for usage)"; exit 2;;
  esac
done

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
case "$BAR" in *" "*) echo "FATAL: the checkout path contains a space, which the build flags and loops do not support: $BAR" >&2; exit 1;; esac
# Deployment target: see build-mesa-kk.sh. Exported before build-mesa-kk.sh runs so
# the driver and the engine always agree.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-27.0}"
DEPS="$BAR/deps"
SRC="${ENGINE_SRC:-$([ -d "$BAR/rts" ] && echo "$BAR" || echo "$BAR/engine")}"
BUILD="${ENGINE_BUILD:-$BAR/build-engine}"

# MESA_PREFIX: which driver install the engine links against (absolute
# install-name — the binary is bound to THIS prefix's libEGL at runtime;
# release bundles rewrite it to @rpath at staging).
[ -n "${MESA_PREFIX:-}" ] && MESA_PREFIX_EXPLICIT=1 || MESA_PREFIX_EXPLICIT=""
MESA_PREFIX="${MESA_PREFIX:-$DEPS/mesa-native}"
MESA_LIBEGL="$MESA_PREFIX/lib/libEGL.dylib"
# Ensure the graphics driver exists before building — so a single command builds
# the whole stack. build-mesa-kk.sh is a no-op when the driver is already current
# (provenance stamp), and never clobbers an unstamped pre-existing driver.
MESA_PREFIX="$MESA_PREFIX" "$BAR/scripts/build-mesa-kk.sh"
test -f "$MESA_LIBEGL" || { echo "FATAL: no libEGL under $MESA_PREFIX after build-mesa-kk.sh"; exit 1; }
export CPATH="$MESA_PREFIX/include${CPATH:+:$CPATH}"


# Reproducibility: strip the absolute build-root prefix out of every
# embedded __FILE__ string (assert/log macros) and DWARF debug path, so the
# shipped binaries embed no absolute build path. Maps $BAR -> "."
# for both preprocessor (__FILE__, via -ffile-prefix-map) and debug info
# (-fdebug-prefix-map). Applied to all languages incl. Obj-C/Obj-C++ (macOS .mm)
# and inherited by subprojects (streflop, pr-downloader). Path-string only — no
# effect on codegen or determinism.
PREFIX_MAP="-ffile-prefix-map=$BAR=. -fdebug-prefix-map=$BAR=."
# The pr-downloader subproject deliberately wipes CMAKE_CXX_FLAGS/CMAKE_C_FLAGS
# (tools/CMakeLists.txt) so it does NOT inherit engine flags — that also drops
# PREFIX_MAP, leaving ~17 absolute source paths embedded in pr-downloader (and,
# since spring links it, in spring too). It force-builds RelWithDebInfo and does
# NOT clear the per-config *_RELWITHDEBINFO flags, so carrying PREFIX_MAP there
# too reaches pr-downloader. Both the engine and pr-downloader build
# RELWITHDEBINFO, so this is belt-and-suspenders (harmless if applied twice).

# SOURCE-TREE GUARD (2026-08-07). `cmake --fresh` silently RE-POINTS an existing
# build dir at whatever -S it is handed, and SRC defaults to $BAR/engine — so
# running this script without ENGINE_SRC against a build dir that was configured
# from a DIFFERENT tree (e.g. build-engine-2025.06.24-perfpin <- engine-2025.06.24)
# quietly rebases it onto the stale tree. Burned once: the perf-pin build was
# re-pointed at the July `engine/` tree, the edited file never recompiled (right
# edit, wrong tree), and the failure surfaced as an unrelated BARb compile error
# that sent the diagnosis off in the wrong direction entirely. Refuse instead.
if [ -f "$BUILD/CMakeCache.txt" ]; then
  PREV_SRC=$(awk -F= '/^CMAKE_HOME_DIRECTORY:INTERNAL=/{print $2}' "$BUILD/CMakeCache.txt")
  if [ -n "$PREV_SRC" ] && [ "$PREV_SRC" != "$SRC" ]; then
    if [ "${ENGINE_ALLOW_SRC_SWITCH:-0}" = 1 ]; then
      echo "WARNING: re-pointing $BUILD from $PREV_SRC to $SRC (ENGINE_ALLOW_SRC_SWITCH=1)"
    else
      echo "FATAL: $BUILD was configured from a DIFFERENT source tree."
      echo "  build dir was configured from: $PREV_SRC"
      echo "  this invocation would use:     $SRC"
      echo "  Building anyway would compile the WRONG TREE and silently ignore your edits."
      echo "  Fix: ENGINE_SRC=$PREV_SRC $0 $*"
      echo "  Or, if the switch is intended: ENGINE_ALLOW_SRC_SWITCH=1 $0 $*"
      exit 1
    fi
  fi
fi

# Third-party libraries, resolved the way upstream's Linux release resolves them
# (docker-build-v2/images/all-linux/Dockerfile): the spring-static-libs set built
# static (build-static-libs.sh: zlib, png, gif, jpeg, tiff, DevIL, ogg, vorbis, xz,
# minizip-ng), PREFER_STATIC_LIBS, and pkg-config confined to our prefixes. What
# Linux takes from the OS (freetype, fontconfig, OpenAL, SDL2) is built from pinned
# source as dylibs (build-shared-libs.sh, build-sdl2.sh). Homebrew prefixes are
# ignored entirely, so nothing a bottle happens to contain can reach the engine.
STATIC_PREFIX="$("$BAR/scripts/build-static-libs.sh")"
SHARED_PREFIX="$("$BAR/scripts/build-shared-libs.sh")"
SDL2_PREFIX="$("$BAR/scripts/build-sdl2.sh")"
echo "static libs: $STATIC_PREFIX"; echo "shared libs: $SHARED_PREFIX"; echo "SDL2: $SDL2_PREFIX"
export PREFER_STATIC_LIBS=TRUE
export PKG_CONFIG="pkg-config --static"
export PKG_CONFIG_LIBDIR="$STATIC_PREFIX/lib/pkgconfig:$SHARED_PREFIX/lib/pkgconfig:$SDL2_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH
CMAKE_EXTRA=(
  -DCMAKE_PREFIX_PATH="$STATIC_PREFIX;$SHARED_PREFIX;$SDL2_PREFIX"
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
  -DPREFER_STATIC_LIBS=TRUE
)

# VERSION-TAG GUARD. ConfigureVersion.cmake derives the reported engine version
# (which must match the autohosts) from the nearest numeric release tag. A clone
# of this port's GitHub repo carries none of Recoil's release tags, so cmake dies
# deep in configure with "Invalid version format: <sha> main". Fail here instead,
# with the fix.
if [ -d "$SRC/.git" ] || [ -f "$SRC/.git" ]; then
  if ! git -C "$SRC" describe --tags --abbrev=0 --match '[0-9]*' >/dev/null 2>&1; then
    echo "FATAL: no Recoil release tag (e.g. 2026.07.04) reachable from HEAD in $SRC."
    echo "  This port's repo does not carry upstream tags. Fetch them once:"
    echo "  git -C \"$SRC\" fetch --no-recurse-submodules https://github.com/beyond-all-reason/RecoilEngine.git 'refs/tags/*:refs/tags/*'"
    exit 1
  fi
fi

# Mark the build: the full version string ("2026.09.02 (macOS port 0.13)",
# shown by --version, in the log and to Lua as Engine.versionFull) says this
# is not the official release. The sync version, which demos, saves and the
# network compare, stays the bare release tag.
PORT_MARK="macOS port ${ENGINE_PORT_VERSION:-$(tr -d '[:space:]' < "$BAR/packaging/PORT_VERSION")}"
cmake --fresh -S "$SRC" -B "$BUILD" -G Ninja \
  ${CMAKE_EXTRA[@]+"${CMAKE_EXTRA[@]}"} \
  -DCMAKE_BUILD_TYPE=RELWITHDEBINFO \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O3 -g -DNDEBUG $PREFIX_MAP" \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O3 -g -DNDEBUG $PREFIX_MAP" \
  -DCMAKE_C_FLAGS="$PREFIX_MAP" \
  -DCMAKE_CXX_FLAGS="$PREFIX_MAP" \
  -DCMAKE_OBJC_FLAGS="$PREFIX_MAP" \
  -DCMAKE_OBJCXX_FLAGS="$PREFIX_MAP" \
  -DAI_TYPES="${AI_TYPES:-NATIVE}" -DAI_EXCLUDE_REGEX="CppTestAI" \
  -DUSERDOCS_PLAIN=ON \
  -DVERSION_ADDITIONAL="$PORT_MARK" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache \
  -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache \
  -DSPRING_MAC_LIBEGL="$MESA_LIBEGL" \
  -DOPENAL_SOFT_PREFIX="$SHARED_PREFIX"

NINJA_TARGETS=(spring spring-headless spring-dedicated unitsync pr-downloader_cli basecontent)
if [ "${AI_TYPES:-NATIVE}" != "NONE" ]; then
  # BARb (CircuitAI-based) + CircuitAI + NullAI + the C interface. BAR uses only
  # BARb; CircuitAI ships in the engine-only distribution like the official 7z.
  NINJA_TARGETS+=("AI/Interfaces/C/all" "AI/Skirmish/BARb/all" "AI/Skirmish/CircuitAI/all" "AI/Skirmish/NullAI/all")
fi
ninja -C "$BUILD" -j"$(sysctl -n hw.ncpu)" "${NINJA_TARGETS[@]}"

if [ "${AI_TYPES:-NATIVE}" != "NONE" ]; then
  # Assemble the runtime AI tree the engine scans (AI/<kind>/<name>/<version>/
  # with the info .lua files beside the dylib). Build outputs land in
  # .../<name>/data/ which the engine ignores (no AIInfo.lua there).
  rm -rf "$BUILD/AI/Interfaces/C/0.1" "$BUILD/AI/Skirmish/BARb/stable" "$BUILD/AI/Skirmish/CircuitAI/stable" "$BUILD/AI/Skirmish/NullAI/0.1"
  mkdir -p "$BUILD/AI/Interfaces/C/0.1" "$BUILD/AI/Skirmish/BARb/stable" "$BUILD/AI/Skirmish/CircuitAI/stable" "$BUILD/AI/Skirmish/NullAI/0.1"
  cp -R "$SRC/AI/Interfaces/C/data/." "$BUILD/AI/Interfaces/C/0.1/"
  cp "$BUILD/AI/Interfaces/C/data/libAIInterface.dylib" "$BUILD/AI/Interfaces/C/0.1/"
  cp -R "$SRC/AI/Skirmish/BARb/data/." "$BUILD/AI/Skirmish/BARb/stable/"
  cp "$BUILD/AI/Skirmish/BARb/data/libSkirmishAI.dylib" "$BUILD/AI/Skirmish/BARb/stable/"
  cp -R "$SRC/AI/Skirmish/CircuitAI/data/." "$BUILD/AI/Skirmish/CircuitAI/stable/"
  cp "$BUILD/AI/Skirmish/CircuitAI/data/libSkirmishAI.dylib" "$BUILD/AI/Skirmish/CircuitAI/stable/"
  cp -R "$SRC/AI/Skirmish/NullAI/data/." "$BUILD/AI/Skirmish/NullAI/0.1/"
  cp "$BUILD/AI/Skirmish/NullAI/data/libSkirmishAI.dylib" "$BUILD/AI/Skirmish/NullAI/0.1/"
fi

# Fleet parity is achieved differently per streflop lane:
#  - glibc-import lane (2025.06.24: dbl-64 is a compiled-in glibc 2.39 import,
#    marker file w_aliases.cpp): pure AppleClang is the certified shipping
#    configuration — NO object swap. (The old cross-lane swap replaced the
#    glibc __exp with a wrapper that infinite-loops via w_aliases; it shipped
#    unnoticed only because the sim never calls double exp. Do not reintroduce.)
#    Gate: dfp hashes vs this lane's committed baseline (drift detection) +
#    replay certification is the parity proof of record.
#  - submodule lane (2026.06.08+): fleet gcc builds use
#    -fsingle-precision-constant (gcc-only); recompile dbl-64 objects with
#    homebrew gcc and relink. Gate: every hash line matches the gcc x86 reference.
if [ -f "$SRC/rts/lib/streflop/libm/dbl-64/w_aliases.cpp" ]; then
  LANE=glibc-import
  REF="$BAR/testkit/libm-refs/double-fn-2025lane-clang.txt"
  echo "streflop lane: glibc-import (pure clang, no dbl-64 swap)"
else
  LANE=submodule
  REF="$BAR/testkit/libm-refs/double-fn-vm26.txt"
  "$BAR/scripts/gcc-dbl64-swap.sh" "$BUILD"
  for tgt in spring spring-headless; do
    LINK_CMD=$(cd "$BUILD" && ninja -t commands "$tgt" | tail -1)
    case "$LINK_CMD" in
      *" -o $tgt "*|*" -o $tgt") ;;
      *) echo "FATAL: cannot find the link step for $tgt, so it cannot be relinked against the gcc dbl-64 objects"; exit 1;;
    esac
    (cd "$BUILD" && eval "$LINK_CMD")
    # The gate below tests the archive. These two checks tie the binary that
    # ships to it: not older than the swapped archive, and any dbl-64 function
    # it links comes from the gcc-built objects (scripts/check-dbl64-marker.sh).
    [ "$BUILD/$tgt" -ot "$BUILD/rts/lib/streflop/libstreflop.a" ] \
      && { echo "FATAL: $tgt is older than the swapped streflop archive (the relink did not run)"; exit 1; }
    "$BAR/scripts/check-dbl64-marker.sh" "$BUILD/$tgt" || exit 1
  done
fi

# Verification gate: the archive must reproduce the lane's reference libm
# hashes; hard-fails the build otherwise.
# FAIL CLOSED. This used to be a bare `if [ -f "$REF" ]` with no else, and the
# references lived in gitignored logs/ — so on a fresh clone, a new machine, or
# after anyone cleaned logs/, the ONLY artifact-level FP-parity check silently
# vanished and the build still printed ENGINE_BUILD_OK. "The reference is
# missing" is not consent; it is the one condition under which this gate must
# shout. (Adversarial harness audit, 2026-08-07.)
for _req in "$REF" "$BAR/scripts/dfp-small.cpp"; do
  [ -f "$_req" ] || { echo "FATAL: libm parity gate cannot run — missing $_req"; \
                      echo "  (lane=$LANE) Refusing to report a build as good without it."; exit 2; }
done
if true; then
  # fastiroot shim is only needed (and only links) on trees whose streflop
  # exports streflop_libm::fastiroot (the 2026 lane); detect from the archive.
  SHIM=()
  if nm "$BUILD/rts/lib/streflop/libstreflop.a" 2>/dev/null | grep -q "fastiroot"; then
    SHIM=("$BAR/scripts/fastiroot_shim.cpp")
  fi
  clang++ -std=c++17 -O2 -DSTREFLOP_NEON -ffp-contract=off \
    -I"$SRC/rts/lib/streflop" "$BAR/scripts/dfp-small.cpp" \
    ${SHIM[@]+"${SHIM[@]}"} \
    "$BUILD/rts/lib/streflop/libstreflop.a" -o "$BUILD/dfp-verify"
  # bounded: a libm infinite loop (see the w_exp landmine above) must FAIL
  # the gate, not hang the build. Stock macOS has no timeout(1); Homebrew
  # coreutils (installed by build-mesa-kk.sh) provides it as gtimeout.
  TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) \
    || { echo "FATAL: neither timeout nor gtimeout found (brew install coreutils)"; exit 1; }
  "$TIMEOUT_BIN" 120 "$BUILD/dfp-verify" > "$BUILD/dfp-verify.txt" \
    || { echo "FATAL: dfp-verify crashed or hung (libm landmine?)"; exit 1; }
  # Every reference line must be reproduced exactly. The submodule lane's
  # reference covers every line the program prints; the glibc-import lane's
  # older baseline covers the first nine.
  REF_LINES=$(grep -c . "$REF"); OUT_LINES=$(grep -c . "$BUILD/dfp-verify.txt")
  if [ -n "$(grep -Fxv -f "$BUILD/dfp-verify.txt" "$REF")" ] \
     || { [ "$LANE" = submodule ] && [ "$REF_LINES" != "$OUT_LINES" ]; }; then
    echo "FATAL: streflop archive does not match $LANE lane libm hashes ($REF):"
    paste "$BUILD/dfp-verify.txt" "$REF"
    exit 1
  fi
  echo "libm parity gate ($LANE): OK ($REF_LINES/$REF_LINES hash match vs $(basename "$REF"))"
fi
echo "NOTE: do not run bare 'ninja' in $BUILD afterwards — it clobbers the"
echo "gcc-swapped dbl-64 objects. Always rebuild via this script."

# Stage the SAME loose cont/ files packaging/release-build.sh puts in the bundle's
# Resources, so the tree the gates run against matches what players actually get.
# This tree used to be RICHER than the product: cmake wrote a SpringData line
# pointing at a second datadir (<srcdir>/cont), which is how ctrlpanel.txt was
# reaching the engine here but not in the bundle -- so visreg could not see the
# missing-ctrlpanel bug. That path is now stale anyway (it names engine-<lane>/cont,
# renamed to engine/ in the 2026-08-07 lane move) and cont/CMakeLists.txt will not
# regenerate an existing springsettings.cfg. Staging explicitly is the honest fix:
# if the bundle stops shipping a file, the gate stops seeing it too.
mkdir -p "$BUILD/LuaUI"
cp "$SRC/cont/LuaUI/ctrlpanel.txt" "$BUILD/LuaUI/ctrlpanel.txt"

echo "=== artifact verification ==="
for b in spring spring-headless; do
  test -f "$BUILD/$b" || { echo "FATAL: $b missing"; exit 1; }
  file "$BUILD/$b" | grep -q arm64 || { echo "FATAL: $b not arm64"; exit 1; }
  m=$(vtool -show-build "$BUILD/$b" | awk '/minos/{print $2; exit}')
  [ "$m" = "$MACOSX_DEPLOYMENT_TARGET" ] || { echo "FATAL: $b minos $m, want $MACOSX_DEPLOYMENT_TARGET"; exit 1; }
done
file "$BUILD/tools/pr-downloader/src/pr-downloader"
echo "--- spring links:"
otool -L "$BUILD/spring" | head -25
ls "$BUILD"/*.sdz 2>/dev/null || ls "$BUILD"/base/*.sdz 2>/dev/null || find "$BUILD" -name "*.sdz" | head
echo "ENGINE_BUILD_OK"

# ---- opt-in test stages (see header) ------------------------------------------
if [ "$WITH_SYNCTEST" = "1" ]; then
  echo "=== opt-in: sync-test"
  ENGINE_SRC="$SRC" "$BAR/scripts/run-synctest.sh"
fi
if [ "$WITH_VISREG" = "1" ]; then
  # visreg plays an app bundle (default: the last 'make app'), not this build
  # directory: the bare engine cannot load the bundled Vulkan loader. So this
  # checks whatever bundle is there; release-build.sh --with-visreg is the one
  # that checks the bundle it has just built.
  echo "=== opt-in: visreg (on the last built app bundle)"
  "$BAR/scripts/visreg.sh"
fi
