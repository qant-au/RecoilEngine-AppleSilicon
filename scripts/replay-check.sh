#!/bin/bash
# Replay-determinism check: re-simulate a recorded game on our engine and fail
# on any sync divergence from the machine that recorded it.
#
# A demo (.sdfz) embeds the per-frame sync checksums of the client that
# recorded it (usually an x86 Windows/Linux fleet client). spring-headless
# replays the command stream through the full simulation and compares every
# frame; one differing bit logs "[DESYNC WARNING] checksum ... from demo".
#
# Usage: scripts/replay-check.sh <demo.sdfz> [options]
#   --engine <path>    spring-headless binary (default $ENGINE_BUILD/spring-headless,
#                      ENGINE_BUILD defaults to build-engine/)
#   --content <dir>    data dir holding the game, map and lobby packages the demo
#                      needs (default: the launcher's write dir)
#   --timeout <secs>   wall-clock limit (default 7200). Replays run at 1x game
#                      speed, so allow at least the game's own length.
#   --log <file>       where to keep the engine log (default: a temp file)
# Prints REPLAY_SYNC_OK and exits 0 on a clean run to the end of the demo;
# prints REPLAY_SYNC_FAIL <reason> and exits 1 otherwise. A demo recorded on a
# different engine version is refused (VERSION_MISMATCH): it cannot replay.
#
# Fetching a public BAR replay: https://api.bar-rts.com/replays?engine=<version>
# lists them (use the id for .../replays/<id>, whose fileName is downloadable from
# https://storage.uk.cloud.ovh.net/v1/AUTH_10286efc0d334efd917d476d7183232e/BAR/demos/).
# Its gameVersion must be present in --content (pr-downloader --download-game) and
# its map too (--download-map).
set -uo pipefail

BAR="${BAR:-$(cd "$(dirname "$0")/.." && pwd)}"
DEMO=""; ENGINE="${ENGINE_BUILD:-$BAR/build-engine}/spring-headless"
CONTENT="$HOME/Library/Application Support/Beyond-All-Reason-mac"
TIMEOUT=7200; LOG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE=$2; shift 2;;
    --content) CONTENT=$2; shift 2;;
    --timeout) TIMEOUT=$2; shift 2;;
    --log) LOG=$2; shift 2;;
    -*) echo "unknown option: $1"; exit 2;;
    *) DEMO=$1; shift;;
  esac
done
[ -f "$DEMO" ] || { echo "usage: $0 <demo.sdfz> [--engine ..] [--content ..] [--timeout ..] [--log ..]"; exit 2; }
[ -x "$ENGINE" ] || { echo "REPLAY_SYNC_FAIL engine not found: $ENGINE"; exit 1; }
DEMO=$(cd "$(dirname "$DEMO")" && pwd)/$(basename "$DEMO")
ENGINE_DIR=$(cd "$(dirname "$ENGINE")" && pwd)
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) \
  || { echo "REPLAY_SYNC_FAIL neither timeout nor gtimeout found (brew install coreutils)"; exit 1; }

# Version check: the demo header names the engine that recorded it.
DEMO_VER=$(python3 -c "import gzip,re,sys; h=gzip.open(sys.argv[1]).read(512).decode('latin-1'); m=re.search(r'(20\d\d\.\d\d\.\d\d)', h); print(m.group(1) if m else '')" "$DEMO" 2>/dev/null)
BIN_VER=$("$ENGINE" --version 2>/dev/null | grep -oE '20[0-9]{2}\.[0-9]{2}\.[0-9]{2}' | head -1)
if [ -z "$DEMO_VER" ] || [ "$DEMO_VER" != "$BIN_VER" ]; then
  echo "REPLAY_SYNC_FAIL VERSION_MISMATCH: demo=${DEMO_VER:-unknown} binary=${BIN_VER:-unknown}"; exit 1
fi

# Isolated write dir, so a replay never touches the launcher's settings.
WD=$(mktemp -d "${TMPDIR:-/tmp}/replay-check.XXXXXX")
[ -n "$LOG" ] || LOG="$WD/replay.log"
trap 'rm -rf "$WD/LuaUI" "$WD/cache" 2>/dev/null' EXIT

echo "replay-check: $(basename "$DEMO") on $BIN_VER ($ENGINE)"
START=$(date +%s)
# The engine dir goes on SPRING_DATADIR for its own base content (springcontent).
SPRING_DATADIR="$CONTENT:$ENGINE_DIR" "$TIMEOUT_BIN" "$TIMEOUT" \
  "$ENGINE" --write-dir "$WD" "$DEMO" > "$LOG" 2>&1
RC=$?
SECS=$(( $(date +%s) - START ))
LAST_FRAME=$(grep -oE '\[f=[0-9]+\]' "$LOG" | tail -1 | tr -dc '0-9' | sed 's/^0*//')
DESYNCS=$(grep -c 'DESYNC WARNING' "$LOG")

if ! grep -q 'Beginning demo playback' "$LOG"; then
  echo "REPLAY_SYNC_FAIL playback never started (missing game/map content?) - see $LOG"
  grep -E 'Fatal|content_error' "$LOG" | head -3
  exit 1
fi
if [ "$DESYNCS" -gt 0 ]; then
  echo "REPLAY_SYNC_FAIL $DESYNCS desync warning(s); first:"
  grep -m1 'DESYNC WARNING' "$LOG"
  exit 1
fi
if [ "$RC" -ne 0 ]; then
  echo "REPLAY_SYNC_FAIL engine exit $RC after ${SECS}s at frame ${LAST_FRAME:-?} (124 = timeout) - see $LOG"
  exit 1
fi
echo "REPLAY_SYNC_OK frames=${LAST_FRAME:-?} desyncs=0 wall=${SECS}s log=$LOG"
