#!/bin/bash
# sl-bridge-test.sh: drives packaging/sl-bridge.swift over its real TCP protocol
# with a scripted lobby client. No GUI, no network (download tests use refused
# inputs only). Needs a demo to parse: SL_BRIDGE_TEST_DEMO=<path.sdfz>, default
# deps/test-demos/duel.sdfz (a public 2026.07.04 BAR duel); skipped if absent.
# Usage: packaging/test/sl-bridge-test.sh
set -uo pipefail
BAR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sl-bridge-test.XXXXXX")
WD2="$WORK/wd2"   # write dir of the second bridge (the StartNewSpring and UploadLog cases)
trap 'kill $BPID $HOLDER ${DISCORD:-} ${B2PID:-} $(cat "$WD2/engine-starts" 2>/dev/null) 2>/dev/null; rm -rf "$WORK" "${DTMP:-}"' EXIT
PASS=0; FAIL=0
ok(){ echo "  ok   $*"; PASS=$((PASS+1)); }; no(){ echo "  FAIL $*"; FAIL=$((FAIL+1)); }

swiftc -O -o "$WORK/sl-bridge" "$BAR/packaging/sl-bridge.swift" 2>/dev/null || { echo "FATAL: compile failed"; exit 1; }
WD="$WORK/wd"; mkdir -p "$WD/demos"
DEMO="${SL_BRIDGE_TEST_DEMO:-$BAR/deps/test-demos/duel.sdfz}"
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

# The demo is read as a stream: the script is kept, the demo stream is read
# past to reach the winners behind it, and sizes no real demo has are refused.
cat > "$WORK/demos.py" <<'PY'
import gzip, struct, sys
SCRIPT = b'[game]\n{\n\tmapname=Fixture Map;\n\tgametype=Fixture Game;\n}\n'
def demo(name, stream=0, winners=b'', claim_script=None, claim_stream=None):
    h = bytearray(352); h[0:15] = b'spring demofile'
    struct.pack_into('<i', h, 20, 352)                                       # headerSize
    struct.pack_into('<i', h, 304, len(SCRIPT) if claim_script is None else claim_script)
    struct.pack_into('<i', h, 308, stream if claim_stream is None else claim_stream)
    struct.pack_into('<i', h, 312, 77)                                       # gameTime
    struct.pack_into('<i', h, 348, len(winners))
    zeros = bytes(1 << 20)
    with gzip.open(sys.argv[1] + '/' + name, 'wb', compresslevel=1) as f:
        f.write(bytes(h) + SCRIPT)
        for _ in range(stream >> 20): f.write(zeros)
        f.write(zeros[:stream & 0xFFFFF] + winners)
demo('small.sdfz', stream=1000, winners=b'\x01')
demo('bigscript.sdfz', claim_script=64 << 20)             # a 64 MB start script
demo('farwinners.sdfz', claim_stream=1 << 30, winners=b'\x01')   # winners 1 GB in
demo('bomb.sdfz', stream=300 << 20, winners=b'\x02')      # 300 MB once decompressed
PY
python3 "$WORK/demos.py" "$WD/demos"
replay(){ # replay <name> <python expression over c, the ReplayInfo for that demo>
  python3 -c "
import json,sys
c=[m['command'] for m in map(json.loads, filter(str.strip, sys.stdin)) if m['name']=='ReplayInfo' and m['command']['relativePath']=='demos/$1']
assert len(c)==1, c
c=c[0]; assert $2, c"
}
R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"demos/small.sdfz"}}' \
         '{"name":"ReadReplayInfo","command":{"relativePath":"demos/bigscript.sdfz"}}' \
         '{"name":"ReadReplayInfo","command":{"relativePath":"demos/farwinners.sdfz"}}')
echo "$R" | replay small.sdfz "c['map']=='Fixture Map' and c['game']=='Fixture Game' and c['gameTime']==77 and c['winningAllyTeamIds']==[1]" 2>/dev/null \
  && ok "replay read as a stream: script parsed, winners found behind the demo stream" || no "streamed replay: $R"
! echo "$R" | grep -q 'bigscript' && grep -q 'bad demo header: demos/bigscript.sdfz' "$WORK/bridge.log" \
  && ok "replay claiming an oversized script refused" || no "oversized script: $R"
echo "$R" | replay farwinners.sdfz "c['map']=='Fixture Map' and c['winningAllyTeamIds']==[]" 2>/dev/null \
  && ok "winners beyond the read limit: replay listed without them" || no "far winners: $R"
