#!/bin/bash
# Skirmish AI check: start a headless game with two native skirmish AIs
# against each other and let it run. It proves the AI libraries this tree
# builds (BARb, CircuitAI) load, start and keep playing: both are built from
# submodules with their own build files, so an engine build that passes says
# nothing about them at run time.
#
# Usage: scripts/ai-skirmish.sh [options]
#   --ai <name>        AI short name (default BARb)
#   --ai-version <v>   AI version folder (default stable)
#   --game <name>      game archive name, as the lobby shows it
#   --map <name>       map name
#   --seconds <n>      wall-clock time to run (default 90)
#   --min-frames <n>   simulation frames that must be reached (default 1800)
#   --engine <path>    spring-headless (default build-engine/spring-headless)
#   --content <dir>    data folder with the game and the map (default: the
#                      app's data folder)
# The defaults for --game and --map are the ones the fleet demo used by the
# other scripts was recorded with, so the same content serves both.
# Prints AI_SKIRMISH_OK, or AI_SKIRMISH_FAIL <reason> and exit 1.
set -uo pipefail
BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
AI=BARb; AIVER=stable; SECS=90; MIN_FRAMES=1800
GAME="Beyond All Reason test-31836-b250a16"; MAP="Glacial Gap v1.1"
ENGINE="${ENGINE_BUILD:-$BAR/build-engine}/spring-headless"
CONTENT="$HOME/Library/Application Support/Beyond-All-Reason-mac"
while [ $# -gt 0 ]; do
  case "$1" in
    --ai) AI=$2; shift 2;;
    --ai-version) AIVER=$2; shift 2;;
    --game) GAME=$2; shift 2;;
    --map) MAP=$2; shift 2;;
    --seconds) SECS=$2; shift 2;;
    --min-frames) MIN_FRAMES=$2; shift 2;;
    --engine) ENGINE=$2; shift 2;;
    --content) CONTENT=$2; shift 2;;
    *) echo "unknown arg: $1 (see the header for usage)"; exit 2;;
  esac
done
[ -x "$ENGINE" ] || { echo "AI_SKIRMISH_FAIL no engine at $ENGINE"; exit 1; }
ENGINE_DIR=$(cd "$(dirname "$ENGINE")" && pwd)
[ -f "$ENGINE_DIR/AI/Skirmish/$AI/$AIVER/libSkirmishAI.dylib" ] \
  || { echo "AI_SKIRMISH_FAIL no library for $AI $AIVER under $ENGINE_DIR/AI/Skirmish"; exit 1; }
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout) \
  || { echo "AI_SKIRMISH_FAIL neither timeout nor gtimeout found (brew install coreutils)"; exit 1; }

WD=$(mktemp -d "${TMPDIR:-/tmp}/ai-skirmish.XXXXXX")
LOG="$WD/infolog.txt"
cat > "$WD/script.txt" <<SCRIPT
[game]
{
	gametype=$GAME;
	mapname=$MAP;
	ishost=1;
	hostip=127.0.0.1;
	startpostype=2;
	myplayername=spectator;
	[modoptions] { minspeed=20; maxspeed=20; }
	[player0] { name=spectator; team=0; spectator=1; isfromdemo=0; }
	[ai0] { name=$AI one; shortname=$AI; version=$AIVER; team=0; host=0; }
	[ai1] { name=$AI two; shortname=$AI; version=$AIVER; team=1; host=0; }
	[team0] { allyteam=0; teamleader=0; side=Armada; }
	[team1] { allyteam=1; teamleader=0; side=Cortex; }
	[allyteam0] { numallies=0; startrectleft=0; startrectright=0.3; startrecttop=0; startrectbottom=1; }
	[allyteam1] { numallies=0; startrectleft=0.7; startrectright=1; startrecttop=0; startrectbottom=1; }
}
SCRIPT
printf 'Sound = 0\n' > "$WD/springsettings.cfg"

echo "ai-skirmish: $AI $AIVER against itself on $MAP for ${SECS}s ($ENGINE)"
SPRING_DATADIR="$CONTENT:$ENGINE_DIR" "$TIMEOUT_BIN" "$SECS" "$ENGINE" --write-dir "$WD" "$WD/script.txt" > "$WD/stdout.log" 2>&1
RC=$?
[ -f "$LOG" ] || LOG="$WD/stdout.log"
LAST_FRAME=$(grep -oE '\[f=[0-9]+\]' "$LOG" | tail -1 | tr -dc '0-9' | sed 's/^0*//')
LOADED=$(grep -c "Skirmish AI <" "$LOG" || true)
echo "ai-skirmish: exit $RC (124 = stopped by the time limit, as intended), last frame ${LAST_FRAME:-none}, log $LOG"
if [ "$RC" -ne 124 ]; then
  echo "AI_SKIRMISH_FAIL the engine ended by itself (exit $RC) before the time limit"
  grep -E 'Fatal|Error|error:|content_error|Crash|Segmentation' "$LOG" | head -5
  exit 1
fi
# Judge the game, not the stop: the time limit ends the engine with SIGTERM,
# and its forced exit from a signal handler can abort inside an AI library's
# static destructors (threads still joinable). Only what was logged before the
# signal arrived counts.
sed '/caught SIGTERM/,$d' "$LOG" > "$WD/before-stop.log"
if grep -q -E 'Stacktrace|Segmentation fault|Abort trap|has crashed|Failed to load Skirmish AI|Failed to initialize' "$WD/before-stop.log"; then
  echo "AI_SKIRMISH_FAIL the log reports a crash or an AI that did not load:"
  grep -E 'Stacktrace|Segmentation fault|Abort trap|has crashed|Failed to load Skirmish AI|Failed to initialize' "$WD/before-stop.log" | head -5
  exit 1
fi
if [ "${LAST_FRAME:-0}" -lt "$MIN_FRAMES" ]; then
  echo "AI_SKIRMISH_FAIL only frame ${LAST_FRAME:-0} reached, expected at least $MIN_FRAMES"; exit 1
fi
if [ "$LOADED" -eq 0 ]; then
  echo "AI_SKIRMISH_FAIL no line from a skirmish AI in the log: it did not start"; exit 1
fi
echo "AI_SKIRMISH_OK ai=$AI frames=$LAST_FRAME ai_log_lines=$LOADED log=$LOG"
