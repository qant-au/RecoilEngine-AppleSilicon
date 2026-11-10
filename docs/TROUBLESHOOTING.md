# Troubleshooting

Problems a maintainer is likely to meet when building or running this tree, and
what to do about each. Every entry is written as symptom, cause, what to do.

Before a long build or test run, start with:

```sh
scripts/preflight.sh
```

It checks the toolchain, the upstream release tag, the crash-reporter setting
and leftover engine processes. It only reports: it changes nothing on the
machine. It prints `PREFLIGHT_OK` when nothing blocks a run.

## Building

### A Rebuild With Plain Ninja Gives an Unverified Engine

- **Symptom.** You ran `ninja` in `build-engine/` to save time. It compiled and
  linked without an error, and the engine starts.
- **Cause.** `scripts/build-engine.sh` does more than compile. After `ninja`
  finishes, it recompiles streflop's double-precision maths objects with gcc
  (`scripts/gcc-dbl64-swap.sh`), links `spring` and `spring-headless` again
  against them, checks each binary (`scripts/check-dbl64-marker.sh`), and runs
  the libm parity gate against the reference hashes in `testkit/libm-refs/`.
  A plain `ninja` run does none of that, and it rebuilds the swapped objects
  with clang. Nothing fails and nothing warns you. The result is an engine
  that nothing ties to the maths library the Windows and Linux builds use.
- **What to do.** Always build through the script, never with `ninja` directly:

  ```sh
  scripts/build-engine.sh     # or: make engine
  ```

  If you already ran plain `ninja`, run the script again. Trust a build only
  when it has printed the `libm parity gate (...): OK` line and
  `ENGINE_BUILD_OK`. The script is safe to rerun: it skips the driver build when
  the driver is current.

### The Libm Parity Gate Stops the Build

- **Symptom.** `scripts/build-engine.sh` stops with `FATAL: streflop archive does
  not match ... libm hashes`, `FATAL: gcc not found`, `FATAL: swapped 0 dbl-64
  objects`, or `FATAL: libm parity gate cannot run`.
- **Cause.** The official Windows and Linux builds are compiled with gcc, and the
  engine's CMake adds `-fsingle-precision-constant` for gcc only. That flag
  changes the value of floating-point constants inside streflop's
  double-precision maths library. Clang has no such flag, so a pure clang build
  gives different results there. The build therefore recompiles those objects
  with one specific Homebrew gcc and compares the result with reference hashes.
  The gate fails closed: a missing compiler or a missing reference file stops
  the build instead of skipping the check.
- **What to do.**
  - Install the pinned gcc. `scripts/preflight.sh` checks for it, and
    [VERSIONS.md](VERSIONS.md) says which version and why. A different gcc
    version is not a substitute.
  - Do not edit the reference files to get past the gate. A mismatch means the
    maths library differs from the one the official builds use.
  - If two builds of the same source file disagree and you cannot see why,
    compare the complete compiler command lines, not the flags you expect:
    `ninja -C build-engine -t commands <target>` prints them. The flag above is
    set globally, so it does not show up next to the file it affects.

### Code After a LOG Call Never Runs

- **Symptom.** A function call that plainly should run does not. The code
  compiles without a warning.
- **Cause.** The engine's `LOG()` and `LOG_L()` macros expand to an `if`
  statement with no braces (`rts/System/Log/ILog.h`). In
  `if (cond) LOG(...); else foo();` the `else` attaches to the `if` inside the
  macro, not to yours.
- **What to do.** Put braces around both branches whenever one of them is a
  `LOG` call.

## Running

### The Engine Will Not Start Outside the App Bundle

- **Symptom.** You start `build-engine/spring` by hand. It stops with a message
  that the GPU driver failed to load and the game fell back to a software
  renderer, or it finds no usable OpenGL at all.
- **Cause.** The graphics stack is selected entirely by environment variables.
  `packaging/launcher.sh` sets them: `EGL_PLATFORM=surfaceless`,
  `VK_ICD_FILENAMES` and `VK_DRIVER_FILES` (the KosmicKrisp ICD file),
  `GALLIUM_DRIVER=zink`, `MESA_LOADER_DRIVER_OVERRIDE=zink` and
  `MESA_GL_VERSION_OVERRIDE=4.6`. Without them Mesa falls back to a software
  renderer, which draws a correct picture at a few frames per second. The
  engine refuses to continue in that state. The binary in `build-engine/` also
  cannot find the bundled Vulkan loader, because that path only resolves inside
  an app bundle.
- **What to do.**
  - Run the engine from a built app bundle (`make app`). The test scripts do
    the same: `scripts/visreg.sh` plays the engine inside the last built bundle,
    with the launcher's environment.
  - To test the driver alone, run `scripts/gpu-smoke.sh`. It needs no window and
    prints `GPU_SMOKE_OK`.
  - To confirm which driver a run used, look for the line
    `KOSMICKRISP_LOADED version=... path=...` in the output. The OpenGL renderer
    string must name zink and KosmicKrisp.
  - `SPRING_ALLOW_SOFTWARE_GL=1` lets the engine run on the software renderer.
    Use it for debugging only.

### pr-downloader Finds No Game or Map

- **Symptom.** pr-downloader runs, and the game or map you asked for is not
  found.