R=$(send '{"name":"ReadReplayInfo","command":{"relativePath":"demos/bomb.sdfz"}}')
echo "$R" | replay bomb.sdfz "c['winningAllyTeamIds']==[2]" 2>/dev/null \
  && ok "300 MB replay read through to its winners" || no "large replay: $R"

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
[ -z "$R" ] && [ ! -f "$WD/x.jpg" ] && grep -q 'ParseMiniMap hosts: failed' "$WORK/bridge.log" \
  && ok "ParseMiniMap on a non-map: no image, so no ParseMiniMapFinished" || no "ParseMiniMap non-map: $R"
# The minimap pointer comes from the map file. "deep" has its minimap 5 MB in
# (blue, behind white filler): found by reading past the filler. "far" points
# near 2 GB and "short" past the end of its .smf: no picture and no reply.
for spec in deep:5242880 far:2147483000 short:1048576; do
  n=${spec%%:*}
  mkdir -p "$WORK/map-$n/maps"
  python3 -c "
import struct,sys
ptr=int(sys.argv[2])
hdr=bytearray(80); hdr[0:16]=b'spring map file\\0'
struct.pack_into('<i',hdr,64,ptr)
body=b'\\xff'*4096
if sys.argv[3]=='deep': body=b'\\xff'*(ptr-80)+struct.pack('<HHI',0x001F,0x001F,0)*(256*256)
open(sys.argv[1],'wb').write(bytes(hdr)+body)
" "$WORK/map-$n/maps/$n.smf" "${spec##*:}" "$n"
  (cd "$WORK/map-$n" && /usr/bin/zip -q -r "$WD/maps/$n.sdz" maps)
done
R=$(send "{\"name\":\"ParseMiniMap\",\"command\":{\"mapPath\":\"$WD/maps/deep.sdz\",\"destination\":\"deep.png\"}}" \
         "{\"name\":\"ParseMiniMap\",\"command\":{\"mapPath\":\"$WD/maps/far.sdz\",\"destination\":\"far.png\"}}" \
         "{\"name\":\"ParseMiniMap\",\"command\":{\"mapPath\":\"$WD/maps/short.sdz\",\"destination\":\"short.png\"}}")
python3 -c "
from PIL import Image; import sys
im=Image.open(sys.argv[1]).convert('RGB'); assert im.size==(1024,1024), im.size
for xy in ((0,0),(512,512),(1023,1023)):
    r,g,b=im.getpixel(xy); assert r<20 and g<20 and b>240, (xy,r,g,b)
" "$WD/deep.png" 2>/dev/null && ok "minimap 5 MB into the map found" || no "deep minimap wrong or missing: $R"
[ "$(echo "$R" | grep -c '"ParseMiniMapFinished"')" = 1 ] && [ ! -f "$WD/far.png" ] && grep -q 'minimap missing in maps/far.smf' "$WORK/bridge.log" \
  && ok "minimap pointer near 2 GB refused, no reply" || no "far minimap pointer: $R"
[ ! -f "$WD/short.png" ] && grep -q 'minimap missing in maps/short.smf' "$WORK/bridge.log" && kill -0 "$BPID" 2>/dev/null \
  && ok "minimap pointer past the end of the map refused, bridge still running" || no "short minimap: $R"
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

# A client that never ends its line is dropped once 1 MB is pending.
cat > "$WORK/noline.py" <<'PY'
import json, socket, sys
c = json.load(open(sys.argv[1]))
s = socket.create_connection((c["_sl_address"], c["_sl_port"]), timeout=5)
closed = False
try:
    for _ in range(32):
        s.sendall(b"a" * 65536)           # 2 MB in all, no newline
    closed = s.recv(1) == b""
except (BrokenPipeError, ConnectionResetError):
    closed = True
except Exception:
    closed = False
sys.exit(0 if closed else 1)
PY
python3 "$WORK/noline.py" "$WD/sl-connection.json" && grep -q 'line over 1 MB' "$WORK/bridge.log" && kill -0 "$BPID" 2>/dev/null \
  && ok "2 MB without a newline: connection dropped, bridge still running" || no "an endless line was not dropped"

# Nothing above (a 300 MB replay, the map pointers, the endless line) may have
# been held in memory: the bridge's lifetime peak footprint (proc_pid_rusage)
# stays small. Skipped where the system does not report it.
PEAK=$(python3 -c "
import ctypes, struct, sys
b = ctypes.create_string_buffer(1024)
if ctypes.CDLL('/usr/lib/libproc.dylib').proc_pid_rusage(int(sys.argv[1]), 4, b) == 0:
    print(struct.unpack_from('<Q', b.raw, 240)[0] >> 20)" "$BPID" 2>/dev/null)
if [ -n "$PEAK" ]; then
  [ "$PEAK" -lt 150 ] && ok "bridge peak memory ${PEAK} MB: oversized inputs were not held in memory" || no "bridge peak memory ${PEAK} MB"
else
  echo "  skip peak memory check (not reported on this system)"
fi

# A second bridge whose engine is a small program of our own, so that what
# StartNewSpring starts stays up and can be counted. Started with --write-dir
# it records its pid and waits; otherwise it is the lobby client (the bridge
# only talks to its engine binary). This bridge has online play on and a log
# address nothing listens at, so UploadLog gets as far as packing the logs.
cat > "$WORK/engine.c" <<'C'
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc > 2 && strcmp(argv[1], "--write-dir") == 0) {
        char path[4096];
        snprintf(path, sizeof path, "%s/engine-starts", argv[2]);
        FILE *f = fopen(path, "a");
        if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
        sleep(120);
        return 0;
    }
    if (argc < 2) return 2;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(atoi(argv[1])); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) return 1;
    for (int i = 2; i < argc; i++) { write(s, argv[i], strlen(argv[i])); write(s, "\n", 1); }
    struct timeval tv = {3, 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char buf[65536]; ssize_t n;
    while ((n = read(s, buf, sizeof buf)) > 0) fwrite(buf, 1, (size_t)n, stdout);
    return 0;
}
C
cc -o "$WORK/engine" "$WORK/engine.c" 2>/dev/null || { echo "FATAL: the stand-in engine did not compile"; exit 1; }
mkdir -p "$WD2"
echo "log" > "$WD2/infolog.txt"; echo "log" > "$WD2/-T.log"     # zip would read -T.log as options
printf '%s' '{"log_upload_url":"https://127.0.0.1:1"}' > "$WORK/extras2.json"
"$WORK/sl-bridge" --writedir "$WD2" --prd /usr/bin/false --engine "$WORK/engine" \
  --engine-version 2026.07.04 --config "$WORK/extras2.json" --online 1 \
  --parent-pid "$HOLDER" --log "$WORK/bridge2.log" > "$WORK/out2" &
