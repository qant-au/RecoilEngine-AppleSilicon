# Accurona: The Recoil Engine On Apple Silicon

<p align="center">
  <img src="https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple" alt="macOS on Apple Silicon">
  <img src="https://img.shields.io/badge/license-GPL--2.0--or--later-blue" alt="License: GPL-2.0-or-later">
  <img src="https://img.shields.io/badge/built%20on-Recoil-orange" alt="Built on the Recoil engine">
</p>

**An unofficial native Apple Silicon build of the
[Recoil](https://github.com/beyond-all-reason/RecoilEngine) RTS engine**, with
an optional helper app, Accurona, that sets it up to play
[Beyond All Reason](https://www.beyondallreason.info/) (BAR). No Rosetta and no
virtual machine.

> [!IMPORTANT]
> If you run into a problem, report it
> [here](https://github.com/qant-au/RecoilEngine-AppleSilicon/issues), **not**
> in the official Beyond All Reason or Recoil channels. They cannot help with
> problems caused by this port.

## Status

- **Engine:** an upstream Recoil release tag plus this repository's macOS
  layer. The tag, and every other pinned version, is in
  [docs/VERSIONS.md](docs/VERSIONS.md). The current tag is BAR's Engine Test
  engine, which is ahead of the engine BAR's production servers run, so until
  BAR moves, a build from this tree can replay and join **Engine Test games
  only**.
- **No release has been published yet.** There is nothing to download: the
  way to run it today is to [build it](#building). Builds are ad-hoc signed
  and run on the Mac that built them.
- **Online play is switched off** in every build. No request to connect to
  BAR's servers has been made for this repository yet. Skirmish against AI,
  replays and local-network games work. See [Online Play](#online-play).
- **Simulation:** a public replay recorded by BAR's fleet on this engine
  version re-simulates with every recorded checksum equal, on the macOS build
  and on this tree's own Linux build. What has and has not been run on the
  current engine version is in
  [docs/SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md), section 3b.
- **Against the official Windows and Linux builds:**
  [docs/PARITY.md](docs/PARITY.md) is the row-by-row status.

> [!CAUTION]
> **Unofficial project, third-party game content.** This is an independent
> community port. It is not affiliated with, endorsed by, or supported by the
> Recoil engine team or the Beyond All Reason project. **No game content is
> hosted here**: this repository contains only the engine (GPL-2.0-or-later)
> and this port's packaging. The game itself, **including executable game
> code that the engine runs**, plus its units, art, sounds and maps, under
> [BAR's own licenses](https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/LICENSE.md),
> is downloaded by the helper app from BAR's official content network on
> first launch, after an explicit consent prompt, and may update itself
> later. That code and content is not hosted, vetted or endorsed by this
> project, which accepts no responsibility for it or for any damage it may
> cause. Install and play **at your own risk**.

## What It Is

<p align="center">
  <img src="screenshots/hero.jpg" alt="Beyond All Reason running natively on macOS (Apple Silicon)" width="100%">
  <br><em>Recoil running Beyond All Reason natively on an Apple Silicon Mac.</em>
</p>

The [Recoil engine](https://github.com/beyond-all-reason/RecoilEngine) runs a
game built on it: the simulation, graphics and networking. Upstream ships it
for Windows and Linux. This repository builds it for macOS:

- **Graphics** go through Apple's Metal: OpenGL 4.6 compatibility profile on
  Mesa Zink, on [KosmicKrisp](https://lunarg.com/kosmickrisp/), on Metal. The
  driver is built from a pinned upstream Mesa commit plus the patches in
  `patches/mesa/`.
- **Simulation** has to match the x86 builds bit for bit, because Recoil
  games are lockstep-deterministic. The rules this build follows, and what
  checks each one, are in [docs/DETERMINISM.md](docs/DETERMINISM.md).
- **Two bundles** come out of the build. `make app` makes Accurona, the app
  that (after consent) downloads BAR from its official content network and
  starts its lobby. `make engine-dist` makes the engine alone, in the same
  layout as the official Linux engine archive, with no game content and no
  BAR-specific helper, for any Recoil game or tool.

Upstream's own engine README is
[README-upstream.markdown](README-upstream.markdown).

## Screenshots

<p align="center">
  <img src="screenshots/battle.jpg" width="49%" alt="A battle mid-map, two armies clashing with the full HUD">
  <img src="screenshots/valley.jpg" width="49%" alt="An army massing in a mountain valley">
  <br><em>Real matches, full interface, captured on macOS.</em>
</p>

## Requirements

- An Apple Silicon Mac (tested on M2 and later).
- The macOS version given as the floor in [docs/VERSIONS.md](docs/VERSIONS.md).
- An internet connection on first run of the app: game content downloads from
  BAR's official content network.

## Building

```sh
git clone --recurse-submodules https://github.com/qant-au/RecoilEngine-AppleSilicon.git
cd RecoilEngine-AppleSilicon
git remote add upstream https://github.com/beyond-all-reason/RecoilEngine.git
git fetch upstream --tags     # the build reads the engine version from the release tag
make app                      # Accurona.app, .zip and .dmg in release-artifacts/
```

Prerequisites, every build target, every test with its expected result, and
all configuration keys and environment variables are in
[docs/BUILDING.md](docs/BUILDING.md).

## Online Play

Online play is off in every build, source builds included: the online lobby
resolves to an unreachable loopback address. LAN and local play are not
affected. No request to connect to BAR's community servers has been made for
this repository yet, so do not distribute a build with online play switched
on. `ONLINE=1 make app` is a deliberate local opt-in for testing, and a
Developer ID signed build refuses it.

## What The App Contacts

Before the consent prompt, each launch of Accurona makes three read-only
requests to GitHub and nothing else:

1. the update feed of this repository (is there a newer app),
2. the message file of this repository (`message-config/messages.json`,
   notices for players),
3. BAR's launcher configuration in the BYAR-Chobby repository (which engine
   BAR's production servers run, so the app can say when it is out of date).

After consent, the app downloads game content from BAR's content network. The
lobby then downloads maps, games and its own resources from the same network.

## Known Limitations

- Late-game frame rate in very large games is bounded by the single-threaded
  simulation and game Lua on the main thread. That is a property of the
  engine, not of the graphics stack.
- Geometry shaders are unavailable (Metal has no geometry stage). BAR does
  not need them.
- The checks that have not been run on the current engine version are listed
  in [docs/SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md) and
  [docs/PARITY.md](docs/PARITY.md).

## Documentation

| Document | What It Is |
|---|---|
| [docs/BUILDING.md](docs/BUILDING.md) | Prerequisites, build targets, every test with its command and expected result, configuration keys and environment variables. |
| [docs/PARITY.md](docs/PARITY.md) | Status of the macOS build against the official Windows and Linux builds, row by row. |
| [docs/DETERMINISM.md](docs/DETERMINISM.md) | The determinism contract: what must hold, what may change, and the evidence each kind of change needs. |
| [docs/SYNC_VALIDATION.md](docs/SYNC_VALIDATION.md) | The sync evidence, by engine version, and the register of synced-code changes. |
| [docs/VERSIONS.md](docs/VERSIONS.md) | Every pinned version and why it is pinned. |
| [docs/MAINTENANCE.md](docs/MAINTENANCE.md) | Merging a new upstream release, the submodule forks, the Mesa pin and patches, the non-Mac check. |
| [docs/RELEASING.md](docs/RELEASING.md) | Version number, signing, notarisation, the update feed and its key, the message file, the publish checklist. |
| [docs/UPSTREAM.md](docs/UPSTREAM.md) | Which changes in this layer could go upstream, and the state of each. |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | What the macOS layer changes for performance, and how it was measured. |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms a maintainer may meet when building or testing, with causes and fixes. |
| [message-config/README.md](message-config/README.md) | The in-app message file: format, targeting, how to publish a message. |
| [SECURITY.md](SECURITY.md) | How to report a vulnerability. |

## How It Was Built

Much of the macOS layer was written with an AI coding assistant (Anthropic's
Claude), directed and tested by the maintainers of this repository and of the
original port. Commits say so in their trailers.

## Credits

This port stands on a lot of prior work, gratefully:

- **[Ben Breen](https://github.com/benbreen/RecoilEngine-AppleSilicon)**: the
  original Apple Silicon port this repository continues: the first sync
  validation, the Metal present path, the packaging pipeline and the v0.11 to
  v0.13 releases. That repository is no longer maintained; this one is.
- **[TonyTheCat](https://github.com/TonyTheCat)** (Anton Shishenia): fresh-clone
  build fixes, the source-built SDL2, the hardware cursor and camera fixes, and
  MetalFX upscaling, from
  [PR #20](https://github.com/benbreen/RecoilEngine-AppleSilicon/pull/20) on the
  original repository, merged here with authorship kept. Several commits in
  that pull request, the MetalFX ones among them, were written with an AI
  assistant and carry that authorship; he committed and submitted them.
- **[ExaDev](https://github.com/ExaDev/RecoilEngine)**: the foundational macOS
  fork: first working builds, EGL/Zink bring-up, pr-downloader fixes. Their
  commits form the base of this layer, preserved with attribution.
- **The Recoil engine team**, especially for the ARM64 deterministic
  floating-point work merged in
  [PR #2819](https://github.com/beyond-all-reason/RecoilEngine/pull/2819),
  without which cross-platform lockstep on Apple Silicon would not exist.
- **Fixes taken from other macOS work**, with authorship kept in the commits.
  Most are their authors' open pull requests on Recoil, listed in
  [docs/UPSTREAM.md](docs/UPSTREAM.md):
  - **[Vandomas](https://github.com/Vandomas/RecoilEngine-AppleSilicon)**: sound
    decoding outside the sound lock
    ([RecoilEngine#3276](https://github.com/beyond-all-reason/RecoilEngine/pull/3276));
    rebuilding the picture when the window changes display, Retina mouse
    positions in the engine's own start menu, the hardware cursor default with a
    speed scale, non-blocking UDP sends (#3293), GPU-loss handling, GL debug
    markers, log roll-up fixes, bringing the lobby back after an engine error,
    GPU time per render pass in the profiler, and the savegame fixes, from his
    fork.
  - **[tomjn](https://github.com/tomjn)**: first-vertex provoking on KosmicKrisp
    (#3532), `gl.BeginEnd` in one draw (#3533), rectangle outlines as lines
    (#3272), the SSD path check (#3690), headless S3O decoding (#3700), Lua
    errors instead of crashes on unusable LuaVBOs (#3695), `--window` turning
    fullscreen off again (#3163), and from his macOS integration branch (#3271)
    the GL 3.0 extension-check skip and the Mesa threaded-context patch for
    flipped frames (Mesa issue 16734).
  - **[Leon Seemann](https://github.com/leonseemann)**: macOS keyboard fixes
    (#3540: Cmd as Ctrl, dead keys, AutoFill off, F11/Pause), streamed-buffer
    orphaning (#3542), persistent model uniforms (#3543), LOS/radar PBO uploads
    (#3494), S3TC DDS decompression (#3566), the nano-particle geometry-shader
    check (#3539) and the hardware MAC address through IOKit (#3493).
  - **[ysommer](https://github.com/ysommer)**: macOS crash stack traces and clean
    exit (#3546), hidden symbol visibility (#3545).
  - **[Yeo-Jun Yoon](https://github.com/yeojuny)**: the NEON FPCR check (his
    commit in #3689), the QTPFS failed-load fix (#3694), LuaVBO size and padding
    checks (#3551, #3553), StreamBuffer slot stepping and fence lifetime (#3552,
    #3556), the framebuffer restore after `gl.RenderToTexture` (#3554), archive
    fallback fonts (#3555), the DXT5/BC4/BC5 alpha flip that wrote past the
    block (from #3271), and finding the `SHIELD_POWER` ARM64/x86 divergence
    ([RecoilEngine#3421](https://github.com/beyond-all-reason/RecoilEngine/issues/3421)).
  - **[sprunk](https://github.com/sprunk)**: review changes and the changelog
    snippet on #3551.
  - **[moss-orbit-9f339e](https://github.com/moss-orbit-9f339e)**: headless
    GLSL/NPOT reporting (#3615) and the screenshot deadlock fix (#3631).
  - **[TonyTheCat](https://github.com/TonyTheCat)**: the mouse-cursor texture leak
    ([RecoilEngine#3687](https://github.com/beyond-all-reason/RecoilEngine/issues/3687)).
  - **[smallketchup82](https://github.com/smallketchup82)**: the Apple arm64
    native calls in CircuitAI's bundled AngelScript, which let the Zero-K AI
    start on Apple Silicon, from his
    [ZkMacOS](https://github.com/smallketchup82/ZkMacOS) port; his commit,
    authorship kept, on this project's CircuitAI fork. The design of the
    trackpad camera gestures (`MacTrackpadEnabled`) and of the full-resolution
    interface over a lower-resolution world (`MacCrispInterface`) also follows
    his port, written again for this tree.
  - **[Anatolii / Dimaris-nsk](https://github.com/Dimaris-nsk)**: Spring camera
    for fresh profiles, rotatable-camera scroll speed, content install failure
    classification, safer rapid backups, and finding the missing
    RapidTagResolutionOrder (Vandomas fork PRs #15 to #19).
- **The Beyond All Reason project**: the game, the content network, and the
  reason any of this is worth doing.
- **Mesa / Zink** and **KosmicKrisp** (LunarG, Google): the driver stack that
  makes the OpenGL 4.6 compatibility profile on Metal real.
- **SDL2, openal-soft, streflop**, and the rest of the dependency tree.
- Porting methodology informed by the
  [C&C Generals Apple port](https://github.com/ammaarreshi/Generals-Mac-iOS-iPad)
  (built on [GeneralsX](https://github.com/fbraz3/GeneralsX)).

## License

**GPL-2.0-or-later**, the same as the upstream Recoil engine. The GPL text is
in [LICENSE](LICENSE), and the notices for third-party code inside the engine
source are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

A built app carries its own license set, collected from the source trees at
build time: `COPYING` (the GPL text), `NOTICE` (what the bundle contains and
where its source is) and `LICENSES/` (the text for every bundled library,
with `MANIFEST.tsv` naming each one). The LGPL-2.1 components are
openal-soft, DevIL and streflop (part of the engine source); `NOTICE` says
how each is linked. The complete
corresponding source for every binary in a bundle is this repository at the
commit it was built from, plus the pinned dependencies listed in
[docs/VERSIONS.md](docs/VERSIONS.md).

Beyond All Reason's game content (units, art, sounds, music, maps) is **not
part of this repository** and is licensed separately by the BAR project
([their LICENSE.md](https://github.com/beyond-all-reason/Beyond-All-Reason/blob/master/LICENSE.md):
GPL-2.0 for game code; most art under CC-BY-NC-ND-4.0 and other restricted
terms). The app downloads it from BAR's official content network at first
launch.

## Reporting Issues

This is an unofficial port: please report problems on
[this repository's issue tracker](https://github.com/qant-au/RecoilEngine-AppleSilicon/issues),
not to the Recoil or BAR projects. A bug here is most likely this port's
fault, and their trackers should not carry it.
