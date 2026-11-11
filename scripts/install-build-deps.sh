#!/bin/bash
# Install the Homebrew build tools the macOS build needs, before anything is
# built. Runs first in build-engine.sh (so first in `make app`), and again in
# build-mesa-kk.sh when that script is run on its own. Installs only what is
# missing, so a second run takes a second or two.
#
# The libraries the app ships are NOT here: SDL2, libpng, libjpeg-turbo,
# libogg, libvorbis, FreeType, DevIL, OpenAL Soft and minizip are built from
# pinned source (build-static-libs.sh, build-shared-libs.sh, build-sdl2.sh).
# The list was checked on a Mac with no Homebrew packages installed (acu-053).
#
# Usage: scripts/install-build-deps.sh
set -uo pipefail
command -v brew >/dev/null || { echo "FATAL: Homebrew not found (https://brew.sh)"; exit 1; }

# cmake, ninja: every source build here. meson, pkg-config, bison, flex,
# llvm@19, libclc, glslang, spirv-tools: the Mesa driver build. vulkan-headers,
# vulkan-loader, molten-vk: Mesa's build-time lookups. glm, libomp: the
# engine build. ccache: optional compile cache. p7zip: content archives.
# gcc@15: scripts/gcc-dbl64-swap.sh. coreutils: gtimeout for the libm gate.
PKGS="cmake ninja meson pkg-config bison flex llvm@19 libclc glslang spirv-tools
      vulkan-headers vulkan-loader molten-vk glm libomp ccache p7zip gcc@15 coreutils"

missing=()
for pkg in $PKGS; do
  brew list --formula "$pkg" &>/dev/null || missing+=("$pkg")
done
[ ${#missing[@]} -eq 0 ] && { echo "build tools: all present"; exit 0; }
echo "=== Homebrew build tools: installing ${missing[*]}"
# individually, so one failure does not stop the rest
for pkg in "${missing[@]}"; do
  brew install "$pkg" || echo "WARN: brew install $pkg failed"
done
for t in cmake ninja meson; do
  command -v "$t" >/dev/null || { echo "FATAL: $t still missing after the install"; exit 1; }
done
