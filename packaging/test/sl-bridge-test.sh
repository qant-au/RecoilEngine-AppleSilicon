#!/bin/bash
# sl-bridge-test.sh: drives packaging/sl-bridge.swift over its real TCP protocol
# with a scripted lobby client. No GUI, no network (download tests use refused
# inputs only). Needs a demo to parse: SL_BRIDGE_TEST_DEMO=<path.sdfz>, default
# deps/oth014/duel.sdfz (a public 2026.07.04 BAR duel); skipped if absent.
# Usage: packaging/test/sl-bridge-test.sh
set -uo pipefail
BAR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-bridge-test.XXXXXX")
trap 'kill $BPID $HOLDER ${DISCORD:-} 2>/dev/null; rm -rf "$WORK" "${DTMP:-}"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $*"; PASS=$((PASS+1)); }; no(){ echo "  FAIL $*"; FAIL=$((FAIL+1)); }

swiftc -O -o "$WORK/sl-bridge" "$BAR/packaging/sl-bridge.swift" 2>/dev/null || { echo "FATAL: compile failed"; exit 1; }
WD="$WORK/wd"; mkdir -p "$WD/demos"
DEMO="${SL_BRIDGE_TEST_DEMO:-$BAR/deps/oth014/duel.sdfz}"
HAVE_DEMO=0; [ -f "$DEMO" ] && { cp "$DEMO" "$WD/demos/test.sdfz"; HAVE_DEMO=1; }

# Fixture map: a .sdz holding maps/fixture.smf whose minimap is one solid DXT1
# colour (pure red, 0xF800), so the decoded picture can be checked exactly.
mkdir -p "$WD/maps" "$WORK/mapsrc/maps"
python3 -c "
import struct,sys
hdr=bytearray(80); hdr[0:16]=b'spring map file\\0'
struct.pack_into('<i',hdr,64,80)            # minimapPtr
blk=struct.pack('<HHI',0xF800,0xF800,0)     # every pixel = colour 0
open(sys.argv[1],'wb').write(bytes(hdr)+blk*(256*256)+b'tail')
" "$WORK/mapsrc/maps/fixture.smf"
(cd "$WORK/mapsrc" && /usr/bin/zip -q -r "$WD/maps/fixture.sdz" maps)
# Fake Discord: answers the handshake with READY, records the SET_ACTIVITY frame.
# Unix socket paths are short (104 bytes), so this TMPDIR is short too.
DTMP=$(mktemp -d /tmp/slb.XXXXXX)
cat > "$WORK/discord.py" <<'PY'
import json, os, socket, struct, sys
path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(1)
c, _ = s.accept()
def rd():
    h = c.recv(8)
    if len(h) < 8: return None
    op, n = struct.unpack('<II', h); b = b''
    while len(b) < n: b += c.recv(n - len(b))
    return op, json.loads(b)
def wr(op, o):
    b = json.dumps(o).encode(); c.sendall(struct.pack('<II', op, len(b)) + b)
op, hs = rd(); json.dump({'handshake': hs}, open(out + '.hs', 'w'))
wr(1, {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {}})
op, cmd = rd(); json.dump(cmd, open(out, 'w'))
wr(1, {'cmd': 'SET_ACTIVITY', 'evt': None, 'nonce': cmd.get('nonce'), 'data': {}})
c.recv(1)
PY
python3 "$WORK/discord.py" "$DTMP/discord-ipc-0" "$WORK/discord.json" & DISCORD=$!
printf '%s' '{"log_upload_url":"https://log.example.invalid","discord_rich_presence":{"application_id":"123","minimap_url":"https://maps.example/<map>.jpg","large_image_text_default":"BAR","small_image_key_default":"logo","small_image_text_default":"BAR","button_label":"Play","button_url":"https://www.beyondallreason.info/"}}' > "$WORK/extras.json"

sleep 300 & HOLDER=$!     # stands in for the launcher/engine pid
# The bridge only talks to a process running the --engine binary. The scripted
# lobby below is python, so python stands in for the engine: ask the kernel for
# the path it reports for this interpreter (python3 may be a shim).
PYBIN=$(python3 -c "
import ctypes, os
b = ctypes.create_string_buffer(4096)
ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath(os.getpid(), b, 4096)
print(b.value.decode())")
[ -x "$PYBIN" ] || { echo "FATAL: could not find the python executable path"; exit 1; }
TMPDIR="$DTMP/" "$WORK/sl-bridge" --writedir "$WD" --prd /usr/bin/false --engine "$PYBIN" \
  --engine-version 2026.07.04 --config "$WORK/extras.json" --online 0 \
  --parent-pid "$HOLDER" --log "$WORK/bridge.log" > "$WORK/out" &
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

# A link inside the write dir must not lead out of it.
mkdir -p "$WORK/outside"; ln -s "$WORK/outside" "$WD/link"
R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"link/x.sdfz"}}')
[ -z "$R" ] && grep -q 'outside write dir: link/x.sdfz' "$WORK/bridge.log" && ok "symlink out of the write dir refused" || no "symlink escape: $R"
R=$(send "{\"name\":\"OpenFile\",\"command\":{\"path\":\"file://$WD/link/sub/\"}}")
echo "$R" | grep -q '"OpenFileFailed"' && [ ! -e "$WORK/outside/sub" ] && ok "OpenFile through a symlink refused" || no "OpenFile symlink: $R"

