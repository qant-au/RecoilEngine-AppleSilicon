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
#   --speed <x>        playback speed (default 20; engine knob SPRING_DEMO_SPEED,
#                      demos only). Sync is checked identically at any speed;
#                      a 36 min 8v8 took 7 min at 20x on an M3 Ultra (CPU-bound).
#   --timeout <secs>   wall-clock limit (default 7200).
#   --log <file>       where to keep the engine log (default: a temp file)
# Prints REPLAY_SYNC_OK and exits 0 on a clean run past the demo's last recorded
# checksum (a demo with no checksums is refused);
# prints REPLAY_SYNC_FAIL <reason> and exits 1 otherwise. A demo recorded on a
# different engine version is refused (VERSION_MISMATCH): it cannot replay.
#
# Fetching a public BAR replay: https://api.bar-rts.com/replays?engine=<version>
# lists them (use the id for .../replays/<id>, whose fileName is downloadable from
# https://storage.uk.cloud.ovh.net/v1/AUTH_10286efc0d334efd917d476d7183232e/BAR/demos/).
# Its gameVersion must be present in --content (pr-downloader --download-game) and
# its map too (--download-map). Point pr-downloader at BAR's content network, or
# it falls back to the old springrts repositories and finds nothing:
#   PRD_RAPID_REPO_MASTER=https://repos-cdn.beyondallreason.dev/repos.gz \
#   PRD_HTTP_SEARCH_URL=https://files-cdn.beyondallreason.dev/find \
#   build-engine/tools/pr-downloader/src/pr-downloader \
#     --filesystem-writepath "<content dir>" --download-map "<map name>"
#
# Linux: run this same script inside upstream's build image, e.g.
#   docker run --rm --platform linux/amd64 --entrypoint bash -v "$PWD:/src" \
#     -v "<content dir>:/content:ro" ghcr.io/beyond-all-reason/recoil-build-amd64-linux@<digest> \
#     /src/scripts/replay-check.sh /src/<demo> --engine /src/build-amd64-linux/spring-headless \
#     --content /content
# (digest: docker-build-v2/images_versions.sh). The official release binary from
# https://github.com/beyond-all-reason/RecoilEngine/releases is the control.
set -uo pipefail

BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
DEMO=""; ENGINE="${ENGINE_BUILD:-$BAR/build-engine}/spring-headless"
CONTENT="$HOME/Library/Application Support/Beyond-All-Reason-mac"
TIMEOUT=7200; LOG=""; SPEED=20
while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE=$2; shift 2;;
    --content) CONTENT=$2; shift 2;;
    --timeout) TIMEOUT=$2; shift 2;;
    --speed) SPEED=$2; shift 2;;
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

# Positive evidence: the engine is silent when checksums match, so a demo that
# carries none would pass whatever the simulation did.
read -r SYNC_PACKETS SYNC_LAST_FRAME < <(python3 "$(dirname "$0")/demo-sync-packets.py" "$DEMO" 2>/dev/null)
if [ "${SYNC_PACKETS:-0}" -lt 1 ]; then
  echo "REPLAY_SYNC_FAIL the demo carries no sync checksums, so a replay of it proves nothing"; exit 1
fi

# Isolated write dir, so a replay never touches the launcher's settings.
WD=$(mktemp -d "${TMPDIR:-/tmp}/replay-check.XXXXXX")
[ -n "$LOG" ] || LOG="$WD/replay.log"
trap 'rm -rf "$WD/LuaUI" "$WD/cache" 2>/dev/null' EXIT

echo "replay-check: $(basename "$DEMO") on $BIN_VER ($ENGINE)"
START=$(date +%s)
# The engine dir goes on SPRING_DATADIR for its own base content (springcontent).
SPRING_DEMO_SPEED="$SPEED" SPRING_DATADIR="$CONTENT:$ENGINE_DIR" "$TIMEOUT_BIN" "$TIMEOUT" \
  "$ENGINE" --write-dir "$WD" "$DEMO" > "$LOG" 2>&1
RC=$?
SECS=$(( $(date +%s) - START ))
LAST_FRAME=$(grep -oE '\[f=[0-9]+\]' "$LOG" | tail -1 | tr -dc '0-9' | sed 's/^0*//')
DESYNCS=$(grep -c 'DESYNC WARNING' "$LOG")
# the game's own end (BAR logs <autoquit> there); later frames are post-game
# filler while autoquit waits, with no recorded checksums to compare
END_FRAME=$(grep -m1 '<autoquit>' "$LOG" | grep -oE '\[f=[0-9]+\]' | tr -dc '0-9' | sed 's/^0*//')

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
if [ "${LAST_FRAME:-0}" -lt "$SYNC_LAST_FRAME" ]; then
  echo "REPLAY_SYNC_FAIL playback stopped at frame ${LAST_FRAME:-?}, before the demo's last checksum at frame $SYNC_LAST_FRAME - see $LOG"
  exit 1
fi
echo "REPLAY_SYNC_OK game_end_frame=${END_FRAME:-?} last_frame=${LAST_FRAME:-?} desyncs=0 checksums=$SYNC_PACKETS speed=${SPEED}x wall=${SECS}s log=$LOG"
