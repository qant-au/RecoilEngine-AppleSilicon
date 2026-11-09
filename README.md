# Recoil Engine Port to Apple Silicon - Plays Beyond All Reason (BAR) natively on macOS

<p align="center">
  <a href="https://github.com/qant-au/RecoilEngine-AppleSilicon/releases/latest"><img src="https://img.shields.io/github/v/release/qant-au/RecoilEngine-AppleSilicon?logo=apple&label=download&color=1793d1" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple" alt="macOS · Apple Silicon">
  <a href="https://github.com/qant-au/RecoilEngine-AppleSilicon/releases"><img src="https://img.shields.io/github/downloads/qant-au/RecoilEngine-AppleSilicon/total?color=44cc11" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/license-GPL--2.0-blue" alt="License: GPL-2.0">
  <img src="https://img.shields.io/badge/built%20on-Recoil-orange" alt="Built on the Recoil engine">
</p>

**This project is an unofficial native Apple Silicon port of the
[Recoil](https://github.com/beyond-all-reason/RecoilEngine) RTS engine** — the
engine itself now runs macOS with no Rosetta and no virtual machine. It achieves <u>100% sync match</u> between macOS and officially supported platforms such as Windows. This means games (such as BAR) can now run natively on macOS. It contains a series of fixes to make sure the behaviour of the game on Apple Silicon matches exactly that of other platforms, plus a series of Apple specific performance improvements.

> [!IMPORTANT]
> If you run into issues, please report them [here](https://github.com/qant-au/RecoilEngine-AppleSilicon/issues) — **not** in the official Beyond All Reason or Recoil channels. They can't help with problems caused by this port.

⚡️ **A Claude Fable port.** The macOS layer in this repository was built
largely by **[Claude Fable](https://www.anthropic.com)** (Anthropic's Claude
model) — see
[How Recoil was Enhanced for Apple Silicon](#how-recoil-was-enhanced-for-apple-silicon).

## Downloading
For convenience, releases also include **Accurona**, an optional
drag-to-install app that downloads **[Beyond All Reason](https://www.beyondallreason.info/)**
from its official online location and configures the engine to play it.

**Two downloads** on the [releases page](https://github.com/qant-au/RecoilEngine-AppleSilicon/releases/latest):

| Artifact | What it is | For whom |
|---|---|---|
| `Accurona-v<ver>.dmg` | **If you want to play BAR on macOS** — Accurona: the engine plus a drag-to-install app that (after an explicit consent prompt) downloads Beyond All Reason from BAR's official content network, keeps it updated, and launches straight into its lobby. | Players who want to play BAR on a Mac. |
| `Recoil-macos-<engine>-port<ver>.zip` | **The project itself** — the engine port: signed, notarized `spring`, `spring-headless`, `spring-dedicated`, `libunitsync`, `pr-downloader` and the AIs (BARb, CircuitAI, NullAI), with the bundled Metal driver stack and the default UI files, the same set as the official Linux engine archive. No game content or configuration. | Any Recoil/Spring game community, tooling, or anyone building their own game launcher on top. |

<p align="center">
  <a href="https://github.com/qant-au/RecoilEngine-AppleSilicon/releases/latest"><b>⬇&nbsp; Download for macOS (Apple Silicon)</b></a>
  &nbsp;·&nbsp; engine port + optional Accurona app &nbsp;·&nbsp; macOS 27+
</p>

> [!CAUTION]
> **Unofficial project — third-party game content.** This is an independent
> community port, not affiliated with, endorsed by, or supported by the Recoil
> engine team or the Beyond All Reason project. **No game content is hosted
> here**: this repository and its releases contain only the engine (GPL-2.0)
> and this port's packaging. The game itself — **including executable game
> code that the engine runs**, plus its units, art, sounds, and maps,
> under [BAR's own licenses](https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/LICENSE.md)
> — is downloaded by the helper app from BAR's official content network on
> first launch (after an explicit consent prompt) and may auto-update later,
> possibly including other components in future.
> That code and content is not hosted, vetted, or endorsed by this project's
> maintainer, who accepts no responsibility for it or for any damage it may
> cause — install and play **AT YOUR OWN RISK**.

## What is Recoil?

<p align="center">
  <img src="screenshots/hero.jpg" alt="Beyond All Reason running natively on macOS (Apple Silicon)" width="100%">
  <br><em>Recoil running Beyond All Reason natively on an Apple Silicon Mac.</em>
</p>

The [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine) is the
program that actually runs a game built on it: the simulation, graphics, and
networking. The engine ships for Windows and Linux; and now this repository is a native macOS build of it. Under the hood it renders through Apple's Metal
(OpenGL 4.6 → Mesa Zink → [KosmicKrisp](https://lunarg.com/kosmickrisp/) →
Metal) and simulates bit-identically to the official builds, so a Mac client
shares the same matches and replays as everyone else. Pinned to engine
version **2025.06.24**, the version BAR's live fleet runs; the screenshots
and benchmarks throughout show the engine port running Beyond All Reason.

## How Recoil was Enhanced for Apple Silicon

The macOS *foundation* — the first working Apple Silicon builds, the
surfaceless-EGL → Zink graphics path, and the ARM64 deterministic-math
groundwork now
[merged into the official engine](https://github.com/beyond-all-reason/RecoilEngine/pull/2819)

Previous efforts to port to macOS did **not** yet produce a
*compliant* engine — one that can join public multiplayer without desyncing.
BAR is lockstep-deterministic: every client recomputes the entire simulation
and must get **bit-identical** results, previous Apple Silicon clients still
diverged from the x86 fleet in three ways:

1. **A different math library.** Apple's libm returns per-ULP-different
   results for `double` functions than the glibc implementations the fleet's
   builds use — any one call in synced code is a desync.
2. **Undefined float→integer conversions.** Out-of-range float→int is
   undefined behavior; the fleet's gcc-x86 binaries saturate in hardware
   (`cvttss2si`) and game unit scripts rely on that value, while clang-arm64
   computed something else (the cause of a real desync in Raptors games).
3. **Fused multiply-adds.** On ARM the compiler freely contracts `a*b+c` into
   one `fmadd` with different rounding — a single contraction in synced code
   is a 1-ULP, game-ending divergence.

This repository is the layer that closed those gaps and **proved** the result,
(developed largely by **Claude Fable**) with direction
from the maintainer:

- **Bit-exact cross-architecture simulation** — the core of the port: the
  glibc dbl-64 libm compiled in for fleet-parity `double` math (guarded by a
  9/9 libm hash gate in every build), x86 conversion semantics reproduced on
  arm64, `-ffp-contract=off` enforced globally, and a UB sweep of synced code
  — then certified bit-exact over full-length 8v8 replays and live
  cross-platform matches ([SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md); the
  complete register of synced-code changes is its Appendix A).
- **A rebuilt macOS graphics-present path.** The EGL/Metal context and the whole
  read-back-and-present pipeline were extracted into a proper `Platform/Mac`
  backend, and the driver stalls and bugs that made the earlier path unshippable
  were fixed.
- **A one-command, reproducible build-and-release pipeline.** `make app` builds
  the graphics driver from pinned upstream source, builds the engine, runs the
  determinism gates, and produces the signed, notarized, drag-to-install
  `.app`/`.dmg` — nothing fetched or built by hand ([details below](#building-the-macos-app)).
- **Native optimisation** taking heavy late-game scenes from
  single-digit frame rates to display-class ones at 5K, pixel-identical (table
  below).
- **Native-Mac behaviour** — correct windowing and full-screen behavior, keyboard layour, a Cmd+Q guard so a reflex keystroke can't abandon a live match, Local-Network permission handling, and loud failure instead of a silent slow software fallback, full-screen behavior, retina/HiDPI, etc.

Upstream's own engine README is
[README-upstream.markdown](README-upstream.markdown); this file covers the macOS
build.

## What works

- **Full game, online-compatible simulation.** The port is sync-certified
  against official builds: bit-exact lockstep over full-length 8v8 replays
  (up to 92,040 frames) and live LAN games versus unmodified official Linux
  and Windows release binaries, including 16-player games and PvE modes,
  with zero sync errors. Method, numbers, reproduction commands, and honest
  limits: **[SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md)**.

  > **Online play is currently disabled in released builds** while approval
  > to connect to BAR's community servers is sought from the game's creators.
  > Skirmish vs AI, replays, and local-network (LAN) games all work; the sim
  > is online-*capable* and certified above — the block is a deliberate
  > policy choice in the launcher, not a technical limit. This is an
  > unofficial port: please report problems with it [here](../../issues),
  > not to the official BAR/Recoil teams.
- **Native performance.** A month-one optimization campaign took the heavy
  late-game scenes from single-digit to display-class frame rates at 5K with
  pixel-identical output (measured on an M2 Ultra Mac Studio, vsync on):

  | Scene | Before | After |
  |---|---|---|
  | 2,162-unit battle arena | 6.8 fps | 54.4 fps (8.0×) |
  | 1,082-unit battle, combat zoom | 12.1 fps | 71.7 fps (5.9×) |
  | Late-game 8v8, icon overview | 4.7 fps | 45.5 fps (9.7×) |
  | Early game | 50.6 fps | display-limited (120 Hz) |

  What changed and why, with the methodology:
  **[IMPROVEMENTS.md](docs/IMPROVEMENTS.md)**.
- Retina/HiDPI, dynamic window resize, borderless fullscreen, lobby
  (Chobby) networking, music/effects via openal-soft, P/E-core-aware
  threading.

## Screenshots

<p align="center">
  <img src="screenshots/battle.jpg" width="49%" alt="A battle mid-map — two armies clashing with the full HUD">
  <img src="screenshots/valley.jpg" width="49%" alt="An army massing in a mountain valley">
  <br><em>Real matches, full interface — captured on macOS. (More in the game itself.)</em>
</p>

## Requirements

- Apple Silicon Mac so far tested on M2 and above.
- macOS 27+.
- Internet connection - Game content downloads from the official BAR content network on first run

## Known limitations (honest ones)

- Late-game 8v8 frame rate is bounded ~60–70 fps by single-threaded
  simulation + game-Lua on the main thread — an upstream engine property,
  not a graphics-stack limit on this port.
- Memory footprint is healthy on desktop (≈7.4 GB RSS in late-game 8v8) but
  heavy for smaller devices.
- Geometry shaders are unavailable (Metal has no geometry stage); BAR does
  not require them.

## Building / stack

The GL stack is upstream Mesa (Zink + KosmicKrisp) at a pinned commit plus
a small patch series maintained both as a Mesa fork branch and as plain
`patches/mesa/*.patch` — the driver is reproducible from pure upstream
source. Engine-side macOS work is a curated, reviewable commit series on
top of the upstream release tag, written to be upstreamable piecewise.

## Building the macOS app

Everything needed ships in this repository — the engine source, the Mesa
patch series (`patches/mesa/`), the driver/engine build scripts
(`scripts/`), and the packaging pipeline (`packaging/`, `Makefile`).

Prerequisites: an Apple Silicon Mac on macOS 27+, Xcode Command Line Tools,
and [Homebrew](https://brew.sh) — the build installs the packages it needs
(SDL2, LLVM 19 for the driver compile, openal-soft, …) as it goes.

```sh
make app         # Accurona, the BAR app: pinned Mesa driver (cached
                 # after the first build) -> engine + determinism gates ->
                 # Accurona.app + .dmg (ad-hoc signed, local use)
make engine-dist # the Recoil engine alone (no BAR helper/branding):
                 # Recoil-macos-<engine>-port<ver>.zip
make certify     # app + full replay-determinism certification (GPU, ~1h)
make release     # certified + Developer ID signed + notarized (needs
                 #   IDENTITY="Developer ID Application: ..." and
                 #   NOTARY_PROFILE=<notarytool keychain profile>)
make engine      # just the engine binary, with the sync gates
```

**Online play is disabled by default** in every build, source builds included
(`packaging/release-build.sh` defaults to `BAR_ONLINE=0`: the online lobby
resolves to an unreachable loopback endpoint; LAN and local play are
unaffected). `ONLINE=0 make app` and `--disable-online` remain as explicit
spellings of the default; `--enable-online` is a deliberate local opt-in.
Approval to connect to BAR's community servers has not been sought for this
repository yet: do not distribute an online-enabled build until it is.

### Tests

Unit tests build in their own directory, never in `build-engine/` (a bare
`ninja` there undoes the gcc-swapped libm objects and silently breaks fleet
parity):

```sh
scripts/build-engine.sh                      # engine + libm parity gate
cmake -S . -B build-tests -G Ninja -DAI_TYPES=NONE   # once (see scripts/build-engine.sh for the full flag set)
ninja -C build-tests tests spring-headless basecontent
(cd build-tests && ctest --output-on-failure)
packaging/test/message-check-test.sh && packaging/test/launcher-test.sh
```

What the build does, in order: builds the Mesa Zink+KosmicKrisp driver from
the pinned upstream commit + `patches/mesa/` (provenance-stamped, skipped
when already built); builds the engine against it with the deterministic-FP
configuration; runs the libm fleet-parity hash gate and the cross-arch
streflop sync-test; stages, signs, and (for `make release`) notarizes the
bundle with the styled drag-to-install DMG. Heavier validation (full-replay
determinism, GPU driver-identity smoke) is the certify tier — mirroring
upstream Recoil CI, where build and validation are separate workflows.

## Runtime knobs

One policy: **user-facing switches are registered springsettings config
variables** (discoverable, documented, changeable from the game); **env vars
are support/debug escape hatches**, and anything heavier is compiled out of
release builds behind `-DSPRING_MAC_DIAGNOSTICS=ON`.

Config (springsettings.cfg):

| Key | Default | Meaning |
|---|---|---|
| `MacPresentDirect` | 1 | Present shader reads the readback ring directly from unified memory; 0 = IOSurface staging path. Runtime-changeable. |
| `MacWorkerQos` | 1 | Sync-pool ThreadPool workers request USER_INITIATED QoS (prefer the performance cluster). Runtime-changeable. |
| `WindowTitle` | "" | Window title; `{version}` expands to the engine version. Empty = engine default. |

Environment (support escape hatches; all default off/unset):

| Var | Effect |
|---|---|
| `SPRING_MAC_NO_RETINA=1` | Render at logical 1x and let CoreAnimation upscale (readback cost /4 on Retina). |
| `SPRING_MAC_GL_CORE=1` | Force a core-profile GL context (compat is the default and the supported mode). |
| `SPRING_MAC_LEGACY_PRESENT=1` | CPU-staging present path (the pre-optimization fallback). |
| `SPRING_ALLOW_SOFTWARE_GL=1` | Permit the llvmpipe/softpipe fallback instead of failing loudly. |
| `SPRING_EGL_FULL_TEARDOWN=1` | Real EGL teardown at exit (debug the driver shutdown race; default is fast-exit). |
| `SPRING_NO_STALL_LOG=1` | Silence the >150ms draw-gap stall log lines. |
| `SPRING_MAC_STREAM_BUFFERING=n` | Stream-buffer ring depth 2..8 (default 3). |
| `SPRING_LUAVAO_FORCE_RESTART=1` | Restore upstream primitive-restart behavior on list topologies. |
| `SPRING_DUMP_STATE_RANGE=min:max` | Dump full synced state per frame in the range (desync triage; local analysis only). |

Diagnostics builds only (`cmake -DSPRING_MAC_DIAGNOSTICS=ON`; not compiled
into releases): `SPRING_MAC_PRESENT_TEST`, `SPRING_FRAME_CAPTURE[_EVERY/_LIMIT]`,
`SPRING_MAC_DUMP_FRAME`, `SPRING_TIME_PRESENT`, `SPRING_MAC_PRESENT_LAG`,
`SPRING_MAC_PRESENT_GPUPACK`.

## Documentation

Deeper docs live alongside the code — start with **AGENTS.md** if you want to
work on the port (with or without an AI agent).

| Document | What it is |
|---|---|
| [docs/PARITY.md](docs/PARITY.md) | **The authoritative status of macOS against the official Windows and Linux builds**: what matches, what is equivalent, what is open, and how to re-check each. |
| [AGENTS.md](AGENTS.md) | Start here to work on the port: read-order, the hard rules, and how to build. Written so an AI coding agent can get up and running. |
| [docs/PORTING_PRINCIPLES.md](docs/PORTING_PRINCIPLES.md) | The golden rules — the determinism contract, sim untouchability, per-subsystem strategy, and the verification ladder. |
| [SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md) | How multiplayer bit-exactness is proven: method, numbers, reproduction commands, and honest limits. |
| [IMPROVEMENTS.md](docs/IMPROVEMENTS.md) | What the port changes and why — each entry symptom → cause → fix → measured result. |
| [docs/MAINTENANCE.md](docs/MAINTENANCE.md) | How the macOS layer rides upstream: the version-bump / rebase-onto-a-new-release procedure. |
| [docs/AGENT_FAILURE_MODES.md](docs/AGENT_FAILURE_MODES.md) | What halts or silently misleads an automated agent on macOS (dialogs, permissions, fallbacks). |
| [docs/LESSONS.md](docs/LESSONS.md) | Numbered, citable gotchas already hit during the port. |
| [docs/UPSTREAM_CANDIDATES.md](docs/UPSTREAM_CANDIDATES.md) | Fixes in this layer that belong upstream, so the patch series shrinks over time. |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Pinned versions (engine, driver, toolchain) and why each is pinned. |
| [docs/SOUND_WARNINGS_CATALOG.md](docs/SOUND_WARNINGS_CATALOG.md) | Reference for the audio-subsystem warnings you may see in the log. |

## Credits

This port stands on a lot of prior work, gratefully:

- **[Ben Breen](https://github.com/benbreen/RecoilEngine-AppleSilicon)** —
  the original Apple Silicon port this repository continues: the sync
  certification, the Metal present path, the packaging pipeline and the v0.11
  to v0.13 releases. That repository is no longer maintained; this one is.
- **[TonyTheCat](https://github.com/TonyTheCat)** and
  **[kapyctnik-ai](https://github.com/kapyctnik-ai)** — fresh-clone build fixes,
  the source-built SDL2, the hardware cursor and camera fixes, and MetalFX
  upscaling, from
  [PR #20](https://github.com/benbreen/RecoilEngine-AppleSilicon/pull/20) on the
  original repository, merged here with authorship kept.
- **[ExaDev](https://github.com/ExaDev/RecoilEngine)** — the foundational
  macOS fork: first working builds, EGL/Zink bring-up, pr-downloader fixes.
  Their commits form the base of this series, preserved with attribution.
- **The Recoil engine team** — especially the ARM64 deterministic
  floating-point work merged in
  [PR #2819](https://github.com/beyond-all-reason/RecoilEngine/pull/2819),
  without which cross-platform lockstep on Apple Silicon would not exist.
- **Fixes taken from other macOS work**, with authorship kept in the commits:
  - **[Vandomas](https://github.com/Vandomas/RecoilEngine-AppleSilicon)**: sound
    decoding outside the sound lock, from
    [RecoilEngine#3276](https://github.com/beyond-all-reason/RecoilEngine/pull/3276);
    rebuilding the picture when the window changes display, Retina mouse
    positions in the engine's own start menu, the hardware cursor default with a
    speed scale, non-blocking UDP sends (RecoilEngine#3293), GPU-loss handling,
    GL debug markers, log roll-up fixes, bringing the lobby back after an
    engine error, GPU time per render pass in the profiler, and the savegame
    fixes (decal drawer recreated from the save, objects cleaned up after a
    failed load), from his fork.
  - **[tomjn](https://github.com/tomjn)**: the NEON FPCR check, from
    [RecoilEngine#3689](https://github.com/beyond-all-reason/RecoilEngine/pull/3689);
    first-vertex provoking on KosmicKrisp (#3532), `gl.BeginEnd` in one draw
    (#3533), rectangle outlines as lines (#3272), the SSD path check (#3690),
    headless S3O decoding (#3700), Lua errors instead of crashes on unusable
    LuaVBOs (#3695), `--window` turning fullscreen off again (#3163), and from
    his macOS integration branch (#3271) the GL 3.0 extension-check skip and
    the Mesa threaded-context patch for flipped frames (Mesa issue 16734).
  - **[Leon Seemann](https://github.com/leonseemann)**: macOS keyboard fixes
    (#3540: Cmd as Ctrl, dead keys, AutoFill off, F11/Pause), streamed-buffer
    orphaning (#3542), persistent model uniforms (#3543), LOS/radar PBO uploads
    (#3494), S3TC DDS decompression (#3566) and the nano-particle geometry-shader
    check (#3539), and the hardware MAC address through IOKit (#3493).
  - **[ysommer](https://github.com/ysommer)**: macOS crash stack traces and clean
    exit (#3546), hidden symbol visibility (#3545).
  - **[Yeo-Jun Yoon](https://github.com/yeojuny)**: the QTPFS failed-load fix (#3694),
    LuaVBO size and padding checks (#3551, #3553), StreamBuffer slot stepping and
    fence lifetime (#3552, #3556), the framebuffer restore after
    gl.RenderToTexture (#3554), archive fallback fonts (#3555) and the DXT5/BC4/BC5
    alpha flip that wrote past the block (from #3271).
  - **[sprunk](https://github.com/sprunk)**: review changes and the changelog
    snippet on #3551.
  - **[moss-orbit-9f339e](https://github.com/moss-orbit-9f339e)**: headless GLSL/NPOT
    reporting (#3615) and the screenshot deadlock fix (#3631).
  - **[TonyTheCat](https://github.com/TonyTheCat)**: the mouse-cursor texture leak
    ([RecoilEngine#3687](https://github.com/beyond-all-reason/RecoilEngine/issues/3687)).
  - **[Anatolii / Dimaris-nsk](https://github.com/Dimaris-nsk)**: Spring camera for
    fresh profiles, rotatable-camera scroll speed, content install failure
    classification, safer rapid backups, and finding the missing
    RapidTagResolutionOrder (Vandomas fork PRs #15-#19).
  - **[yeojuny](https://github.com/yeojuny)**: found the `SHIELD_POWER`
    ARM64/x86 divergence fixed here,
    [RecoilEngine#3421](https://github.com/beyond-all-reason/RecoilEngine/issues/3421).
- **The Beyond All Reason project** — the game, the content network, and
  the reason any of this is worth doing.
- **Mesa / Zink** and **KosmicKrisp** (LunarG, Google) — the driver stack
  that makes GL 4.6 compatibility profile on Metal real.
- **SDL2, openal-soft, streflop**, and the rest of the dependency tree.
- Porting methodology informed by the
  [C&C Generals Apple port](https://github.com/ammaarreshi/Generals-Mac-iOS-iPad)
  (built on [GeneralsX](https://github.com/fbraz3/GeneralsX)).

## License

**GPL-2.0-or-later**, same as the upstream Recoil engine — full text in
[LICENSE](LICENSE). Bundled components keep their own compatible licenses
(streflop/vendored libm under LGPL, the SDL/OpenAL/Mesa stack under MIT/BSD/zlib
— see [COPYING](COPYING) and the component directories). Complete corresponding
source for every shipped binary is this repository plus the pinned/patched
dependency set documented in the release notes.

Beyond All Reason's game content (units, art, sounds, music, maps) is **not
part of this repository or its releases** and is licensed separately by the
BAR project ([their LICENSE.md](https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/LICENSE.md)
— GPL-2.0 for game code; most art under CC-BY-NC-ND-4.0 and other restricted
terms). The app downloads it from BAR's official content network at first
launch.

## Reporting issues

This is an unofficial port: please report problems **on this repository's
issue tracker [here](https://github.com/qant-au/RecoilEngine-AppleSilicon/issues)**, not to the Recoil or BAR projects — a bug here is most likely
this port's fault, and their trackers shouldn't carry our noise.
