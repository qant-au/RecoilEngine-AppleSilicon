# Maintenance

How the macOS layer follows upstream: where the repository stands, how a new
upstream release is merged, the submodule forks, the Mesa pin and patches,
and the check that keeps the Linux and Windows builds working. Version
numbers are in [VERSIONS.md](VERSIONS.md). Releasing is in
[RELEASING.md](RELEASING.md).

## The Model

`main` is an upstream Recoil release tag with the macOS layer on top. A new
upstream release is **merged** into `main`; `main` is never rebased or
rewritten. The layer is whatever `git diff <tag> main` shows.

Keep the layer small and scoped, so each piece can go upstream and a merge
stays mechanical:

- platform code under `rts/System/Platform/Mac/`;
- a change to a shared file is guarded for Apple unless it is a fix every
  platform should have, and then it is written so upstream could take it
  as it is;
- synced code changes only under the rules in
  [DETERMINISM.md](DETERMINISM.md);
- a change upstream's maintainers decline is removed here, so games stay
  portable between this build and theirs ([UPSTREAM.md](UPSTREAM.md)).

## Where The Repository Stands

- **Base:** the upstream release tag named in [VERSIONS.md](VERSIONS.md). It
  was merged on 2026-11-09 (commit `c3f400b6cd`). It is BAR's Engine Test
  engine and is ahead of production by decision: releases target the engine
  BAR is moving to. Measure which engine each BAR setup runs; do not assume:
  [BYAR-Chobby `dist_cfg/config.json`](https://github.com/beyond-all-reason/BYAR-Chobby/blob/master/dist_cfg/config.json)
  (`manual-linux` and `manual-win` are production, the `*-test-engine`
  entries are the next engine).
- **Against upstream `master`:** Recoil cuts releases on branches, so a
  release tag is not on `master` and "behind master" is mostly unreleased
  work. Measure with `git rev-list --left-right --count upstream/master...main`.
  Follow release tags; watch `master` for fixes worth carrying.
- **Remotes:** `origin` is this repository. `upstream` is
  `beyond-all-reason/RecoilEngine`, fetch only. The original port and another
  fork of it are kept as fetch-only remotes for reference.
- **CI:** GitHub Actions are disabled on this repository by decision. Every
  build and test is local. The workflows inherited from upstream that publish
  or act for BAR are also disabled one by one on GitHub (`gh workflow
  disable`), so the files stay identical to upstream and merges stay clean.
  There is no macOS job upstream. Check the state with
  `gh api repos/qant-au/RecoilEngine-AppleSilicon/actions/workflows --jq '.workflows[]|[.path,.state]|@tsv'`.
- **Branch protection:** `main` cannot be force-pushed or deleted.

## Merging A New Upstream Release

Do this when BAR's Engine Test channel moves to a new engine version `NEW`.

1. **Fetch and merge the tag.**

   ```sh
   git fetch upstream --tags
   git checkout main
   git merge NEW
   ```

   Resolve conflicts in the macOS files. A change of ours that the new tag
   now contains is dropped in favour of upstream's version, also when ours
   differs: once the fleet runs upstream's code, sync must match theirs. If a
   conflict forces a new change under `rts/Sim/` or in streflop, stop: that is
   a determinism question, not a merge chore.
2. **Move the submodule forks.** `tools/pr-downloader` and
   `AI/Skirmish/CircuitAI` are forks with one commit each on a branch named
   for the engine version. For each: create a branch at the commit the new tag
   pins, re-apply our commit (or drop it if upstream has it), push the
   branch, and update `.gitmodules` and the submodule pointer. See
   [Submodule Forks](#submodule-forks).
3. **Update the BYAR-Chobby pin.** `SHIP_CHOBBY_COMMIT` in
   `packaging/ship-config.sh` names the BYAR-Chobby commit whose launcher
   configuration the app ships. Move it to a commit that lists `NEW`.
4. **Build and run every test** in [BUILDING.md](BUILDING.md):
   `make engine`, `scripts/run-synctest.sh`, `scripts/run-unit-tests.sh`,
   `make test`. The libm and streflop references are regenerated only if the
   new tag changed streflop on purpose; otherwise a difference there is a
   bug, not an update. If the unit-test result changed, find out whether
   upstream's did.
5. **Get a fleet demo recorded on `NEW`** and run the replay check on it.
   A demo from the old version cannot be used: the check refuses it.
   `scripts/find-fleet-replays.py NEW` lists public ones. Prefer a 1v1, a
   full team game and a Raptors or Scavengers game. Run the same demos
   through `scripts/sanitize-replay.sh` and treat every conversion it reports
   in synced code as a finding.
6. **Make new visual-regression baselines.** The pictures are stored per
   engine version and demo (`testkit/visreg/<engine>/<demo>/`). Run
   `scripts/visreg.sh --demo <new demo>`, look at every picture, and only
   then `--bless`. Update the script's default demo.
7. **Run the Linux and Windows check** (`scripts/check-nonmac.sh`), then the
   same replay on the Linux build it produced, and go through the
   [Non-Mac Runtime Checklist](#non-mac-runtime-checklist).
8. **Regenerate the register** of synced-code changes
   ([SYNC_VALIDATION.md](SYNC_VALIDATION.md), Appendix A) from the diff, with
   the command printed there, and add an evidence section for `NEW`.
9. **Update the documents:** [VERSIONS.md](VERSIONS.md) (never move a pin
   silently), [PARITY.md](PARITY.md) (re-measure the rows, change the date),
   [UPSTREAM.md](UPSTREAM.md) (rows that are now in the tag).
10. **`make certify`**, then commit and push.

Players on an older app are told by themselves: the app compares its engine
with BAR's production engine at each launch ([RELEASING.md](RELEASING.md),
The Engine Notice).

## Submodule Forks

| Submodule | Fork And Branch | Our Change |
|---|---|---|
| `tools/pr-downloader` | `qant-au/pr-downloader`, branch `macos-<engine>` | one commit on upstream's pin: HTTP/1.1 for BAR's content network on macOS |
| `AI/Skirmish/BARb` | none: upstream's commit and address, as in the engine tag | none |
| `AI/Skirmish/CircuitAI` | `qant-au/CircuitAI`, branch `macos-arm64-native-calls-zk-<engine>` | one commit on upstream's pin, by smallketchup82 (authorship kept): AngelScript native calls on Apple arm64, its assembly file in CMake, and the Apple assembler labels |

The forks must stay public at the commits a release was built from: they are
part of the corresponding source. The exact commits are in
[VERSIONS.md](VERSIONS.md).

## The Mesa Driver

The app ships Mesa's Zink and KosmicKrisp drivers, built by
`scripts/build-mesa-kk.sh` from a pinned upstream commit plus the patches in
`patches/mesa/`. `make engine` and `make app` call the script; it does
nothing when the installed driver is current.

**How it decides.** Each driver prefix holds a provenance stamp,
`.driver-provenance`: the Mesa commit, the hash of every patch, the
SPIRV-LLVM-Translator tag, the driver dependencies, the macOS target, and a
hash of the script's own commands. The driver is rebuilt when the stamp the
script would write differs from the one installed. A driver with no stamp is
kept and reported, never rebuilt silently; `MESA_FORCE_REBUILD=1` rebuilds it.
A release build refuses an unstamped driver.

**Two prefixes.** `deps/mesa-native` serves `make engine` and the test
scripts. `deps/mesa-native-release` serves the app targets. Each is built and
stamped on its own, so a change rebuilds both, each at its next use.

### Changing A Patch

1. Add, edit or remove a file in `patches/mesa/`. Patches are applied with
   `git apply` in file-name order, so the four-digit prefix is the order.
   Keep the numbering dense and the names descriptive.
2. Run `make engine`. The changed patch hash makes the stamp differ, so the
   driver is rebuilt from a clean checkout of the pin. A patch that does not
   apply stops the build and names itself.
3. Run `scripts/gpu-smoke.sh`, then `make app` and `scripts/visreg.sh`
   (the app build rebuilds the release prefix). For a change that could
   affect speed, compare frame rates before and after
   ([PERFORMANCE.md](PERFORMANCE.md)).
4. Update the Mesa row in [VERSIONS.md](VERSIONS.md) and the patch table in
   [UPSTREAM.md](UPSTREAM.md).

### Moving The Pin

1. Set `MESA_COMMIT` in `scripts/build-mesa-kk.sh` to the new commit.
2. Check each patch against it: drop those upstream has taken, port those
   that no longer apply. `git apply --check` in `deps/mesa-src` tells you
   which.
3. Then as above from step 2. Look at every visual-regression picture, not
   only the pass line: a new driver can change the picture within the limits.
4. Record in [VERSIONS.md](VERSIONS.md) what was dropped, ported and kept.

The driver build takes its other inputs from pins as well: the Vulkan loader,
SPIRV-Tools and zstd (`scripts/build-driver-deps.sh`), the translator tag and
commit in the script itself, libclc (`scripts/build-libclc.sh`) and the Python
packages for Mesa's code generators (`scripts/mesa-venv-requirements.txt`).
LLVM 19 comes from Homebrew and is a build tool only: the build stops if any
LLVM code ends up in a driver library, and if a driver library depends on
anything under a package manager's prefix.

## The Linux And Windows Check

This layer edits shared files, and a Linux or Windows break does not show in
a Mac build. Before pushing a change outside `rts/System/Platform/Mac`,
`packaging/` and `scripts/`, run `scripts/check-nonmac.sh`: it builds this
tree for Linux and Windows in upstream's build images and runs the unit tests
on Linux. It prints `NONMAC_OK`.

### Non-Mac Runtime Checklist

The check above builds; it does not run the clients. These changes in shared
code alter behaviour on Linux and Windows too. Most come from upstream pull
requests, and no defect is known in any of them, but before a release run a
Linux client and a Windows client and look at each:

| Change | Where | What To Look At |
|---|---|---|
| Fence wait raised from 1 ns to 250 microseconds, with an abort on a failed fence | `rts/Rendering/GL/StreamBuffer.cpp`, `StreamBuffer.h` | a long game with many units: no stall, no abort |
| Stream buffers orphaned once per frame | `rts/Rendering/GL/StreamBuffer.cpp` | frame rate against the official build |
| Model uniforms through a persistently mapped ring | `rts/Rendering/ModelsDataUploader.cpp` | units draw with correct transforms and team colours |
| Info textures uploaded through a re-specified buffer | `rts/Rendering/Map/InfoTexture/Modern/ModernInfoTexture.cpp` | LOS, radar and height overlays |
| Uniform state restored before shader validation | `rts/Rendering/Shaders/Shader.cpp` | maps with shadows and sky reflections; toggling an info overlay |
| `--window` precedence over the fullscreen setting | `rts/Rendering/GlobalRendering.cpp` | start with and without `--window` |
| The loading thread no longer pumps window events | `rts/Game/LoadScreen.cpp` | the window stays responsive while a game loads |
| Outlines drawn as line primitives | `rts/Game/UI/StartPosSelecter.cpp`, `rts/Rendering/CommandDrawer.cpp` | start boxes, command and selection outlines |
| S3O textures not decoded in headless builds | `rts/Rendering/Textures/S3OTextureHandler.cpp` | a headless replay; a normal game still textures models |
| Sound decoded outside the sound mutex | `rts/System/Sound/OpenAL/Sound.cpp` | sound effects in a busy battle |
| Music restarted after a buffer underrun | `rts/System/Sound/OpenAL/MusicStream.cpp` | music survives a long load |
| Capture devices ignored in audio hot-plug events | `rts/System/SpringApp.cpp` | plugging a microphone in does not reset sound |
| Load-side serialisation validation | `rts/System/creg/Serializer.cpp` | save a game and load it |
| UDP sends never block; one retry on a full send buffer | `rts/System/Net/UDPConnection.cpp` | a multiplayer game on a slow link: no packet-loss warnings in the log |
| `EdgeMoveWidth = 0` turns edge scrolling off (upstream clamps to one pixel) | `rts/Game/Camera.cpp` | with the setting at 0, the pointer at a screen edge does not scroll |
| The legacy ARB extension check is skipped on GL 3.0 and newer | `rts/Rendering/GlobalRendering.cpp` | the engine starts on a GL 3 or newer driver as before |
| `gl.GPUStamp` accepts 64 distinct labels; a call dropped in a buffered `gl.BeginEnd` block is logged once | `rts/Lua/LuaOpenGL.cpp` | no new warning in the log of a normal game |

## Working On The Layer

- **Reproduce first.** Do not start on a bug until there is a way to
  reproduce it, and do not add a feature without a way to test it.
- **Fix the cause.** If something works on other platforms and not on macOS,
  find out why before changing logic for Apple. Upstream will ask the same
  question.
- **Check upstream first** for an existing report or fix, and prefer carrying
  theirs over writing ours.
- **Test what the change can reach.** Anything drawn: visual regression, with
  a look at the pictures. Anything in shared code: the Linux and Windows
  check. Anything near synced code: [DETERMINISM.md](DETERMINISM.md).
- **One concern per commit**, and a message that says what changed and why.
- **Carry other people's commits with `git cherry-pick -x`**, so the author
  and the commit it came from stay exact.
- **Keep reports diagnosable.** Every engine log names the package version,
  the engine version and the game content. When a bug cannot be reproduced,
  add the log lines that would identify it next time.
- **Do not move a pin silently.** Every pin is in
  [VERSIONS.md](VERSIONS.md) with the script that enforces it.
- **Report bugs noticed along the way**, even when they are not the task.

Issues for this build go to
[this repository's tracker](https://github.com/qant-au/RecoilEngine-AppleSilicon/issues),
never to the Recoil or BAR projects.
