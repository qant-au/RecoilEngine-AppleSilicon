# Parity with the official Windows and Linux builds

This is the authoritative record of how close the macOS build of this repository is
to the official Recoil builds that Beyond All Reason ships for Windows and Linux.
Every row is measured, dated and re-checkable with the command beside it; where the
two differ, the difference is either forced by the platform and stated, or open and
linked to the work that closes it.

**Measured: 2026-11-08** (engine row and simulation re-measured 2026-11-09; Linux replay, rendering and update rows 2026-11-10), macOS 27.2 on an M3 Ultra, engine `2026.09.02`.
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
| Engine version | BAR production: `2026.07.04`; BAR Engine Test: `2026.09.02` | upstream tag `2026.09.02` + macOS layer | **match with Engine Test; ahead of production** (by decision: releases target the engine BAR is moving to) | `build-engine/spring --version`; engines per setup in BYAR-Chobby `dist_cfg/config.json` |
| Simulation vs fleet recordings | reference | 2026.09.02: a 13.6 min 1v1 recorded on the fleet, 0 desyncs (2026.07.04: a 36.5 min 8v8 and a 1v1, 0 desyncs) | **match** | `scripts/replay-check.sh <demo>` (REPLAY_SYNC_OK); `docs/SYNC_VALIDATION.md` §3a, §3b |
| Simulation on this repository's own Linux build | n/a | 2026.09.02: the same 13.6 min 1v1 on amd64 Linux built from this tree (upstream's build image, emulated), 0 desyncs (2026.07.04: both replays, 0 desyncs) | **match** | `scripts/check-nonmac.sh linux`, then `scripts/replay-check.sh` in the build image; `docs/SYNC_VALIDATION.md` section 3b |
| libm / FP parity | gcc fleet build | gcc-15 dbl-64 swap; 21/21 double libm hashes equal to an x86 gcc build (no engine binary links a double libm function, so play runs on the float path only); streflop BIT-EXACT vs SSE (47,852) and NEON (52,080) | **match** | `scripts/build-engine.sh` gate; `scripts/run-synctest.sh` |
| Live multiplayer | BAR servers | LAN and cross-platform play proven by the original port; **online disabled** in builds from this repository | **gap (policy)**: needs BAR's approval for this repository | issue #6 |
| Unit tests | 29/30 on Linux (testCreg: an unregistered `CProjectile` member in upstream, one byte "between drawSorted & blockPreciseCol") | 29/30, same single failure | **match** | `scripts/run-unit-tests.sh`; `scripts/check-nonmac.sh linux` |
| Static libraries (image, archive, audio decoding) | spring-static-libs: zlib 1.3.1, libpng 1.6.50, giflib 5.2.2, jpeg 9f, libtiff 4.7.0, DevIL 1.8.0, libogg 1.3.6, libvorbis 1.3.7, xz 5.8.1, minizip-ng 4.0.10 | same versions, sha256 pins and flags, linked statically | **match** (macOS-only build adjustments documented in `docs/VERSIONS.md`) | `scripts/build-static-libs.sh` |
| SDL2 | Linux: the OS's SDL2; Windows: mingwlibs | SDL 2.32.10 from source | **equivalent** (same API and major version; exact version differs by platform upstream too) | `scripts/build-sdl2.sh` |
| OpenAL | Linux: the OS's OpenAL; Windows: openal-soft (mingwlibs) | openal-soft 1.25.2 from source, CoreAudio backend | **equivalent** | `scripts/build-shared-libs.sh` |
| Fonts and fallback glyphs | freetype + fontconfig; system fonts as fallback (Windows: `%WINDIR%\fonts`) | freetype 2.15.0 + fontconfig 2.18.3 from source; macOS font dirs passed explicitly | **match** | `rts/Rendering/Fonts/CFontTexture.cpp` |
| Graphics API | native OpenGL 4.6 compatibility | OpenGL 4.6 compatibility through Mesa zink → KosmicKrisp → Metal | **equivalent**; geometry shaders unavailable (Metal has no geometry stage; BAR does not need them) | `scripts/gpu-smoke.sh` (renderer string, pixel checks) |
| Rendering correctness in game | reference | six pictures of a fleet replay, taken at fixed simulation frames in the real game window, match baselines a person approved | **match** within the comparison limits; no picture-for-picture comparison with a Windows or Linux client has been made | `scripts/visreg.sh` (VISREG_OK); baselines in `testkit/visreg/` |
| BAR lobby: replay list and downloads | spring-launcher (Electron) | `sl-bridge` implements the same protocol | **match** for replays and game/map/resource downloads | `packaging/test/sl-bridge-test.sh`; issue #1 |
| BAR lobby: minimap thumbnails, log upload, Discord presence | spring-launcher | `sl-bridge`: minimaps decoded from the map archive (system bsdtar + DXT1), Discord Rich Presence over Discord's local socket with BAR's application id, log upload to BAR's log server | **match**; log upload is off while online play is off (it answers with where the logs are) | `packaging/test/sl-bridge-test.sh` |
| Engine updates when BAR moves engines | the launcher downloads the new engine | the engine is inside the app, so a new app must be built and published. The app checks BAR's production engine at each launch and tells the player when it is newer, and its in-app updater installs a newer app from a signed feed | **equivalent by design**; not exercised end to end, because no release has been published | `packaging/test/engine-nudge-test.sh`, `packaging/test/updater-test.sh`; `docs/RELEASING.md` |
| Engine-only distribution | `recoil_<ver>_<arch>-linux.7z`: spring, spring-dedicated, spring-headless, libunitsync, pr-downloader, AI (BARb, CircuitAI, NullAI), base content, fonts, default UI files | `make engine-dist`: spring, spring-headless, spring-dedicated, libunitsync.dylib, pr-downloader, AI (BARb, CircuitAI, NullAI), base content in the official layout, fonts, default UI files (LuaUI, luaui.lua, ctrlpanel.txt, cmdcolors.txt, example widgets), bundled libraries | **match** (unitsync initialises and lists all three AIs; BARb and CircuitAI load and play, `scripts/ai-skirmish.sh`; CircuitAI checked on Zero-K v1.14.10.3 on 2026-11-11, with smallketchup82's Apple arm64 AngelScript fix) | `ls` the official 7z vs `make engine-dist` |
| Input (cursor, camera, multi-monitor) | reference | hardware cursor and CamMode 2 (PR #20); multi-monitor scaling reported broken | **unverified / gap** | issues #2, #3 |
| VSync setting | SDL swap interval: off, on or adaptive | any non-zero value paces the render loop to the display (120.0 fps on a 120 Hz panel, no dropped frames); 0 runs unpaced (354 fps in the same scene, surplus frames dropped). On and adaptive behave the same: frames are never torn on this present path | **equivalent** | `rts/System/Platform/Mac/MetalPresent.mm` (`TakePresentSlot`); the log line `[EGL] VSync=N: frames paced to the display` |
| `gl.BeginEnd` drawing from Lua | one GL call per vertex | each block drawn with one `glDrawArrays` (`LuaImmediateModeBuffering`, on by default on macOS only, off elsewhere as upstream); inside `gl.CreateList` the plain calls are recorded, as upstream | **equivalent** (same picture; setting 0 restores the upstream path) | `scripts/visreg.sh` |
| Frame pacing / hitches | reference | `SPRING_HITCH_LOG` available; periodic hitches reported on M1 | **unverified** | issue #4 |
| macOS floor | n/a | macOS 27.0, enforced on every bundled binary | n/a | `packaging/release-build.sh` deployment-target audit |
| Signed, notarised releases | n/a | pipeline supports Developer ID + notarytool; no identity configured for this repository | **gap (decision)** | `make release` |

## Lua-Visible Differences From The Official Engine

What game Lua can observe on this build against official 2026.09.02. Each
comes from a change listed in `docs/UPSTREAM.md`, and each needs a changelog
entry in whichever upstream pull request carries it.

| Difference | Where It Applies | From |
|---|---|---|
| A `gl.BeginEnd` block is drawn with one call when it ends (`LuaImmediateModeBuffering`). Inside the block only vertex data is accepted: other `gl.*` calls do nothing, including `gl.Material` and `gl.CallList`, which plain GL accepts there. The first such call is logged once. State set inside the block (`gl.LineWidth`, `gl.PointSize`) applies to the whole block, and a nested block joins the outer one. Inside `gl.CreateList` the plain calls are recorded, as upstream does. | macOS by default; elsewhere only when the setting is turned on | #3533 |
| `gl.Rect` draws a line loop or points when the polygon mode is not fill, instead of a quad lowered to triangles. | every platform | #3272 |
| `gl.RenderToTexture` restores the framebuffer that was bound before the call. | every platform | #3554 |
| `gl.Shape` and LuaVBO calls raise a Lua error or draw nothing on unusable data instead of crashing; LuaVBO size limits apply to the requested size and attribute padding is honoured. | every platform | #3695, #3551, #3553 |
| `gl.CreateShader` fails a shader with a geometry stage on a driver where the engine's probe finds geometry shaders dead. | drivers without a geometry stage (this one) | #3539 |
| LuaVAO draws do not enable primitive restart for list topologies. | every platform | #3516 |
| `gl.GPUStamp(label)` is a new function (see `GPUTimers`); at most 64 distinct labels. | every platform | this repository |
| `Engine.versionFull` carries the build marker, `2026.09.02 (macOS port <version>)`. `Engine.version` is unchanged. | macOS | this repository |
| `EdgeMoveWidth = 0` turns edge scrolling off. | every platform | #3341 |

## Re-checking everything

```sh
scripts/preflight.sh                       # toolchain
scripts/build-engine.sh                    # engine + libm parity gate
scripts/run-synctest.sh                    # streflop vs x86 SSE and NEON references
scripts/run-unit-tests.sh                  # ctest, all but testCreg expected
scripts/gpu-smoke.sh                       # driver renders, renderer string
scripts/replay-check.sh <fleet-demo.sdfz>  # simulation vs the fleet, default 20x
scripts/check-nonmac.sh                    # Linux + Windows builds, Linux ctest
make app && make test                      # bundle audits; launcher, bridge tests
scripts/visreg.sh                          # pictures against the baselines (needs the app)
```
