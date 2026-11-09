#!/bin/bash
# Visual regression: play a replay in the REAL game window (GPU, Mesa zink ->
# KosmicKrisp -> Metal, same driver environment as packaging/launcher.sh), take
# engine screenshots at fixed sim frames from a fixed camera, and compare them
# with approved baselines in testkit/visreg/<engine>/<demo>/.
#
# Usage: scripts/visreg.sh [--demo <file.sdfz>] [--content <dir>] [--bless]
#   --demo     replay to play (default deps/replays-0902/glacial-gap-0902.sdfz)
#   --content  data dir with the game, map and lobby packages (default: the
#              launcher's write dir; read only, the run uses its own write dir)
#   --bless    after a run, copy the pictures into testkit/visreg as the new
#              baselines. Only after Adam has looked at them and approved.
#   --perf     accepted for release-build.sh compatibility (no perf gate yet)
# Opens a game window for about two minutes. Prints VISREG_OK, VISREG_FAIL or
# VISREG_NO_BASELINE (pictures kept under logs/local/visreg-<stamp>/ to review).
#
# Pictures are keyed to sim frames, and the window is pinned (SPRING_MAC_PERF_PIN:
# 1x scale, fixed size), so a rerun gives the same pictures on any monitor.
# Unsynced animation (water, sky) still moves a little between runs, hence a
# tolerance rather than an exact match: a shot fails when its mean per-channel
# difference exceeds VISREG_MAX_MEAN (default 2.0 of 255; two runs measured 0.71 at most) or more than
# VISREG_MAX_BAD_PCT percent (default 1.0; measured 0.20) differ by over 40.
set -uo pipefail
BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
# The engine comes from a BUILT APP BUNDLE (default: the last 'make app'),
# with exactly the driver environment the launcher uses. The build-engine/
# binary cannot load the bundled Vulkan loader (@rpath only resolves in the
# bundle), which is why this runs the packaged engine.
APP="${VISREG_APP:-$BAR/release-artifacts/BAR Launcher.app}"
C="$APP/Contents"; RES="$C/Resources"
DEMO="$BAR/deps/replays-0902/glacial-gap-0902.sdfz"
CONTENT="$HOME/Library/Application Support/Beyond-All-Reason-mac"
BLESS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --demo) DEMO=$2; shift 2;;
    --content) CONTENT=$2; shift 2;;
    --bless) BLESS=1; shift;;
    --perf) shift;;
    *) echo "unknown option: $1"; exit 2;;
  esac
done
[ -f "$DEMO" ] || { echo "VISREG_FAIL demo not found: $DEMO"; exit 1; }
[ -x "$C/MacOS/spring" ] || { echo "VISREG_FAIL engine not found: $C/MacOS/spring (run make app)"; exit 1; }
ICD=$(ls "$RES"/vulkan/icd.d/*.json 2>/dev/null | head -1)
[ -f "$ICD" ] || { echo "VISREG_FAIL no KosmicKrisp ICD in $RES/vulkan"; exit 1; }
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) || { echo "VISREG_FAIL need timeout (brew install coreutils)"; exit 1; }

ENGINE_VER=$("$C/MacOS/spring" --version 2>/dev/null | grep -oE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}' | head -1)
NAME=$(basename "$DEMO" .sdfz)
BASE="$BAR/testkit/visreg/$ENGINE_VER/$NAME"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$BAR/logs/local/visreg-$STAMP"; mkdir -p "$OUT"

# Isolated write dir: the widget, the shot list and fixed settings live here, so
# the player's own settings and widgets are never touched.
WD=$(mktemp -d "${TMPDIR:-/tmp}/visreg.XXXXXX")
trap 'rm -rf "$WD"' EXIT
mkdir -p "$WD/LuaUI/Widgets"
cp "$BAR/scripts/visreg/visreg_capture.lua" "$WD/LuaUI/Widgets/"
# <frame> <name> <x-fraction> <z-fraction> <camera height>
cat > "$WD/LuaUI/visreg_frames.txt" <<'SHOTS'
900 01-start-overview 0.5 0.5 9000
900 02-start-west 0.25 0.5 2500
6000 03-early-east 0.75 0.5 2500
12000 04-mid-overview 0.5 0.5 9000
18000 05-late-west 0.25 0.5 2500
24000 06-end-east 0.75 0.5 2500
SHOTS
cat > "$WD/springsettings.cfg" <<'CFG'
Fullscreen = 0
XResolutionWindowed = 1280
YResolutionWindowed = 720
WindowPosX = 40
WindowPosY = 40
WindowBorderless = 0
VSync = 0
CFG

echo "visreg: $NAME on $ENGINE_VER (window opens for about two minutes)"
SPRING_MAC_PERF_PIN=1 SPRING_DEMO_SPEED=20 \
EGL_PLATFORM=surfaceless VK_ICD_FILENAMES="$ICD" VK_DRIVER_FILES="$ICD" \
GALLIUM_DRIVER=zink MESA_LOADER_DRIVER_OVERRIDE=zink MESA_GL_VERSION_OVERRIDE=4.6 \
DYLD_FALLBACK_LIBRARY_PATH="$C/Frameworks" \
SPRING_DATADIR="$CONTENT:$RES" "$TIMEOUT_BIN" 420 \
  "$C/MacOS/spring" --write-dir "$WD" "$DEMO" > "$OUT/engine.log" 2>&1
RC=$?
cp "$WD/infolog.txt" "$OUT/" 2>/dev/null || true

# map screenshots to shot names in order (the engine names them by time)
SHOTS_TAKEN=$(grep -c '\[visreg\] SHOT ' "$OUT/infolog.txt" 2>/dev/null || echo 0)
i=0
grep -oE '\[visreg\] SHOT \S+' "$OUT/infolog.txt" 2>/dev/null | awk '{print $3}' > "$OUT/names.txt"
ls "$WD"/screenshots/*.png 2>/dev/null | sort > "$OUT/files.txt"
paste -d' ' "$OUT/names.txt" "$OUT/files.txt" | while read -r n f; do
  [ -n "$n" ] && [ -f "$f" ] && cp "$f" "$OUT/$n.png"
done
EXPECTED=$(wc -l < "$WD/LuaUI/visreg_frames.txt" 2>/dev/null || echo 6)
GOT=$(ls "$OUT"/[0-9]*.png 2>/dev/null | wc -l | tr -d ' ')
if ! grep -q '\[visreg\] DONE' "$OUT/infolog.txt" 2>/dev/null || [ "$GOT" -ne "$EXPECTED" ]; then
  echo "VISREG_FAIL capture incomplete: $GOT of $EXPECTED pictures, engine exit $RC - see $OUT"
  exit 1
fi

if [ "$BLESS" = "1" ]; then
  mkdir -p "$BASE"; cp "$OUT"/[0-9]*.png "$BASE/"
  echo "VISREG_BLESSED $GOT baselines -> $BASE"; exit 0
fi
if [ ! -d "$BASE" ]; then
  echo "VISREG_NO_BASELINE pictures for review: $OUT (approve, then rerun with --bless)"
  exit 3
fi
python3 "$BAR/scripts/visreg/compare.py" "$BASE" "$OUT" \
  --max-mean "${VISREG_MAX_MEAN:-2.0}" --max-bad-pct "${VISREG_MAX_BAD_PCT:-1.0}"
