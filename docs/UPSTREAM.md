# Upstream Status

What in the macOS layer could go to the Recoil project, what already belongs
to someone else's pull request there, and what stays here. The layer should
get smaller over time: every change that lands upstream is one fewer to carry
through the next merge.

Pull request and issue numbers are on
[beyond-all-reason/RecoilEngine](https://github.com/beyond-all-reason/RecoilEngine)
unless a row says otherwise. States were read on 2026-11-10; re-read them
before acting on a row.

## Rules That Apply

- Upstream's `AI_POLICY.md`: disclose all AI use; AI-assisted pull requests
  only for accepted issues; fully verified by a person; no AI code for a
  platform you cannot test by hand.
- Upstream's `contributing.md`: work not covered by a ticket needs one, or a
  talk with the responsible developer, first. "Recoil is not just for BAR":
  no game-specific design in the engine. Small pull requests; pure refactor
  commits in front.
- A pull request must build on Linux amd64, Linux arm64 and Windows amd64.
  Upstream has no macOS CI job.
- A visible change needs a changelog snippet in `doc/pr-changelogs/`.
- Tabs in `*.cpp`, `*.h`, `*.lua` and CMake; the GPL header line on every
  source file.
- Mesa has its own rules for driver patches: a GitLab merge request by a
  person, subject and body within 75 columns, commit messages written by
  hand, AI help disclosed with an `Assisted-by:` or `Generated-by:` tag.

Upstream's macOS path is its own integration series: draft #3271 with its
child pull requests, tracked under issue #936. A second, larger
implementation of the same pieces will not be reviewed beside it. What this
repository can usefully give that series is testing on Apple hardware.

## Ours To Offer

Smallest and most independent first. Each needs an upstream issue before
code. None has been opened yet.

| Change | Files | Upstream | Status |
|---|---|---|---|
| Ignore capture devices in audio hot-plug events | `rts/System/SpringApp.cpp` | follow-up to merged #3340 | not opened |
| TextureAtlas: null-check `GetTexID` and log why `Finalize` failed | `rts/Rendering/Textures/TextureAtlas.h`, `TextureAtlas.cpp` | none | not opened |
| Do not terminate on joinable ext threads at exit | branch `pr/extthreads-joinable-exit` | none | branch prepared; needs an issue, an upstream-style title, and credit to its original author. Upstream may ask for the cause (an `exit()` off the main thread) to be fixed |
| Resume music after a buffer underrun | `rts/System/Sound/OpenAL/MusicStream.cpp` | none | not opened |
| Sim: avoid undefined behaviour in the remaining float-to-short heading casts | `rts/Sim/MoveTypes/HoverAirMoveType.cpp`, `rts/Sim/Path/IPathController.cpp`, `rts/Lua/LuaSyncedMoveCtrl.cpp`, `rts/Lua/LuaSyncedRead.cpp` | precedent: merged #3342 | not opened. Synced. Make the seven sites agree with x86 above 2^31 first (see [DETERMINISM.md](DETERMINISM.md), Known Limits) |
| COB: give `SHIELD_POWER` a defined result outside `int` range | `rts/Sim/Units/Scripts/UnitScript.cpp` | issue #3421 (open) | ask on the issue before sending code: a maintainer leans toward removing `SHIELD_POWER` |
| Restore shader uniforms before validating a re-linked program | `rts/Rendering/Shaders/Shader.cpp` | none | not opened. Changes every driver, so it needs a Linux and a Windows run |
| Add a `WindowTitle` setting | `rts/System/SpringApp.cpp` | none | not opened. Needs a changelog snippet |
| macOS: native message box; system font directories; the Local Network privacy message; the saved window size on HiDPI | `rts/System/Platform/Mac/MessageBox.cpp`, `rts/Rendering/Fonts/CFontTexture.cpp`, `rts/System/Net/Socket.cpp`, `rts/Rendering/GlobalRendering.cpp` | #3271 series | hold until that series settles, then offer as follow-ups |

Found while working on the layer, to report rather than to patch:

- streflop's double `expm1` and `cosh` return NaN near zero on every platform
  ([DETERMINISM.md](DETERMINISM.md), Known Limits).
- #3022 tests the GL version before it has been read, so its early return
  never fires.
- #3293 retries a send on `try_again`, which Windows never returns for a full
  send buffer (`would_block` there). Fixed in this tree.
- #3533 reads GL state while a display list is being compiled. In this tree
  the plain calls are recorded inside `gl.CreateList`.
- #3566: the decompression buffer was sized from unchecked header
  dimensions. Bounded in this tree.

None of these has been posted upstream yet.

## Carried From Other People's Open Pull Requests

Not ours to submit. Each is carried with its author's name on the commit and
drops out of the layer when the tag that contains it is merged. Testing them
on a Mac and reporting the result on the pull request is the useful
contribution.

| Pull Request | Author | What It Is | State |
|---|---|---|---|
| #3276 | Vandomas | Do not hold the sound mutex while decoding sounds | open |
| #3293 | Vandomas | Never block the main thread on UDP sends | open |
| #3341 | Vandomas | `EdgeMoveWidth=0` disables edge scrolling | open |
| #3493 | leonseemann | macOS: hardware MAC address through IOKit | open |
| #3494 | leonseemann | LOS and radar textures uploaded through PBOs | open |
| #3516 | leonseemann | LuaVAO: primitive restart only for connected primitives | open |
| #3539 | leonseemann | Work around missing wireframe fill and geometry shaders on KosmicKrisp | open |
| #3540 | leonseemann | macOS keyboard fixes: dead keys, Command as Control, F11/Pause, AutoFill | open |
| #3542 | leonseemann | Orphan streamed render buffers once per frame | open |
| #3543 | leonseemann | Stream model uniforms through a persistently mapped buffer | open |
| #3545 | leonseemann | macOS: hidden symbol visibility, as on Linux | open |
| #3546 | leonseemann | macOS: write the crash stack trace and exit cleanly | open |
| #3566 | leonseemann | Decompress S3TC DDS textures that need generated mipmaps | open |
| #3022 | tomjn | Skip the legacy ARB extension check on GL 3.0 and newer | open |
| #3163 | tomjn | `--window` turns fullscreen off again | open |
| #3272 | tomjn | Rectangle outlines as line primitives | open |
| #3532 | tomjn | First-vertex provoking on KosmicKrisp | open |
| #3533 | tomjn | `gl.BeginEnd` blocks drawn with one `glDrawArrays` | open |
| #3537 | tomjn | Do not pump window events from the loading thread | open |
| #3551 to #3556 | tomjn | LuaVBO size limits and padding, StreamBuffer slot offsets and fence lifetime, the framebuffer restore after `gl.RenderToTexture`, archive fallback fonts | open |
| #3689 | tomjn | Check the FPCR on NEON in `good_fpu_control_registers` | open |
| #3691 | tomjn | nv_dds: `flip_dxt5_alpha` wrote past the block | open |
| #3694 | tomjn | QTPFS: do not read system components that were never created | open |
| #3695 | tomjn | LuaVBO: Lua errors instead of crashes on unusable buffers | open |
| #3700 | tomjn | Headless: do not decode S3O textures that are never drawn | open |
| #3615 | moss-orbit-9f339e | Headless builds report no GLSL or NPOT support | open |
| #3631 | moss-orbit-9f339e | Log outside the texture pool mutex when saving a bitmap | open |
| #3271 | tomjn | macOS integration branch (the GL 3.0 check and the DXT alpha fix came from it) | draft |

## Already Upstream

| Pull Request | What It Is | Where |
|---|---|---|
| #3342 | Float-to-short heading casts | in the current tag |
| #3289 | `views::enumerate` fallback for libc++ | in the current tag |
| #3290 | `testClampRad` undefined conversion | in the current tag |
| #3340 | Audio output closed when a device is added | merged |
| #3690 | macOS: the spinning-disk warning on every archive | merged on master; ours drops at the next tag that has it |

## Declined Upstream, Removed Here

| Pull Request | What It Was | Outcome |
|---|---|---|
| #3280 | Destroy loader-created objects on a failed load (destructor guards) | closed after a maintainer objected. Removed from this layer: a change upstream declines is not carried |

## Prepared Branches

| Branch | State |
|---|---|
| `pr/extthreads-joinable-exit` | the one to keep; see the table above |
| `pr/fastmath-sqrtf-decl` | do not open: #3046 (open) edits the same lines |
| `pr/mac-threading-solib` | do not open: #3044 (open) adds the same line |
| `pr/minizip-include-system` | do not open: draft #3160 contains the same change |

## Staying Downstream For Now

- **The present path, MetalFX upscaling and the window policy**
  (`rts/System/Platform/Mac/`). They are a different design from the EGL
  bridge in upstream's series (#3538). They stay here until that series
  lands; then the measurements and any follow-ups can be offered on top of it.
- **Test and support switches** (the environment variables in
  [BUILDING.md](BUILDING.md)). Upstream uses configuration keys and Tracy.
- **Packaging** (`packaging/`, `scripts/`, `message-config/`, the `Makefile`).
  It is a product, not engine code.

## Submodule Forks

| Submodule | Fork | What It Carries | Upstream |
|---|---|---|---|
| `tools/pr-downloader` | `qant-au/pr-downloader` | one commit: HTTP/1.1 for BAR's content network on macOS | not offered yet |
| `AI/Skirmish/BARb` | `qant-au/CircuitAI` | one commit: the AngelScript arm64 assembly file for Apple in CMake. Upstream CircuitAI already has it (its #140), so the fork commit is redundant and the submodule can go back to upstream's commit once that is build-tested | merged upstream |
| `AI/Skirmish/CircuitAI` | none (upstream `rlcevg/CircuitAI`) | `patches/circuitai/0001` is applied to the working tree at build time | not offered yet |

## Mesa Patches

The ten files in `patches/mesa/`, against the pin in
[VERSIONS.md](VERSIONS.md). None has been submitted to Mesa.

| Patch | Subject | Offer To Mesa? |
|---|---|---|
| 0001 | poly: barrier after reading the shared scratch pointer | yes |
| 0002 | kosmickrisp: clear uploader bump state on release | yes |
| 0003 | kosmickrisp: zero-initialise device memory allocations | only reworked (behind a driver option) |
| 0004 | kosmickrisp: log the loaded library path and version | no: for this bundle's own check |
| 0005 | kosmickrisp: `fillModeNonSolid` through Metal triangle fill mode | only reworked: it maps point fill to lines and would fail conformance |
| 0006 | zink: try `@rpath/libvulkan.1.dylib` first | no: specific to an app bundle |
| 0007 | kosmickrisp: save and restore push-descriptor data and layout | yes |
| 0008 | zink: keep `vertex_buffers_dirty` on an empty unbind | yes |
| 0009 | kosmickrisp: reset the geometry heap once per frame | yes |
| 0010 | gallium/tc: do not carry an ended renderpass into the next batch | no: fixed in Mesa main after the pin; drop it when the pin moves past the fix |

Before any is sent: re-check it against Mesa main, rewrite its message by
hand within 75 columns with no reference to this project or its tracker, and
add the disclosure tag.

## Before Approaching The Community

1. Do not open the three duplicate branches.
2. Test the open upstream macOS pull requests on this Mac and post the
   results on them.
3. Ask in #936 or #3271 what counts as an accepted issue for macOS work, and
   ask on #3421 before sending the `SHIELD_POWER` change.
4. Offer a working, tested Mac build and test capacity, not a competing
   merge.