- **Cause.** Left to its defaults, pr-downloader looks in the old Spring
  repositories. Beyond All Reason's content is on its own content network.
- **What to do.** Set both variables, as `packaging/launcher.sh` does:

  ```sh
  PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz \
  PRD_HTTP_SEARCH_URL=https://files-cdn.beyondallreason.dev/find \
  build-engine/tools/pr-downloader/src/pr-downloader \
    --filesystem-writepath "<content dir>" --download-map "<map name>"
  ```

  Pass the content folder with `--filesystem-writepath`. Do not export
  `SPRING_DATADIR` for pr-downloader: it resolves its data folder the way the
  engine does, and can pick a read-only folder from that list as the place to
  write. The download then fails. The
  header of `scripts/replay-check.sh` shows the full recipe for fetching what a
  replay needs.

### A LAN Game Cannot Be Reached

- **Symptom.** Joining or hosting a game on the local network times out. The
  log has a line starting `Cannot reach <address>: macOS is blocking Local
  Network access`.
- **Cause.** macOS Local Network privacy. Until the permission is granted, every
  UDP packet to a local address fails with "host unreachable", which looks like
  a routing fault. Internet servers are not affected.
- **What to do.** Open System Settings, Privacy & Security, Local Network, and
  enable the app. Then try again.

### The Water Setting Changes by Itself

- **Symptom.** You set `Water` to one value and find another in
  `springsettings.cfg` after a run. The water looks plainer than you asked for.
- **Cause.** The engine only uses a water renderer the driver can run. Modes 1
  to 3 need ARB assembly shader programs. If the driver does not accept them,
  the engine picks basic water (mode 0) instead and saves that as the new
  setting.
- **What to do.** Use `Water = 4`. That mode (bump-mapped water) is written in
  GLSL and does not depend on ARB programs. When a run behaves differently from
  the one before with no change on your side, compare `springsettings.cfg`
  between the two.

## Unattended Runs

These stop or mislead a build or test run that nobody is watching.

### A Crash Dialog Blocks the Run

- **Symptom.** A test run hangs. On the screen is the macOS dialog saying the
  engine quit unexpectedly.
- **Cause.** The crash-reporter dialog is modal. Nothing continues until someone
  clicks it.
- **What to do.** `scripts/preflight.sh` warns when the dialog is enabled. To
  turn it off for your user account:

  ```sh
  defaults write com.apple.CrashReporter DialogType none
  ```

  This is a setting on your Mac, not in the repository, so decide before a run
  whether you want it. Crash reports are in `~/Library/Logs/DiagnosticReports`.

### A Leftover Engine Process Breaks the Next Run

- **Symptom.** A run fails or misbehaves at startup, for example because the
  host port is already in use, after an earlier run crashed or was interrupted.
- **Cause.** An engine process from the earlier run is still alive. It holds the
  port and its audio and graphics state.
- **What to do.**

  ```sh
  scripts/reap.sh --dry-run   # list what would be stopped
  scripts/reap.sh             # stop it
  ```

  The script only stops processes named `spring`, `spring-headless`,
  `spring-dedicated` or `pr-downloader` that were started from this checkout or
  from a temporary folder. A game running from the Applications folder is
  listed and left alone. It asks processes to quit first and kills them only if
  they have not gone after about ten seconds. During a long session, run it
  between tests, not only at the start.

### A Bundle Copied to Another Mac Is "Damaged"

- **Symptom.** An app built with `make app` opens on the Mac that built it. On
  another Mac, macOS says the app is damaged and will not open it.
- **Cause.** `make app` signs the bundle ad hoc, which is good for the Mac that
  built it only. A downloaded copy carries the quarantine attribute, and
  Gatekeeper reports an ad hoc signed app in quarantine as damaged.
- **What to do.** On a test Mac, remove the attribute before the first launch:

  ```sh
  xattr -dr com.apple.quarantine <path to the app>
  ```

  For anything given to other people, build a signed and notarised release
  with `make release`. See [RELEASING.md](RELEASING.md).

### A Script Exits Cleanly but Did Not Do the Work

- **Symptom.** A step in an unattended run returned without an error, and later
  steps behave as if it never ran.
- **Cause.** An exit code alone says little. A build can succeed and leave an
  old binary in place, and a replay with nothing to compare proves nothing.
- **What to do.** Check for the line each script prints on real success:
  `PREFLIGHT_OK`, `MESA_KK_STACK_OK`, `ENGINE_BUILD_OK`, `SYNCTEST_OK`,
  `UNIT_TESTS_OK`, `GPU_SMOKE_OK`, `REPLAY_SYNC_OK`, `VISREG_OK`. The scripts
  fail on purpose where a silent pass would mislead: `scripts/replay-check.sh`
  refuses a replay that carries no sync checksums and one recorded on a
  different engine version, and `scripts/build-engine.sh` checks the binaries
  it produced, not only that the compiler returned.

## See Also

- [BUILDING.md](BUILDING.md) for the build itself.
- [VERSIONS.md](VERSIONS.md) for every pinned version and what enforces it.
- [SYNC_VALIDATION.md](SYNC_VALIDATION.md) for replay and sync checks.
- [PERFORMANCE.md](PERFORMANCE.md) for frame rate problems and the tools to
  measure them.