B2PID=$!
for _ in $(seq 50); do grep -q SL_BRIDGE_READY "$WORK/out2" 2>/dev/null && break; sleep 0.1; done
PORT2=$(sed -n 's/^SL_BRIDGE_READY //p' "$WORK/out2")
START='{"name":"StartNewSpring","command":{"Engine":"2026.07.04","StartDemoName":"demos/x.sdfz"}}'
"$WORK/engine" "$PORT2" "$START" "$START" "$START" > /dev/null
[ "$(wc -l < "$WD2/engine-starts" | tr -d ' ')" = 1 ] && [ "$(grep -c 'StartNewSpring ignored' "$WORK/bridge2.log")" = 2 ] \
  && ok "StartNewSpring three times: one engine started, the rest ignored while it runs" || no "StartNewSpring started $(cat "$WD2/engine-starts" 2>/dev/null | wc -l | tr -d ' ') engines"
kill "$(head -1 "$WD2/engine-starts")" 2>/dev/null; sleep 0.5
"$WORK/engine" "$PORT2" "$START" > /dev/null
[ "$(wc -l < "$WD2/engine-starts" | tr -d ' ')" = 2 ] && ok "StartNewSpring works again once that engine has exited" || no "StartNewSpring stayed off after the engine exited"

R=$("$WORK/engine" "$PORT2" '{"name":"UploadLog","command":{}}')
echo "$R" | grep -q 'did not accept the upload' && ! echo "$R" | grep -q 'Could not pack' \
  && ok "UploadLog packs a log whose name starts with a dash" || no "UploadLog with a dash-named log: $R"

kill "$HOLDER"; wait "$HOLDER" 2>/dev/null
for _ in $(seq 40); do kill -0 "$BPID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$BPID" 2>/dev/null && no "bridge still running after parent exit" || ok "bridge exits with its parent"
[ -f "$WD/sl-connection.json" ] && no "sl-connection.json left behind" || ok "sl-connection.json removed on exit"

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