# A replay whose header sizes are negative is not a demo, and must not take the bridge down.
cat > "$WORK/baddemo.py" <<'PY'
import gzip, struct, sys
h = bytearray(400); h[0:15] = b'spring demofile'
struct.pack_into('<i', h, 20, 352)       # headerSize
struct.pack_into('<i', h, 304, 0)        # scriptSize
struct.pack_into('<i', h, 308, -100000)  # demoStreamSize
struct.pack_into('<i', h, 348, 4)        # winningAllyTeamsSize
gzip.open(sys.argv[1], 'wb').write(bytes(h))
PY
python3 "$WORK/baddemo.py" "$WD/demos/bad.sdfz"
R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"demos/bad.sdfz"}}')
kill -0 "$BPID" 2>/dev/null && grep -q 'bad demo header: demos/bad.sdfz' "$WORK/bridge.log" \
  && ok "malformed replay rejected, bridge still running" || no "malformed replay: $R"

# Only the engine may connect: the same command sent by another program (nc) is
# refused before a byte of it is read.
PORT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['_sl_port'])" "$WD/sl-connection.json")
printf '%s\n' '{"name":"ReadReplayInfo","command":{"relativePath":"demos/peer-probe.sdfz"}}' | /usr/bin/nc -w 2 127.0.0.1 "$PORT" >/dev/null 2>&1
grep -q 'refused a connection that does not come from the engine' "$WORK/bridge.log" && ! grep -q 'peer-probe' "$WORK/bridge.log" \
  && ok "a connection from another program is refused" || no "a non-engine client was served"

# A peer that does not speak the lobby protocol (an HTTP request, for one) is
# closed, and a command in its body is never run.
cat > "$WORK/http.py" <<'PY'
import json, socket, sys
c = json.load(open(sys.argv[1]))
s = socket.create_connection((c["_sl_address"], c["_sl_port"]), timeout=5)
body = '{"name":"ReadReplayInfo","command":{"relativePath":"demos/http-probe.sdfz"}}\n'
s.sendall(("POST / HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s" % (len(body), body)).encode())
s.settimeout(3)
try:
    closed = s.recv(1) == b""
except ConnectionResetError:
    closed = True
except Exception:
    closed = False
sys.exit(0 if closed else 1)
PY
python3 "$WORK/http.py" "$WD/sl-connection.json" && ! grep -q 'http-probe' "$WORK/bridge.log" \
  && ok "HTTP request closed, its body not run" || no "an HTTP client was served"

R=$(send '{"name":"Download","command":{"name":"x","type":"resource","resource":{"url":"http://example.com/a","destination":"a"}}}')
echo "$R" | grep -q '"DownloadFinished"' && echo "$R" | grep -q '"isSuccess":false' && ok "non-https resource refused" || no "resource http: $R"

R=$(send '{"name":"Download","command":{"name":"y","type":"resource","resource":{"url":"https://widget-hub.beyondallreason.dev/a","destination":"../../escape"}}}')
echo "$R" | grep -q '"isSuccess":false' && grep -q 'Download resource y: needs an https url and a destination inside the write dir' "$WORK/bridge.log" \
  && ok "resource destination outside write dir refused" || no "resource traversal: $R"

# only BAR's own download hosts, and only the folders its lobby downloads into
# (all four are refused before any request is made, so this needs no network)
for host in example.com beyondallreason.dev.example.com evilbeyondallreason.dev; do
  R=$(send '{"name":"Download","command":{"name":"h-'"$host"'","type":"resource","resource":{"url":"https://'"$host"'/a.zip","destination":"LuaUI/Widgets/a","extract":true}}}')
  echo "$R" | grep -q '"isSuccess":false' && grep -q "Download resource h-$host: $host is not one of BAR's download hosts, refused" "$WORK/bridge.log" \
    && ok "resource from $host refused" || no "resource host $host: $R"
done
R=$(send '{"name":"Download","command":{"name":"f","type":"resource","resource":{"url":"https://widget-hub.beyondallreason.dev/a.zip","destination":"AI/Skirmish/a","extract":true}}}')
echo "$R" | grep -q '"isSuccess":false' && grep -q 'Download resource f: AI/Skirmish/a is not a folder the lobby downloads into, refused' "$WORK/bridge.log" \
  && ok "resource into a folder the lobby does not use refused" || no "resource folder: $R"
