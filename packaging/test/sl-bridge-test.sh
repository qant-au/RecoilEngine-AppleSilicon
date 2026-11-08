#!/bin/bash
# sl-bridge-test.sh: drives packaging/sl-bridge.swift over its real TCP protocol
# with a scripted lobby client. No GUI, no network (download tests use refused
# inputs only). Needs a demo to parse: SL_BRIDGE_TEST_DEMO=<path.sdfz>, default
# deps/oth014/duel.sdfz (a public 2026.07.04 BAR duel); skipped if absent.
# Usage: packaging/test/sl-bridge-test.sh
set -uo pipefail
BAR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-bridge-test.XXXXXX")
trap 'kill $BPID $HOLDER 2>/dev/null; rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $*"; PASS=$((PASS+1)); }; no(){ echo "  FAIL $*"; FAIL=$((FAIL+1)); }

swiftc -O -o "$WORK/sl-bridge" "$BAR/packaging/sl-bridge.swift" 2>/dev/null || { echo "FATAL: compile failed"; exit 1; }
WD="$WORK/wd"; mkdir -p "$WD/demos"
DEMO="${SL_BRIDGE_TEST_DEMO:-$BAR/deps/oth014/duel.sdfz}"
HAVE_DEMO=0; [ -f "$DEMO" ] && { cp "$DEMO" "$WD/demos/test.sdfz"; HAVE_DEMO=1; }

sleep 300 & HOLDER=$!     # stands in for the launcher/engine pid
"$WORK/sl-bridge" --writedir "$WD" --prd /usr/bin/false --engine /usr/bin/false \
  --engine-version 2026.07.04 --parent-pid "$HOLDER" --log "$WORK/bridge.log" > "$WORK/out" &
BPID=$!
for _ in $(seq 50); do grep -q SL_BRIDGE_READY "$WORK/out" 2>/dev/null && break; sleep 0.1; done
grep -q SL_BRIDGE_READY "$WORK/out" && ok "bridge ready" || { no "bridge never became ready"; cat "$WORK/bridge.log"; exit 1; }
[ -f "$WD/sl-connection.json" ] && ok "sl-connection.json written" || no "sl-connection.json missing"

# Scripted lobby: send commands, collect replies for a moment, print them as JSON lines.
cat > "$WORK/client.py" <<'PY'
import json, socket, sys, time
conn = json.load(open(sys.argv[1]))
assert conn["_sl_address"] == "127.0.0.1"
s = socket.create_connection((conn["_sl_address"], conn["_sl_port"]), timeout=5)
for line in sys.argv[2:]:
    s.sendall((line + "\n").encode())
s.settimeout(0.5); buf = b""; end = time.time() + 4
while time.time() < end:
    try:
        d = s.recv(65536)
        if not d: break
        buf += d
    except socket.timeout:
        pass
for l in buf.split(b"\n"):
    if l.strip(): print(l.decode())
PY
send(){ python3 "$WORK/client.py" "$WD/sl-connection.json" "$@"; }

if [ "$HAVE_DEMO" = 1 ]; then
  R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"demos/test.sdfz"}}')
  echo "$R" | python3 -c "
import json,sys
m=[json.loads(l) for l in sys.stdin if l.strip()]
r=[x['command'] for x in m if x['name']=='ReplayInfo']
assert r, 'no ReplayInfo'
c=r[0]
assert c['relativePath']=='demos/test.sdfz', c['relativePath']
assert c['engine'].startswith('2026.07.04'), c['engine']
assert c['game'].startswith('Beyond All Reason'), c['game']
assert c['map'], 'no map'
assert len(c['players'])>=2, c['players']
assert all('allyTeamId' in p and 'name' in p for p in c['players'])
assert len({p['allyTeamId'] for p in c['players']})>=2
assert c['gameTime']>0
assert isinstance(c['winningAllyTeamIds'], list)
print('  info: %s on %s, %d players, %ss, winners %s' % (c['game'], c['map'], len(c['players']), c['gameTime'], c['winningAllyTeamIds']))
" && ok "ReadReplayInfo parses a fleet demo" || no "ReadReplayInfo: $R"
  [ -f "$WD/demos/test.sdfz.cache" ] && ok "replay info cached beside the demo" || no "no .cache written"
else
  echo "  skip ReadReplayInfo (no demo at $DEMO)"
fi

R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"../../../etc/hosts"}}')
[ -z "$R" ] && grep -q 'outside write dir' "$WORK/bridge.log" && ok "path traversal refused" || no "path traversal: $R"

R=$(send '{"name":"OpenFile","command":{"path":"file:///etc/hosts"}}')
echo "$R" | grep -q '"OpenFileFailed"' && ok "OpenFile outside write dir refused" || no "OpenFile: $R"

R=$(send '{"name":"Download","command":{"name":"x","type":"resource","resource":{"url":"http://example.com/a","destination":"a"}}}')
echo "$R" | grep -q '"DownloadFinished"' && echo "$R" | grep -q '"isSuccess":false' && ok "non-https resource refused" || no "resource http: $R"

R=$(send '{"name":"Download","command":{"name":"y","type":"resource","resource":{"url":"https://example.com/a","destination":"../../escape"}}}')
echo "$R" | grep -q '"isSuccess":false' && ok "resource destination outside write dir refused" || no "resource traversal: $R"

R=$(send '{"name":"Download","command":{"name":"z","type":"engine"}}')
echo "$R" | grep -q '"isSuccess":false' && ok "engine download reported unsupported" || no "engine dl: $R"

R=$(send '{"name":"Download","command":{"name":"Some Map","type":"map"}}')
echo "$R" | grep -q '"DownloadFinished"' && echo "$R" | grep -q '"isSuccess":false' && ok "map download runs pr-downloader and reports its exit" || no "map dl: $R"

kill "$HOLDER"; wait "$HOLDER" 2>/dev/null
for _ in $(seq 40); do kill -0 "$BPID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$BPID" 2>/dev/null && no "bridge still running after parent exit" || ok "bridge exits with its parent"
[ -f "$WD/sl-connection.json" ] && no "sl-connection.json left behind" || ok "sl-connection.json removed on exit"

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
