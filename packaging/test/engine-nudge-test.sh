#!/bin/bash
# Engine nudge (launcher.sh engine_nudge): shown only when BAR production's
# engine (BYAR-Chobby dist_cfg, setup manual-linux) is NEWER than the engine in
# this app; silent when older, equal, offline or unparseable. message-check is
# stubbed, so no window opens.
set -u
HERE_T="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE_T/../launcher.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0

# pull the helper out of the launcher (its definition block only)
sed -n '/^BAR_DIST_CFG_URL=/,/^}/p' "$LAUNCHER" > "$WORK/nudge.sh"
grep -q '^engine_nudge()' "$WORK/nudge.sh" || { echo "FAIL: engine_nudge not found in launcher.sh"; exit 1; }

# fake bundle: Info.plist with an EngineVersion, stub message-check that logs
mkdir -p "$WORK/Contents/MacOS"
/usr/libexec/PlistBuddy -c "Add :EngineVersion string 2026.09.02" "$WORK/Contents/Info.plist" >/dev/null
printf '#!/bin/bash\necho "$@" >> "%s/called"\ncat "${2#file://}" >> "%s/payload"\nexit 0\n' "$WORK" "$WORK" > "$WORK/Contents/MacOS/message-check"
chmod +x "$WORK/Contents/MacOS/message-check"

cfg() { # cfg <engine-for-manual-linux>
  printf '{"setups":[{"package":{"id":"manual-win"},"launch":{"engine":"recoil_2099.01.01"}},{"package":{"id":"manual-linux"},"launch":{"engine":"%s"}}]}' "$1" > "$WORK/config.json"
}
run() { # run <name> <expect: shown|silent>
  rm -f "$WORK/called" "$WORK/payload"
  ( CONTENTS="$WORK/Contents"; HERE="$WORK/Contents/MacOS"; PORT_VERSION=0.14
    BAR_DIST_CFG_URL="$2"; source "$WORK/nudge.sh"; engine_nudge ) >/dev/null 2>&1
  local got=silent; [ -f "$WORK/called" ] && got=shown
  if [ "$got" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1 ($got)"
  else FAIL=$((FAIL+1)); echo "FAIL $1: expected $3, got $got"; fi
}

cfg recoil_2026.11.20; run "production newer"        "file://$WORK/config.json" shown
grep -q "engine 2026.11.20" "$WORK/payload" 2>/dev/null && grep -q "engine 2026.09.02" "$WORK/payload" \
  && { PASS=$((PASS+1)); echo "ok   message names both engines"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL message does not name both engines"; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/payload" 2>/dev/null \
  && { PASS=$((PASS+1)); echo "ok   generated messages.json parses"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL generated messages.json does not parse"; }
cfg recoil_2026.09.02; run "production equal"        "file://$WORK/config.json" silent
cfg recoil_2026.07.04; run "production older"        "file://$WORK/config.json" silent
cfg garbage;           run "unparseable engine"      "file://$WORK/config.json" silent
printf 'not json' > "$WORK/config.json"; run "unparseable config" "file://$WORK/config.json" silent
run "offline"                                        "file://$WORK/does-not-exist.json" silent

echo "engine-nudge-test: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
