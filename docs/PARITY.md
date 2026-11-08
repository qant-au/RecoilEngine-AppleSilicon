# Parity with the official Windows and Linux builds

This is the authoritative record of how close the macOS build of this repository is
to the official Recoil builds that Beyond All Reason ships for Windows and Linux.
Every row is measured, dated and re-checkable with the command beside it; where the
two differ, the difference is either forced by the platform and stated, or open and
linked to the work that closes it.

**Measured: 2026-11-08**, macOS 27.2 on an M3 Ultra, engine `2026.07.04`.
Update the date and the evidence column whenever a row is re-measured; a row that
has not been re-checked after a change to the thing it measures is stale.

## What "1:1" means here

1. **Same engine.** The same upstream release tag the BAR fleet runs, plus a
   reviewable macOS layer; nothing in the simulation differs.
2. **Same simulation, bit for bit.** A game recorded on Windows or Linux replays on
   macOS with every per-frame sync checksum equal, and macOS clients can share a
   live game with them.
3. **Same libraries where they affect what the player sees or hears**: image and
   archive decoding, audio decoding, fonts. Where Linux takes a library from the OS,
   macOS builds the same library from pinned source.
4. **Same features**: everything a Windows or Linux player can do from the BAR app
   and lobby works on macOS.
5. **Differences only where macOS forces them**, each stated in the table below.

## Status

| Area | Windows / Linux (official) | macOS (this repository) | Status | Evidence / re-check |
|---|---|---|---|---|
| Engine version | upstream tag `2026.07.04` (BAR production) | same tag + macOS layer | **match** | `build-engine/spring --version`; production engine in BYAR-Chobby `dist_cfg/config.json` |
| Simulation vs fleet recordings | reference | full 36.5 min 8v8 and a 1v1 recorded on the fleet: 0 desyncs | **match** | `scripts/replay-check.sh <demo>` (REPLAY_SYNC_OK); `docs/SYNC_VALIDATION.md` §3a |
| Simulation on this repository's own Linux build | — | same two replays, 0 desyncs, on amd64 Linux built from this tree | **match** (the macOS layer keeps non-Mac builds exact) | `docs/SYNC_VALIDATION.md` §3a |
| libm / FP parity | gcc fleet build | gcc-15 dbl-64 swap; 9/9 hashes; streflop BIT-EXACT vs SSE (47,852) and NEON (52,080) | **match** | `scripts/build-engine.sh` gate; `scripts/run-synctest.sh` |
| Live multiplayer | BAR servers | LAN and cross-platform play proven by the original port; **online disabled** in builds from this repository | **gap (policy)**: needs BAR's approval for this repository | issue #6 |
| Unit tests | 28/29 on Linux (testCreg: upstream `paletteIndex`, fixed on master) | 28/29, same single failure | **match** | `scripts/run-unit-tests.sh`; `scripts/check-nonmac.sh linux` |
| Static libraries (image, archive, audio decoding) | spring-static-libs: zlib 1.3.1, libpng 1.6.50, giflib 5.2.2, jpeg 9f, libtiff 4.7.0, DevIL 1.8.0, libogg 1.3.6, libvorbis 1.3.7, xz 5.8.1, minizip-ng 4.0.10 | same versions, sha256 pins and flags, linked statically | **match** (macOS-only build adjustments documented in `docs/VERSIONS.md`) | `scripts/build-static-libs.sh` |
| SDL2 | Linux: the OS's SDL2; Windows: mingwlibs | SDL 2.32.10 from source | **equivalent** (same API and major version; exact version differs by platform upstream too) | `scripts/build-sdl2.sh` |
| OpenAL | Linux: the OS's OpenAL; Windows: openal-soft (mingwlibs) | openal-soft 1.25.2 from source, CoreAudio backend | **equivalent** | `scripts/build-shared-libs.sh` |
| Fonts and fallback glyphs | freetype + fontconfig; system fonts as fallback (Windows: `%WINDIR%\fonts`) | freetype 2.15.0 + fontconfig 2.18.3 from source; macOS font dirs passed explicitly | **match** | `rts/Rendering/Fonts/CFontTexture.cpp` |
| Graphics API | native OpenGL 4.6 compatibility | OpenGL 4.6 compatibility through Mesa zink → KosmicKrisp → Metal | **equivalent**; geometry shaders unavailable (Metal has no geometry stage; BAR does not need them) | `scripts/gpu-smoke.sh` (renderer string, pixel checks) |
| Rendering correctness in game | reference | driver passes the window-free smoke test; **not yet seen in a game window** on Mesa 26.3 | **unverified** | first in-game launch; visual regression baselines (open) |
| BAR lobby: replay list and downloads | spring-launcher (Electron) | `sl-bridge` implements the same protocol | **match** for replays and game/map/resource downloads | `packaging/test/sl-bridge-test.sh`; issue #1 |
| BAR lobby: minimap thumbnails, log upload, Discord presence | spring-launcher | acknowledged, not implemented | **gap** | open |
| Engine updates when BAR moves engines | the launcher downloads the new engine | the engine is inside the app; a new app must be built and shipped | **gap (design)** | update channel decision pending |
| Engine-only distribution | `recoil_<ver>_<arch>-linux.7z`: spring, spring-dedicated, spring-headless, libunitsync, pr-downloader, AI (BARb, CircuitAI, NullAI), base content, fonts, default UI files | `make engine-dist`: spring, spring-headless, pr-downloader, bundled libraries | **gap**: no spring-dedicated, libunitsync or CircuitAI | `ls` the official 7z vs `make engine-dist` |
| Input (cursor, camera, multi-monitor) | reference | hardware cursor and CamMode 2 (PR #20); multi-monitor scaling reported broken | **unverified / gap** | issues #2, #3 |
| Frame pacing / hitches | reference | `SPRING_HITCH_LOG` available; periodic hitches reported on M1 | **unverified** | issue #4 |
| macOS floor | n/a | macOS 27.0, enforced on every bundled binary | n/a | `packaging/release-build.sh` deployment-target audit |
| Signed, notarised releases | n/a | pipeline supports Developer ID + notarytool; no identity configured for this repository | **gap (decision)** | `make release` |

## Re-checking everything

```sh
scripts/preflight.sh                       # toolchain
scripts/build-engine.sh                    # engine + libm parity gate
scripts/run-synctest.sh                    # streflop vs x86 SSE and NEON references
scripts/run-unit-tests.sh                  # ctest, 28/29 expected
scripts/gpu-smoke.sh                       # driver renders, renderer string
scripts/replay-check.sh <fleet-demo.sdfz>  # simulation vs the fleet, default 20x
scripts/check-nonmac.sh                    # Linux + Windows builds, Linux ctest
ONLINE=0 make app && make test             # bundle audits; launcher, bridge tests
```
