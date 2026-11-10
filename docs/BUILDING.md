# Building And Testing

How to build the engine and the app on a Mac, what each test checks and what
it prints when it passes, and every configuration key and environment
variable the macOS layer adds. Version numbers are not repeated here: they
are in [VERSIONS.md](VERSIONS.md).

## Prerequisites

- An Apple Silicon Mac on the macOS floor in [VERSIONS.md](VERSIONS.md) or
  later.
- Xcode Command Line Tools (`xcode-select --install`).
- [Homebrew](https://brew.sh). The first build installs the packages it needs
  (`scripts/build-mesa-kk.sh` lists them: cmake, ninja, meson, LLVM 19,
  gcc 15, coreutils and others). Everything the app ships is built from
  pinned source under `deps/`; nothing in a bundle comes from Homebrew.
- A full clone with submodules, and upstream's tags. The build reads the
  engine version from the nearest upstream release tag and stops without one:

  ```sh
  git clone --recurse-submodules https://github.com/qant-au/RecoilEngine-AppleSilicon.git
  cd RecoilEngine-AppleSilicon
  git remote add upstream https://github.com/beyond-all-reason/RecoilEngine.git
  git fetch upstream --tags
  ```

- A checkout path without spaces. The build scripts stop at once if it has
  one.
- For the replay and picture tests only: game content (the game, a map and
  the lobby package) and a demo recorded on this engine version. Running the
  app once and letting it download BAR provides the content; see
  [Replay Check](#replay-check) for the demo.
- For the Linux and Windows check only: Docker, and bash 4 or later
  (`brew install bash`).

`scripts/preflight.sh` reports what is missing. It changes nothing.

## Build Targets

Always build through `make` or the scripts. A bare `ninja` in `build-engine/`
relinks the engine without the libm step described in
[DETERMINISM.md](DETERMINISM.md) and skips every check.

| Command | What It Builds | Tests It Runs |
|---|---|---|
| `make engine` | The engine binaries in `build-engine/` (`scripts/build-engine.sh`). Builds the Mesa driver first if it is not current. | The libm parity gate and the artifact checks. Prints `ENGINE_BUILD_OK`. |
| `make app` | `release-artifacts/Accurona.app`, a `.zip` and a `.dmg`, ad-hoc signed. | As `make engine`, then the bundle audits: library closure, search paths, deployment target, builder-path scan, loose-file manifest, license audit. |
| `make engine-dist` | The engine alone, `release-artifacts/Recoil-macos-<engine>-port<version>.zip`: `spring`, `spring-headless`, `spring-dedicated`, `libunitsync`, `pr-downloader`, the AIs, base content, the driver. | As `make app`. |
| `make certify` | As `make app`. | As `make app`, plus the streflop sync test, a replay check, visual regression on the bundle just built, and the driver smoke test in a real window. Needs a GPU, game content and a demo (`RELEASE_SMOKE_DEMO=<file.sdfz>`, or a file under `refdemos/<engine>/`). The summary ends with `certified: yes`. |
| `make release` | As `make certify`, signed with a Developer ID and notarised. Needs `IDENTITY` and notary credentials: see [RELEASING.md](RELEASING.md). | Every test above. None can be skipped for a Developer ID build. |
| `make test` | Nothing. | The packaging tests under `packaging/test/`. |

`packaging/release-build.sh` is what the app targets call; its header lists
every option. Online play is off unless `ONLINE=1` is on the `make` command
line (see the README).

The build keeps two copies of the driver: `deps/mesa-native` for
`make engine` and the test scripts, and `deps/mesa-native-release` for the
app targets. [MAINTENANCE.md](MAINTENANCE.md) explains the driver build.

## Tests

Each line is a command and what it prints on success. All of them exit
non-zero on failure.

| Test | Command | Passes With | Needs |
|---|---|---|---|
| libm parity gate | part of `scripts/build-engine.sh` | `libm parity gate (submodule): OK (N/N hash match ...)` | nothing extra |
| streflop sync test | `scripts/run-synctest.sh` | `SYNCTEST_OK` | nothing extra |
| Engine unit tests | `scripts/run-unit-tests.sh` | `UNIT_TESTS_OK` | builds in `build-tests/` |
| Replay check | `scripts/replay-check.sh <demo.sdfz>` | `REPLAY_SYNC_OK ... desyncs=0 checksums=N` | game content, a demo |
| Visual regression | `scripts/visreg.sh` | `VISREG_OK` | a GPU, a built app, game content, the demo |
| Driver smoke test | `scripts/gpu-smoke.sh` | `GPU_SMOKE_OK` | a GPU |
| Packaging tests | `make test` | each script ends `RESULT: N passed, 0 failed` | `dialog-center-test.sh` shows real windows |
| Linux and Windows check | `scripts/check-nonmac.sh` | `NONMAC_OK` | Docker, bash 4+ |

### libm Parity Gate

Hashes the results of every double-precision libm function that links, over
fixed inputs, and compares each line with a reference generated on x86
(`testkit/libm-refs/`). It also checks that any binary which links a double
libm function took it from the gcc-compiled objects
(`scripts/check-dbl64-marker.sh`). `scripts/gen-libm-ref.sh` regenerates the
reference in upstream's Linux build image; do that only when streflop itself
changes.

### streflop Sync Test

Builds `tools/sync-test` natively and requires a bit-exact match with the
committed x86 SSE reference and the committed NEON reference, with at least
40,000 tests in common with each. It is the local equivalent of upstream's
"STREFLOP Float Sync Test" workflow. Seconds, CPU only.

### Engine Unit Tests

Upstream's ctest suite, built against the same libraries the app ships. The
expected result on the current engine version is all but one test passing:
`testCreg` fails for one known upstream gap (an unregistered `CProjectile`
member, reported as a missing byte "between drawSorted & blockPreciseCol").
The script excuses `testCreg` for that message only. The Linux build gives
the same result.

### Replay Check

Re-simulates a recorded game with `spring-headless` and compares every
checksum the recording clients stored in the demo. It refuses a demo with no
checksums, a demo recorded on another engine version, and a run that does not
reach the demo's last checksum. Playback runs at 20 times real speed by
default; sync is checked the same way at any speed.

The demo must come from the engine version under test.
`scripts/find-fleet-replays.py <engine version>` lists public BAR replays
recorded on it, with download addresses. The game version and map the demo
names must be in the content folder (`--content`, default the app's data
folder); the header of `scripts/replay-check.sh` shows how to fetch them with
`pr-downloader`.

### Visual Regression

Plays the demo in the real game window from a built app bundle, takes engine
screenshots at fixed simulation frames from a fixed camera, and compares them
with the approved pictures in `testkit/visreg/<engine>/<demo>/`. A picture
fails when its mean difference or its share of clearly different pixels
exceeds the limits (`limits.txt` beside the pictures can loosen them per
picture). It opens a game window for about two minutes and plays without
sound.

`scripts/visreg.sh --bless` copies a run's pictures over the baselines. Do
that only after a person has looked at the new pictures.

### Driver Smoke Test

Builds `test/macos/gpu-smoke.c` against the driver and runs it with the
driver selection the launcher uses. It checks the renderer string (Zink on
KosmicKrisp, not a software fallback) and some rendered pixels. No window.

### Linux And Windows Check

The macOS layer edits shared engine files, and a Linux or Windows break does
not show in a Mac build. `scripts/check-nonmac.sh` builds this tree for Linux
and Windows the way upstream does (`docker-build-v2`) and runs the unit tests
on Linux. amd64 is emulated on Apple Silicon, so a cold run is slow. Run it
before pushing a change outside `rts/System/Platform/Mac`, `packaging/` and
`scripts/`.

## Configuration Keys

The policy: a switch a player may want is a registered configuration key
(`springsettings.cfg`, changeable from the game); an environment variable is
a support or test switch; anything heavier is compiled only into a
diagnostics build (`cmake -DSPRING_MAC_DIAGNOSTICS=ON`), never into a
release.

Keys the layer adds. Those marked macOS exist on macOS only.

| Key | Default | Meaning |
|---|---|---|
| `MacCommandAsCtrl` (macOS) | 1 | Command acts as Control, so Cmd+key works like Ctrl+key elsewhere. Also takes the key equivalents (Cmd+Q, Cmd+H, Cmd+M) out of the application menu. |
| `MacGrabWindowed` (macOS) | 0 | Keep the cursor inside the game window in windowed mode too. Borderless and fullscreen always confine it. |
| `MacRenderScale` (macOS) | 1.0 | Fraction of the window's pixel resolution the game renders at, 0.5 to 1.0. Below 1.0 the frame is upscaled at present time. |
| `MacUpscaler` (macOS) | 1 | How a frame rendered below window resolution is upscaled: 0 plain stretch, 1 the MetalFX spatial upscaler. |
| `MacPresentDirect` (macOS) | 1 | The present shader reads the readback ring directly from unified memory; 0 uses the IOSurface staging path. |
| `MacWorkerQos` (macOS) | 1 | Thread-pool workers ask for the user-initiated quality-of-service class, which prefers the performance cores. |
| `MacSwipePanSpeed` (macOS) | 1.0 | Map pan speed for Shift + swipe on a Magic Mouse or trackpad. 0 turns the pan off. |
| `LuaImmediateModeBuffering` | 1 on macOS, 0 elsewhere | Draw each `gl.BeginEnd` block with one `glDrawArrays` instead of one call per vertex. |
| `GPUTimers` | 0 | Time the GPU per render pass and expose the results as `GPU::*` profiler zones. |
| `GPUTimersSplitPasses` | 0 | Force a render-pass boundary at every GPU timer stamp. Needed on tile-based GPUs to attribute time per pass; costs extra loads and stores. |
| `ShowRenderSizeInTitle` | 0 | Append the true render resolution to the window title. A test aid. |
| `WindowTitle` | empty | Window title; `{version}` expands to the engine version. Empty means the engine's default. |
| `CameraMoveHoldAccel` | 0.0 | Arrow-key camera scrolling speeds up the longer the keys are held, by this fraction of the base speed per second. 0 is constant speed. |
| `CameraMoveHoldMaxMult` | 4.0 | Cap on that speed-up, as a multiple of the base speed. |
| `MouseRelativeSpeedScale` | 1.0 | Scales mouse movement in relative mode (locked camera, middle-button scroll). |

Two defaults differ on macOS: `HardwareCursor` is 1 (the software cursor
trails the pointer by the present latency) and `Fullscreen` has a macOS
default. `VSync` is honoured by pacing presents to the display: any non-zero
value paces, 0 runs unpaced.

## Environment Variables: Engine

Support switches. All are unset by default, and all are in release builds.

| Variable | Effect |
|---|---|
| `SPRING_MAC_NO_RETINA=1` | Render at logical 1x and let the system upscale. |
| `SPRING_MAC_FULL_BACKING=1` | Render at the full backing size even where the layer would cap it to the panel's native size or the GPU pixel budget. |
| `SPRING_MAC_GL_CORE=1` | Force a core-profile GL context. Compatibility is the default and the supported mode. |
| `SPRING_MAC_LEGACY_PRESENT=1` | Use the CPU-staging present path. |
| `SPRING_MAC_NO_LUAINTRO=1` | Skip the Lua loading screen. |
| `SPRING_ALLOW_SOFTWARE_GL=1` | Allow a software renderer instead of failing at start. |
| `SPRING_EGL_FULL_TEARDOWN=1` | Tear EGL down fully at exit instead of the fast exit. |
| `SPRING_NO_STALL_LOG=1` | Silence the log lines for draw gaps over 150 ms. |
| `SPRING_MAC_STREAM_BUFFERING=n` | Stream-buffer ring depth, 2 to 8 (default 3). |
| `SPRING_MAC_UPLOAD_BUFFERING=n` | Ring depth for the model-data upload buffers (minimum 3). |
| `SPRING_LUAVAO_FORCE_RESTART=1` | Keep primitive restart enabled on list topologies, as upstream does. |
| `SPRING_HITCH_LOG=ms` | Log each frame slower than this many milliseconds (50 if the value is 1 or less), with a per-timer breakdown. |
| `SPRING_DBG_INPUT=1` | Log every mouse, wheel and motion event with its source. macOS builds only. |
| `SPRING_DBG_CONFIG=1` | Log every settings change made during play. macOS builds only. |
| `SPRING_DUMP_STATE_RANGE=min:max` | Dump the full synced state per frame in the range, for desync triage. |
| `SPRING_INFOLOG=<file>` | Set by a launcher: the log the engine's error dialog offers for a bug report. |
| `SPRING_PACKAGE_VERSION=<text>` | Set by a launcher: written to the log so a report identifies the package. |

Switches the test scripts use. They run against the release build, so these
are compiled in.

| Variable | Effect |
|---|---|
| `SPRING_DEMO_SPEED=n` | Play a demo back n times faster than real time. Demos only. |
| `SPRING_MAC_FIXED_WINDOW=1` | Keep the window at the configured size and position. |
| `SPRING_MAC_PERF_PIN=1` | Fixed presentation conditions for picture comparison and benchmarks. Turns display pacing off. |
| `SPRING_MAC_PERF_RENDER_SIZE=WxH` | Fixed render size, independent of the window size. |

Diagnostics builds only (`-DSPRING_MAC_DIAGNOSTICS=ON`):
`SPRING_MAC_PRESENT_TEST`, `SPRING_FRAME_CAPTURE` (with `_EVERY` and
`_LIMIT`), `SPRING_MAC_DUMP_FRAME`, `SPRING_TIME_PRESENT`,
`SPRING_MAC_PRESENT_LAG`, `SPRING_MAC_PRESENT_GPUPACK`, and
`SPRING_DBG_INJECT` (scripted mouse input read from a file).

## Environment Variables: The App's Launcher

Read by `packaging/launcher.sh` when the app starts. They exist for the test
scripts and for support; a player never needs one.

| Variable | Effect |
|---|---|
| `BAR_WRITEDIR_OVERRIDE=<dir>` | Use this data folder instead of the one under `~/Library/Application Support`. |
| `BAR_SKIP_CONTENT_CHECK=1` | Skip the whole first-run block: update check, messages, consent and content download. |
| `BAR_ASSUME_CONSENT=1` | Skip the update check, the message check and the consent prompt, and download content as if consent had been given. For unattended tests only. |
| `BAR_CONTENT_SCOPE=lobby` | Download only the lobby package, not the game and maps. |
| `ACCURONA_SKIP_UPDATE=1` | Skip the in-app update check. |
| `ACCURONA_UPDATE_FEED=<url>` | Read this update feed instead of the one the build recorded. |
| `BAR_MESSAGE_CONFIG_URL=<url>` | Read this message file instead of the one the build recorded. |
| `BAR_SKIP_ENGINE_NUDGE=1` | Skip the check of BAR's production engine version. |
| `BAR_DIST_CFG_URL=<url>` | Where that check reads BAR's launcher configuration from. |
| `BAR_RELEASES_URL=<url>` | The page the "new version needed" dialog opens. |

## Environment Variables: Build And Test Scripts

| Variable | Used By | Effect |
|---|---|---|
| `MACOSX_DEPLOYMENT_TARGET` | every build script | The macOS floor. The default is the pinned floor; every binary is checked against it. |
| `ENGINE_SRC`, `ENGINE_BUILD` | `build-engine.sh`, `release-build.sh`, test scripts | Engine source tree and build folder (defaults: this checkout, `build-engine/`). |
| `ENGINE_ALLOW_SRC_SWITCH=1` | `build-engine.sh` | Allow a build folder configured for another source tree to be reused. |
| `AI_TYPES` | `build-engine.sh` | Which AI interfaces to build (default `NATIVE`). |
| `WITH_SYNCTEST=1`, `WITH_VISREG=1` | `build-engine.sh` | Same as `--with-synctest`, `--with-visreg`. |
| `MESA_PREFIX`, `MESA_SRC`, `MESA_PATCH_DIR`, `MESA_FORCE_REBUILD=1` | `build-mesa-kk.sh` | Driver install prefix, source checkout, patch folder, and a forced rebuild. |
| `DRIVER_DEPS_FORCE=1`, `STATIC_LIBS_FORCE=1`, `SHARED_LIBS_FORCE=1` | the dependency build scripts | Rebuild that dependency set even when its stamp matches. |
| `JOBS` | `check-nonmac.sh` | Parallel build jobs in Docker. |
| `SYNCTEST_MIN_COMMON` | `run-synctest.sh` | Lowest acceptable number of tests in common with each reference (default 40,000). |
| `VISREG_APP`, `VISREG_MAX_MEAN`, `VISREG_MAX_BAD_PCT`, `VISREG_EXTRA_SETTINGS` | `visreg.sh` | The app bundle to test, the two default limits, and extra settings lines for the run. |
| `RELEASE_SMOKE_DEMO=<file>` | `release-build.sh` | The demo for the certify replay check. |
| `RELEASE_CERTIFY=1`, `RELEASE_SYNC_TEST=1`, `RELEASE_VISREG=1` | `release-build.sh` | Same as `--certify`, `--with-synctest`, `--with-visreg`. |
| `RELEASE_OUT=<dir>` | `release-build.sh` | Where artifacts go (default `release-artifacts/`). |
| `BAR_ONLINE`, `BAR_CONTENT_TAGS`, `BAR_MESSAGES_CONFIG`, `ACCURONA_UPDATE_FEED`, `ACCURONA_UPDATE_DOWNLOAD_BASE`, `ACCURONA_UPDATE_SIGNING_KEY`, `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | `release-build.sh` | Release settings: see [RELEASING.md](RELEASING.md). |
