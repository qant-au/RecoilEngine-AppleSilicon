# Performance

How the macOS build gets its frame rate, which switches control it, and how to
measure it.

The graphics stack is Recoil (OpenGL 4.6 compatibility profile) on Mesa Zink, on
KosmicKrisp, on Metal. Most of the work below is the same story told several
times: the engine did something that costs nothing on a native OpenGL driver
and a lot on a translation stack. The fixes change how the stack is fed, not
what is drawn.

Nothing here touches the simulation. Rendering and presentation are unsynced.
Determinism is covered in [DETERMINISM.md](DETERMINISM.md) and
[SYNC_VALIDATION.md](SYNC_VALIDATION.md). Version pins for the engine and the
driver are in [VERSIONS.md](VERSIONS.md).

## Summary

| Change | Code | Switch |
|---|---|---|
| Primitive restart only where it has meaning | `rts/Lua/LuaVAOImpl.cpp` | `SPRING_LUAVAO_FORCE_RESTART=1` (environment) restores the old behaviour |
| Present through a GPU readback ring | `rts/System/Platform/Mac/MacPresentBackend.mm` | `SPRING_MAC_LEGACY_PRESENT=1` (environment) forces the slow CPU path |
| Present off the render thread | `rts/System/Platform/Mac/MetalPresent.mm` | none |
| Deeper upload ring, blocking fence waits | `rts/Rendering/ModelsDataUploader.cpp`, `rts/Rendering/GL/StreamBuffer.cpp` | `SPRING_MAC_UPLOAD_BUFFERING`, `SPRING_MAC_STREAM_BUFFERING` (environment) |
| Direct present from unified memory | `rts/System/Platform/Mac/MacPresentBackend.mm`, `MetalPresent.mm` | `MacPresentDirect` (config) |
| Worker threads kept off the efficiency cores | `rts/System/Threading/ThreadPool.cpp` | `MacWorkerQos` (config) |
| Render density capped to the panel and the GPU | `rts/System/Platform/Mac/MacPresentBackend.mm` | `SPRING_MAC_FULL_BACKING=1`, `SPRING_MAC_NO_RETINA=1` (environment) |
| Render scale and upscaler | `rts/System/Platform/Mac/MacPresentBackend.mm`, `MetalPresent.mm` | `MacRenderScale`, `MacUpscaler` (config) |
| Buffered `gl.BeginEnd` drawing from Lua | `rts/Lua/LuaOpenGL.cpp` | `LuaImmediateModeBuffering` (config) |
| Pacing to the display | `rts/System/Platform/Mac/MetalPresent.mm` | `VSync` (config) |

"Config" means a key in `springsettings.cfg`. "Environment" means an environment
variable read once at startup. The environment variables are support and debug
switches, not settings for players.

## Primitive Restart Only Where It Has Meaning

- **Problem.** `LuaVAOImpl` enabled `GL_PRIMITIVE_RESTART` around every indexed
  draw, including triangle lists.
- **Cause.** A native driver ignores restart on list topologies, so this was
  free. Here it is not. The engine's restart index for 32-bit index buffers is
  not the all-ones value, which is the only one Metal has, so KosmicKrisp has
  to unroll the index buffer in a compute pass before every such draw.
- **Fix.** Restart is enabled only for strip, loop and fan topologies. Engine
  and game meshes never put a restart index in a list.
- **Switch.** `SPRING_LUAVAO_FORCE_RESTART=1` restores the unconditional enable.

This change does nothing on a native desktop driver, so it is a candidate for
upstream. See [UPSTREAM.md](UPSTREAM.md).

## Present Through a GPU Readback Ring

- **Problem.** The engine renders into a surfaceless EGL pbuffer, which presents
  nowhere. To reach the window, each frame is read back and drawn onto a
  `CAMetalLayer` with Metal. A plain `glReadPixels` of the frame just rendered
  blocks until the whole GPU pipeline has drained.
- **Fix.** The frame is read into a ring of pixel buffer objects, which keeps
  Mesa on its GPU pack path, and the frame presented is the one packed two
  frames earlier. By then its buffer is idle and can be used without waiting.