[ ! -e "$WD/AI" ] && [ ! -e "$WD/LuaUI/Widgets/a" ] && ok "refused downloads wrote nothing" || no "a refused download left files"
# The allowed case makes one real request to BAR's widget hub (the file its
# lobby fetches whenever the plugins window opens), so it runs only on request:
#   SL_BRIDGE_NET_TEST=1 packaging/test/sl-bridge-test.sh
if [ "${SL_BRIDGE_NET_TEST:-0}" = "1" ]; then
  R=$(send '{"name":"Download","command":{"name":"plugin_manifest","type":"resource","resource":{"url":"https://widget-hub.beyondallreason.dev/manifests.json","destination":"LuaUI/Widgets/manifests.json","extract":false}}}')
  echo "$R" | grep -q '"isSuccess":true' && [ -s "$WD/LuaUI/Widgets/manifests.json" ] \
    && ok "resource from BAR's widget hub into LuaUI/Widgets downloaded" || no "allowed resource download: $R"
fi

R=$(send '{"name":"Download","command":{"name":"z","type":"engine"}}')
echo "$R" | grep -q '"isSuccess":false' && ok "engine download reported unsupported" || no "engine dl: $R"

R=$(send '{"name":"Download","command":{"name":"Some Map","type":"map"}}')
echo "$R" | grep -q '"DownloadFinished"' && echo "$R" | grep -q '"isSuccess":false' && ok "map download runs pr-downloader and reports its exit" || no "map dl: $R"

R=$(send "{\"name\":\"ParseMiniMap\",\"command\":{\"mapPath\":\"$WD/maps/fixture.sdz\",\"destination\":\"LuaMenu/Images/Minimaps/fixture.jpg\",\"miniMapSize\":4}}")
echo "$R" | grep -q '"ParseMiniMapFinished"' && ok "ParseMiniMap answers ParseMiniMapFinished" || no "ParseMiniMap: $R"
python3 -c "
from PIL import Image; import sys
im=Image.open(sys.argv[1]).convert('RGB'); assert im.size==(1024,1024), im.size
r,g,b=im.getpixel((512,512)); assert r>240 and g<20 and b<20, (r,g,b)
" "$WD/LuaMenu/Images/Minimaps/fixture.jpg" 2>/dev/null && ok "minimap decoded: 1024x1024, the map's own colour" || no "minimap image wrong or missing"
R=$(send '{"name":"ParseMiniMap","command":{"mapPath":"/etc/hosts","destination":"x.jpg"}}')
echo "$R" | grep -q '"ParseMiniMapFinished"' && [ ! -f "$WD/x.jpg" ] && ok "ParseMiniMap on a non-map: finished, no image" || no "ParseMiniMap non-map: $R"
R=$(send '{"name":"ParseMiniMap","command":{"mapPath":"x.sdz","destination":"../../escape.jpg"}}')
[ -z "$R" ] && ok "ParseMiniMap destination outside write dir refused" || no "ParseMiniMap traversal: $R"

R=$(send '{"name":"UploadLog","command":{}}')
echo "$R" | grep -q '"UploadLogFailed"' && echo "$R" | grep -q 'switched off' && ok "UploadLog refused while online play is off" || no "UploadLog: $R"

send '{"name":"DiscordSetActivity","command":{"state":"In lobby","mapName":"Glacial Gap","playerCount":2,"maxPlayerCount":16,"partyId":42}}' > /dev/null
python3 -c "
import json,sys
hs=json.load(open(sys.argv[1]+'.hs'))['handshake']; assert hs=={'v':1,'client_id':'123'}, hs
c=json.load(open(sys.argv[1])); assert c['cmd']=='SET_ACTIVITY', c
a=c['args']['activity']
assert a['state']=='In lobby' and a['details']=='Glacial Gap', a
assert a['assets']['large_image']=='https://maps.example/Glacial%20Gap.jpg', a['assets']
assert a['party']=={'id':'42','size':[2,16]}, a['party']
assert a['buttons'][0]['url']=='https://www.beyondallreason.info/', a['buttons']
" "$WORK/discord.json" 2>/dev/null && ok "Discord: handshake with the app id, SET_ACTIVITY with the lobby's fields" || no "Discord activity wrong or missing ($(cat "$WORK/discord.json" 2>/dev/null | head -c 300))"

kill "$HOLDER"; wait "$HOLDER" 2>/dev/null
for _ in $(seq 40); do kill -0 "$BPID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$BPID" 2>/dev/null && no "bridge still running after parent exit" || ok "bridge exits with its parent"
[ -f "$WD/sl-connection.json" ] && no "sl-connection.json left behind" || ok "sl-connection.json removed on exit"

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
