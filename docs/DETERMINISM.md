# The Determinism Contract

Recoil games are lockstep-deterministic. Every client simulates the whole
game and only player commands cross the network, so every machine must
compute bit-identical results for every operation in the simulation. One
differing bit is a desync, for every player in the match.

Upstream builds the engine with gcc for x86. This repository builds it with
AppleClang for arm64. This page states what has to hold for the two to agree,
what in this repository may change, and what evidence each kind of change
needs. The evidence itself is in [SYNC_VALIDATION.md](SYNC_VALIDATION.md).

## What Must Hold On arm64

Most of this comes from upstream's own ARM64 work
([RecoilEngine#2819](https://github.com/beyond-all-reason/RecoilEngine/pull/2819)).
None of it may regress.

| Rule | Where It Is Set | What Checks It |
|---|---|---|
| Synced floating-point math goes through streflop in NEON mode. streflop's initialisation sets the FPCR rounding mode to round-to-nearest and the flush-to-zero bit to match its denormal setting. It does not touch the default-NaN bit, which stays 0 as the process starts. | `rts/lib/streflop` (the upstream submodule, unchanged) | `good_fpu_control_registers` in `rts/System/Sync/FPUCheck.cpp` re-applies streflop's settings and logs a sync warning when the rounding mode or the flush-to-zero bit has drifted |
| No fused multiply-add in engine code: `-ffp-contract=off` for every translation unit on arm64. One compiler-emitted `fmadd` in synced code is a one-ULP difference from x86. | `rts/build/cmake/TestCXXFlags.cmake`; the static libraries use the same flag (`scripts/build-static-libs.sh`) | the streflop sync test; the replay check |
| No `-ffast-math` and no `-Ofast` anywhere in engine code. | the CMake configuration | review |
| SSE intrinsics in engine code go through sse2neon with its `SSE2NEON_PRECISE_*` options left off, as upstream has them. | `rts/lib/sse2neon` (the upstream submodule) | the replay check |
| The streflop float functions give the same bits as the x86 SSE build. | streflop | `scripts/run-synctest.sh`: bit-exact against the committed x86 SSE reference and the committed NEON reference |
| The double-precision libm functions give the same bits as the fleet's gcc build. The fleet compiles them with gcc's `-fsingle-precision-constant`, which clang does not have, so the build recompiles those objects with gcc and swaps them into the streflop archive. | `scripts/gcc-dbl64-swap.sh`, called by `scripts/build-engine.sh` | the libm parity gate in `scripts/build-engine.sh`, and `scripts/check-dbl64-marker.sh` on the built binaries |

Two facts about the last row, measured on the current engine version. No
engine binary links a double-precision libm function today, on macOS or in
the x86 Linux build of the same tree: play runs on the float functions only.
The swap is kept as a guard, so that a double function linked in future comes
from the gcc objects, and the build fails if it does not.

Always build through `scripts/build-engine.sh` or `make`. A bare `ninja` in
the build folder relinks without the swap and runs none of the checks.

## What May Change, And The Evidence It Needs

| Kind Of Change | Allowed | Evidence Before It Is Pushed |
|---|---|---|
| Unsynced code: rendering, the present path, windowing, input, sound, platform files, packaging | Yes | The build and the test that covers the area ([BUILDING.md](BUILDING.md)): visual regression for anything drawn, unit tests, packaging tests. The Linux and Windows check when the file is shared with other platforms. |
| Compiler, compiler flags, the toolchain, streflop, the libm swap | Only with a reason, and never to make something faster | The streflop sync test, the libm parity gate, and the replay check on a fleet demo. |
| Synced code: `rts/Sim`, `rts/Lua/LuaSynced*`, `rts/System/Sync`, the math headers, anything else that can reach checksummed state | Only in the two cases below | A row in the register (see below), the replay check on a fleet demo recorded on this engine version, and, when the change applies to every platform, the same replay on this tree's Linux build. |
| The engine version | By merging an upstream release tag ([MAINTENANCE.md](MAINTENANCE.md)) | Every test again. Evidence from one engine version does not certify another. |
| Game content | Never | Not applicable. Game Lua is downloaded, checksummed and identical for every player. If a fix seems to need a change to game Lua, it is an engine bug being worked around in the wrong place. |

Synced code may change in two cases only:

1. **To make arm64 compute what x86 already computes.** For example, a
   float-to-integer conversion whose out-of-range result is undefined in C++
   and differs between the two instruction sets. The change must leave every
   x86 result as it was.
2. **To carry a fix that upstream has merged or has open.** It is carried
   unchanged and dropped when the tag that contains it is merged.

Never in synced code: a result that differs on macOS on purpose
(`#ifdef __APPLE__` around behaviour), an optimisation, or a change that
upstream's maintainers have declined. This repository follows the upstream
maintainers: a change they reject is removed here, so that a game built for
one engine runs on the other.

## The Register

Every change the macOS layer makes to code that can reach synced state is
listed in [SYNC_VALIDATION.md, Appendix A](SYNC_VALIDATION.md#appendix-a--register-of-synced-code-changes),
with the reason the fleet's x86 results are unchanged. It is read off the
diff against the upstream tag, with the command printed above it. Regenerate
it at every engine merge and whenever one of those paths changes. A synced
change without a row there is not finished.

## Version Identity

Every client in a game must run the same engine version doing the same math.
A build from this repository is an upstream release tag plus the macOS layer,
and it reports that tag as its version. Which tag, and what it can therefore
connect to, is in [VERSIONS.md](VERSIONS.md). When the tag is ahead of the
engine BAR's production servers run, the build can replay and join only games
on that newer engine.

## Known Limits

- **A NaN in synced state would desync a Mac.** The NaN produced by an
  invalid operation (for example `0.0 / 0.0`) has its sign bit set on x86 and
  clear on arm64. The checksums cover the raw bits, so a NaN that reaches
  checksummed state differs between the two whatever the FPCR default-NaN bit
  is. Correct synced code does not produce NaN; treat any NaN in a state dump
  as a bug to report upstream, not as noise.
- **Two double-precision functions in streflop return NaN near zero.**
  `expm1(x)` and `cosh(x)` return NaN for `|x|` below 2^-54 on every
  platform, the x86 fleet included, because `-fsingle-precision-constant`
  turns the library's `1.0e+300` into a float infinity. Nothing in the engine
  calls either on doubles. The parity gate hashes every NaN as one value for
  this reason.
- **Heading conversions above 2^31.** Seven float-to-short heading
  conversions go through `int`. Below 2^31 arm64 and x86 agree. From 2^31
  upward x86 gives 0 and arm64 gives -1. Game Lua would have to pass such a
  heading on purpose.
- **Two compilers.** streflop makes floating-point results independent of
  the compiler where streflop is used. Everything else that is synced relies
  on IEEE 754 and identical operation order. For a desync with no obvious
  cause, suspect undefined behaviour or order-of-evaluation differences
  between gcc and clang first, and check whether the same demo desyncs on a
  clang-built Linux engine, which separates the compiler from the platform.

## Finding A Desync

Work from evidence, not from guesses about flags. The engine checksums the
synced state every frame, demos carry the recording clients' checksums, and
`spring-headless` replays a demo through the full simulation
(`scripts/replay-check.sh`). To find where two builds part, set
`SPRING_DUMP_STATE_RANGE=min:max` during playback on both: it dumps the full
synced state (random number generator, units, features, projectiles, raw
floats) for each frame in the range, and the first differing line names the
frame and the subsystem.

## Check What Was Built, Not The Exit Code

After a build, the scripts check the artifacts themselves: architecture,
linked libraries, the libm hashes, the deployment target, embedded builder
paths. At run time the engine refuses a software renderer unless
`SPRING_ALLOW_SOFTWARE_GL=1` is set, and the log names the renderer (Zink on
KosmicKrisp). A test passes when it prints its `*_OK` line, not when it exits.