- **What keeps the fast path.** A pixel pack buffer must be bound, and the read
  must use the framebuffer's own component order. The engine asks the driver
  for that order once and logs it (`[MacPresent] impl color read ...`). If
  either condition is missed, Mesa falls back to the blocking path without
  saying so.
- **Fallbacks.** If a faster path cannot be set up, the engine steps down: the
  direct path (below), then the pack ring copied into an IOSurface, then a
  blit ring, then a synchronous read. It logs a warning when it leaves the
  direct path and when it ends up on the CPU staging path.
- **Switch.** `SPRING_MAC_LEGACY_PRESENT=1` forces the original CPU staging path.
  The two-frame depth is fixed in release builds.

## Present Off the Render Thread

- **Problem.** Calling `nextDrawable` on the render thread held light scenes at
  exactly half the display refresh rate. Raising the layer's
  `maximumDrawableCount` did not change that on its own.
- **Fix.** Presents run on a serial dispatch queue with a budget of two queued
  presents. The render thread never waits inside `nextDrawable`. When both
  slots are taken, the frame is dropped, not torn: the next present shows newer
  content anyway.
- **Log.** A dropped present writes `[MetalPresent] dropped present (compositor
  2 behind)` to the engine log, rate limited.

## Deeper Upload Ring and Blocking Fence Waits

- **Problem.** The persistently mapped upload ring for model transforms was
  three buffers deep, which assumes the GPU finishes within two frames. This
  stack runs further behind, so every map waited on a fence that had not
  signalled yet. The wait loop also polled with a one nanosecond timeout, and
  every poll is a round trip into the driver.
- **Fix.** On macOS the ring is six deep. The fence wait blocks for up to 250
  microseconds per call instead of spinning.
- **Switches.** `SPRING_MAC_UPLOAD_BUFFERING=n` sets the upload ring depth (3 to
  8). `SPRING_MAC_STREAM_BUFFERING=n` sets the stream buffer ring depth (2 to 8,
  default 3). The stream buffer default was left alone because deeper rings
  measured no gain there.

On macOS the same wait loop also gives up after ten seconds without progress and
closes the game with a "Graphics device lost" message, instead of spinning for
ever on a GPU that has stopped.

## Direct Present From Unified Memory

- **Problem.** With the readback ring in place, each frame was still mapped and
  copied into an IOSurface before Metal could draw it.
- **Fix.** Apple GPUs share memory with the CPU. The ring is allocated with
  `glBufferStorage`, mapped once and kept mapped, and each mapped pointer is
  wrapped as a Metal buffer without a copy. The present shader reads the pixels
  straight from it.
- **Backpressure.** Before a slot is presented, the engine waits on that slot's
  fence. This wait is deliberate. An earlier version skipped the present when
  the GPU was behind: the frame counter stayed high while the screen showed
  stale frames. When you change this path, count presents and drops, not only
  frames per second.
- **Switch.** `MacPresentDirect` (default 1). 0 uses the IOSurface path. It can
  be changed while the game runs. If the direct path cannot be set up, the
  engine falls back by itself and logs a warning.

## Worker Threads Kept Off the Efficiency Cores

- **Problem.** macOS has no thread affinity. A thread at the default quality of
  service class may be scheduled on an efficiency core, and in a parallel loop
  the slowest worker sets the time for the whole group.
- **Fix.** Workers of the synchronous thread pool ask for the user-initiated
  class. The asynchronous pool is background work and stays at the default. The
  present queue is created at the user-interactive class.
- **Switch.** `MacWorkerQos` (default 1). 0 leaves the scheduler default. It can
  be changed while the game runs.
- **Log.** `[ThreadPool] workerN QoS: ...` at startup, one line per worker.

## Render Density Capped to the Panel and the GPU

The default framebuffer follows the window's backing scale, with two caps. The
window size and the configured resolution, which are in points, are never
changed. Only the pixel density of the render target is.

1. **Never more pixels than the panel has.** A "scaled" desktop mode is backed
   by more pixels than the panel can show, and the window server scales it
   down. For example a 2560 x 1664 panel at its default scaled mode has a
   2940 x 1912 backing, which is 31% more pixels. Rendering those is wasted
   work.
2. **A pixel budget per GPU core.** The render target is kept within about 0.6
   megapixels per GPU core, for small GPUs driving large displays. The cap is
   skipped when the core count cannot be read.

