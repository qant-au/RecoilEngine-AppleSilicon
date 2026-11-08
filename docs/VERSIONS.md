# Pinned versions

Everything the macOS build depends on, what it is pinned to, and why. Keep this in
step with the scripts that enforce it; a pin written here and not enforced in a
script is a wish, not a pin.

| Component | Pin | Why | Enforced by |
|---|---|---|---|
| Engine | upstream Recoil release tag **2026.07.04** + this repository's macOS layer | The engine BAR's production servers run (BYAR-Chobby `dist_cfg/config.json`, `manual-linux`/`manual-win`). A client on any other version cannot join. BAR's test-engine channel is on 2026.09.02; rebase only when production moves (`docs/MAINTENANCE.md`) | `rts/build/cmake/ConfigureVersion.cmake` (nearest numeric tag); `scripts/build-engine.sh` refuses to build without upstream tags |
| streflop libm lane | "submodule" lane: dbl-64 objects recompiled with gcc and swapped in | Fleet builds use gcc's `-fsingle-precision-constant`, which clang lacks | `scripts/gcc-dbl64-swap.sh`; libm parity gate (9/9 vs `testkit/libm-refs/double-fn-vm26.txt`) in `scripts/build-engine.sh` |
| gcc (libm swap only) | Homebrew **`gcc@15`** (`/opt/homebrew/bin/g++-15`) | The fleet reference hashes were generated with gcc 15; Homebrew's `gcc` is now 16 | `scripts/gcc-dbl64-swap.sh` (fails naming gcc@15); installed by `scripts/build-mesa-kk.sh` |
| Mesa driver | `8f272b1fe18e95366386a075f2df0db4e9ea78b9` (26.2.0-devel, 2026-06-13) + the 13 `patches/mesa/*.patch` | The Zink + KosmicKrisp stack the bundle ships, built from pinned upstream source | `scripts/build-mesa-kk.sh` provenance stamp (commit, patch hashes, SPIRV tag, macOS target) |
| SPIRV-LLVM-Translator | `v19.1.7` | Matched to `llvm@19` for Mesa's CLC step | `scripts/build-mesa-kk.sh` |
| LLVM (Mesa build only) | Homebrew `llvm@19` | Later LLVM cannot link Mesa's KosmicKrisp CLC step | `scripts/build-mesa-kk.sh` |
| libclc | Homebrew's when it serves the pinned Mesa, else built from LLVM 19.1.7 | Homebrew libclc 23 ships no `libclc.pc` and no mesa3d targets | `scripts/build-libclc.sh` |
| SDL2 | **2.32.10**, built from the release tarball (sha256-pinned) | Homebrew's `sdl2` is now `sdl2-compat`, an SDL2 shim over SDL3 that `dlopen()`s SDL3 at runtime: the bundle would ship without SDL3 and fail to start, and the windowing/input backend would change underneath the port's SDL workarounds. 2.32.10 is what v0.13 shipped | `scripts/build-sdl2.sh` |
| minizip | zlib **1.4** `contrib/minizip`, built from the sha256-pinned tarball against the SDK's libz | Homebrew's bottle is built for the macOS it was bottled on (minos 27.2, above the floor) | `scripts/build-minizip.sh` |
| OpenAL | Homebrew `openal-soft` | Apple's OpenAL.framework lacks alext/efx | bundle deployment-target audit (`packaging/release-build.sh`) |
| Other bundled libraries | Homebrew bottles (freetype, fontconfig, DevIL and its codecs, ogg/vorbis, Vulkan loader, SPIRV-Tools) | Not yet built from source | bundle deployment-target audit: fails if any bundled Mach-O requires a newer macOS than the floor |
| pr-downloader | ExaDev fork submodule `e6510b3d` | macOS HTTP/1.1 fix for the BAR CDN; one commit off upstream Recoil's pin | `.gitmodules` |
| BARb (skirmish AI) | `qant-au/CircuitAI` branch `macos-arm64` at `7b9339da79` | arm64 build fixes; forked from the original port's `benbreen/CircuitAI` | `.gitmodules` |
| macOS floor | **27.0** (since 2026-11-08; was 26.0) | KosmicKrisp needs Metal 4 (26.0+); raised to 27.0 by maintainer decision | `MACOSX_DEPLOYMENT_TARGET` in `scripts/build-*.sh` and `packaging/release-build.sh` (also `LSMinimumSystemVersion`); engine, driver and bundle builds fail on any other `minos` |