The scale never drops below 1. The result is logged as `[EGL] effective backing
scale ...`, with the reason when a cap applies.

- **Switches.** `SPRING_MAC_FULL_BACKING=1` turns both caps off.
  `SPRING_MAC_NO_RETINA=1` forces 1x rendering.

## Render Scale and Upscaler

`MacRenderScale` (0.5 to 1.0, default 1.0) is the fraction of the resolution
above that the game renders at. Below 1.0 the smaller frame is scaled up to the
window when it is presented. Every pixel not rendered is also a pixel not read
back. The value is applied at startup and when the window is resized.

`MacUpscaler` chooses how that frame is scaled up: 1 (default) uses the MetalFX
spatial upscaler, 0 a plain stretch. If MetalFX is not available the engine
uses the plain stretch. MetalFX is used only when `MacRenderScale` is below 1,
so the default setting presents exactly as before. `MacUpscaler` can be changed
while the game runs.

`MacCrispInterface` (default 0, needs a restart) keeps the interface and its
text at the window's full resolution while the world renders at
`MacRenderScale`. It does nothing when `MacRenderScale` is 1. The engine still
works at the `MacRenderScale` size, so the world, its lighting and the screen
effects are drawn exactly as with `MacRenderScale` alone. Only the default
framebuffer is full size. The world is drawn into an engine-size buffer
(`rts/System/Platform/Mac/CrispInterface.cpp`), stretched into the full-size
one with plain smooth scaling (no MetalFX), and the interface pass draws on
top with its viewport and scissor scaled up. Fonts rasterise at twice their
size. The trade-off: the frame read back each frame is the full window, so
the mode saves world drawing but not readback. Design after smallketchup82's
[ZkMacOS](https://github.com/smallketchup82/ZkMacOS) "Retina text and UI"
mode, written again for this tree. A benchmark render-size pin
(`SPRING_MAC_PERF_RENDER_SIZE`) turns it off.

## Buffered Immediate Mode Drawing From Lua

Game widgets draw with `gl.BeginEnd`, which makes one OpenGL call per vertex.
That is cheap on a native driver and expensive here. With
`LuaImmediateModeBuffering` on, each `gl.BeginEnd` block is collected and drawn
with one `glDrawArrays` call. It is on by default on macOS only. Other
platforms keep the upstream path unless the setting is turned on. 0 restores
`glBegin` and `glEnd`. The picture is the same either way, see
[PARITY.md](PARITY.md).

## Pacing to the Display

SDL's swap interval never reaches this present path, because there is no SDL
swap. The `VSync` setting is honoured in the present code instead. Any non-zero
value makes the render loop wait briefly for a free present slot, so the game
renders no faster than frames reach the screen. 0 runs unpaced and drops the
surplus frames. Frames are never torn in either mode. The engine logs
`[EGL] VSync=N: frames paced to the display` or `not paced`. Measured behaviour
is recorded in [PARITY.md](PARITY.md).

## The Driver

The driver is upstream Mesa at a pinned commit plus the patches in
`patches/mesa/`, built by `scripts/build-mesa-kk.sh`. The pin and the reason for
each change of pin are in [VERSIONS.md](VERSIONS.md).

There is no driver performance switch to set. Two things this port used to
carry as patches now come from upstream Mesa and were dropped at the last
re-pin:

- **Shader math mode.** KosmicKrisp now compiles shaders in fast-math mode and
  marks only the operations that must keep their exact semantics. The engine
  sets nothing for this.
- **Render pass tracking for KosmicKrisp in Zink.**

The patches that remain are correctness and loading fixes, plus one line
logged when the driver loads (`KOSMICKRISP_LOADED version=... path=...`) so that
every log shows which copy of the driver was used.

## Measuring

There is no automated performance gate. `scripts/build-engine.sh --with-perf`
says so and stops, and `scripts/visreg.sh --perf` is accepted and ignored.

Tools that exist in the tree:

- **GPU timers.** `GPUTimers = 1` times the GPU with timestamp queries and feeds
  the results into the profiler as `GPU::<label>` zones. Lua can add its own
  with `gl.GPUStamp(label)`. On a tile-based GPU the time is only attributed
  per pass if a pass boundary is forced at each stamp:
  `GPUTimersSplitPasses = 1` does that, at the cost of extra attachment loads
  and stores, so do not leave it on when measuring frame rate. The profiler
  overlay turns the stamps on while it is open. After 300 frames the engine
  logs `[GPUTimers] N stamps per frame, M unreadable so far`. For a visual
  regression run: `VISREG_EXTRA_SETTINGS='GPUTimers = 1' scripts/visreg.sh`.
- **Hitch log.** `SPRING_HITCH_LOG=<ms>` turns the profiler on and logs each
  frame slower than that many milliseconds, with the timers that took longest
  (`[hitch] frame ...`). The present path has its own timers under
  `Misc::SwapBuffers`, so a slow swap can be split into the pack, the wait for
  the GPU and the Metal present.
- **Stall log.** A gap of more than 150 ms between drawn frames is logged as
  `[stall] draw gap ...`. `SPRING_NO_STALL_LOG=1` turns it off.
- **Fixed conditions.** `SPRING_MAC_PERF_PIN=1` turns display sync off, pins the
  colour space and the layer scale, and so removes the attached monitor from
  the result. It tears, so never use it for play.
  `SPRING_MAC_PERF_RENDER_SIZE=<W>x<H>` fixes the render size whatever the
  window size. `SPRING_MAC_FIXED_WINDOW=1` keeps the window where the settings
  put it. `SPRING_DEMO_SPEED=n` plays a replay n times faster.
- **Switching inside one run.** `MacPresentDirect`, `MacUpscaler`,
  `MacWorkerQos` and `VSync` take effect while the game runs, so two settings
  can be compared in one process on the same scene.
- **Diagnostics builds.** Configuring with `-DSPRING_MAC_DIAGNOSTICS=ON` compiles
  in the heavier tools: `SPRING_TIME_PRESENT` (per-stage present timing),
  `SPRING_MAC_PRESENT_LAG` and `SPRING_MAC_PRESENT_GPUPACK` (readback depth and
  path), `SPRING_FRAME_CAPTURE` and `SPRING_MAC_DUMP_FRAME` (raw frame dumps).
  None of this is in a release build.

When a result looks too good, check what reached the screen. With display
pacing off, the engine can render far more frames than it presents, and the
dropped presents are in the log.

## Historical Figures

These figures are **historical**. They were measured in mid 2026 during the
original optimisation work, on the 2025.06.24 engine line and on driver builds
that predate the current Mesa pin (the previous pin is recorded in
[VERSIONS.md](VERSIONS.md)). Machine: M2 Ultra, 5K output, display sync on. They
have not been measured again on the current engine and driver. Read them as the
size of each effect at the time, not as what this tree does today.

| What | Before | After |
|---|---|---|
| 2,162-unit battle, all changes together | 6.8 fps | 54.4 fps |
| 1,082-unit battle, combat zoom, all changes together | 12.1 fps | 71.7 fps |
| Late-game 8v8, icon overview, all changes together | 4.7 fps | 45.5 fps |
| Primitive restart change alone, 2,162-unit battle | 6.8 fps | 23.1 fps |
| Readback ring, present cost at 5120 x 2160 | about 30 ms | about 1.3 ms |
| Upload ring, time waiting on fences per frame | about 10 ms | gone from the profile |
| Present off the render thread, light scene on a 120 Hz panel | held at 60 fps | reached the panel limit |

The totals also include a shader math change that was a driver patch at the
time and is now part of upstream Mesa.

## Open Work

- **A present with no readback.** Rendering the engine's framebuffer straight
  into the surface Metal draws would remove the readback altogether. It is
  blocked on upstream Mesa work: KosmicKrisp's `VK_EXT_external_memory_metal`
  would need to handle IOSurface or Metal texture handles, and Zink would need
  a way to use the resulting image as a framebuffer attachment.
- **Late-game frame rate.** In large late-game battles the limit is the
  simulation and game Lua on the main thread. That is a property of the engine,
  not of the graphics stack.
- **The cost of restart on list topologies in KosmicKrisp.** The driver
  advertises the feature and pays for it with a compute pass per draw. Whether
  it should is a question for upstream, see [UPSTREAM.md](UPSTREAM.md).
