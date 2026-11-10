#!/bin/bash
# In-app updater (packaging/updater.swift), end to end with no window
# (--yes): build two tiny ad-hoc-signed app bundles, sign v2's zip with a fresh
# key, point a file:// feed at it, and check that a real swap happens, and that
# a wrong key, a tampered archive, a different app, a version mismatch, an
# older feed, a missing feed, a feed with any field edited, an oversized
# archive and a download address outside the release site all leave the
# installed app alone.
set -u
HERE_T="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }

STAGING_BEFORE=$(ls -d "${TMPDIR:-/tmp/}"TemporaryItems/NSIRD_updater_* 2>/dev/null | wc -l | tr -d ' ')
U="$WORK/updater"
swiftc -O -o "$U" "$HERE_T/../updater.swift" 2>"$WORK/swiftc.log" || { cat "$WORK/swiftc.log"; echo "FAIL: updater.swift does not compile"; exit 1; }

mkapp() { # mkapp <dir> <version> [bundle-id]
  local a="$1/Accurona.app"
  mkdir -p "$a/Contents/MacOS" "$a/Contents/Resources"
  printf '#!/bin/sh\nexit 0\n' > "$a/Contents/MacOS/launcher"; chmod +x "$a/Contents/MacOS/launcher"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${3:-com.accurona.app}" \
    -c "Add :CFBundleShortVersionString string $2" -c "Add :CFBundleExecutable string launcher" \
    -c "Add :CFBundlePackageType string APPL" "$a/Contents/Info.plist" >/dev/null
  echo "$2" > "$a/Contents/Resources/marker"
  codesign -s - --force --deep "$a" 2>/dev/null
}
mkzip() { # mkzip <version> <zip> [bundle-id]
  rm -rf "$WORK/src"; mkdir -p "$WORK/src"; mkapp "$WORK/src" "$1" "${3:-}"
  (cd "$WORK/src" && ditto -c -k --keepParent Accurona.app "$2")
}
fresh_install() { rm -rf "$WORK/inst"; mkdir -p "$WORK/inst"; mkapp "$WORK/inst" 0.13; }
installed() { cat "$WORK/inst/Accurona.app/Contents/Resources/marker" 2>/dev/null; }
check() { # check <feed-url> [key] -> exit status of the updater
  "$U" check --feed "$1" --key-file "${2:-$WORK/pub}" --app "$WORK/inst/Accurona.app" \
    --current 0.13 --seen-file "$WORK/seen" --yes --no-relaunch --wait-swap --timeout 2 >/dev/null 2>"$WORK/err"
}

"$U" keygen --out "$WORK/priv" > "$WORK/pub" && [ -s "$WORK/pub" ] && [ "$(stat -f %Lp "$WORK/priv")" = "600" ] \
  && ok "keygen writes a 0600 private key and prints the public key" || bad "keygen"
"$U" keygen --out "$WORK/priv" >/dev/null 2>&1 && bad "keygen overwrote an existing key" || ok "keygen refuses to overwrite a key"
"$U" keygen --out "$WORK/priv-other" > "$WORK/pub-other"

mkzip 0.14 "$WORK/v14.zip"
"$U" sign --key "$WORK/priv" --archive "$WORK/v14.zip" --version 0.14 --url "file://$WORK/v14.zip" \
  --notes "Test notes" --out "$WORK/feed.json" >/dev/null && ok "sign writes a feed" || bad "sign"

fresh_install; check "file://$WORK/feed.json"; rc=$?
[ "$rc" = "3" ] && [ "$(installed)" = "0.14" ] && ok "newer signed feed: app replaced (exit 3)" || bad "swap: exit $rc, installed $(installed), $(cat "$WORK/err")"
ls "$WORK/inst" | grep -qv '^Accurona.app$' && bad "swap left files beside the app: $(ls "$WORK/inst")" || ok "nothing left beside the app"

fresh_install; check "file://$WORK/feed.json" "$WORK/pub-other"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "not signed" "$WORK/err" && ok "wrong key: refused, app kept" || bad "wrong key: exit $rc, installed $(installed)"

cp "$WORK/v14.zip" "$WORK/v14-orig.zip"; printf 'x' >> "$WORK/v14.zip"
fresh_install; check "file://$WORK/feed.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && ok "tampered archive: refused, app kept" || bad "tampered: exit $rc, installed $(installed)"
cp "$WORK/v14-orig.zip" "$WORK/v14.zip"

mkzip 0.14 "$WORK/other.zip" com.example.other
"$U" sign --key "$WORK/priv" --archive "$WORK/other.zip" --version 0.14 --url "file://$WORK/other.zip" --out "$WORK/feed-other.json" >/dev/null
fresh_install; check "file://$WORK/feed-other.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "different app" "$WORK/err" && ok "different bundle id: refused" || bad "bundle id: exit $rc"

mkzip 0.15 "$WORK/v15.zip"
"$U" sign --key "$WORK/priv" --archive "$WORK/v15.zip" --version 0.14 --url "file://$WORK/v15.zip" --out "$WORK/feed-mis.json" >/dev/null
fresh_install; check "file://$WORK/feed-mis.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "version does not match" "$WORK/err" && ok "version mismatch: refused" || bad "version mismatch: exit $rc"

mkzip 0.12 "$WORK/v12.zip"
"$U" sign --key "$WORK/priv" --archive "$WORK/v12.zip" --version 0.12 --url "file://$WORK/v12.zip" --out "$WORK/feed-old.json" >/dev/null
fresh_install; check "file://$WORK/feed-old.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && ok "older feed: nothing offered" || bad "older: exit $rc"

fresh_install; check "file://$WORK/missing.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && ok "missing feed (offline): carry on" || bad "missing feed: exit $rc"

fresh_install; check "file://$WORK/feed.json" "$WORK/no-key"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && ok "no public key in the build: updates off" || bad "no key: exit $rc"

"$U" sign --key "$WORK/priv" --archive "$WORK/v14.zip" --version 0.14 --url "file://$WORK/v14.zip" \
  --min-system 99.0 --out "$WORK/feed-min.json" >/dev/null
fresh_install; check "file://$WORK/feed-min.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && ok "update for a newer macOS: not offered" || bad "min-system: exit $rc"

# The signature covers the feed's fields: a feed with any of them edited is
# ignored, whatever archive it points at.
edit_feed() { # edit_feed <out> <sed -E expression applied to the good feed>
  sed -E "$2" "$WORK/feed.json" > "$1"
  cmp -s "$WORK/feed.json" "$1" && bad "test bug: the feed edit $2 changed nothing"
}
unsigned() { [ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "not signed by the release key" "$WORK/err"; }
edit_feed "$WORK/feed-ver.json" 's/"version" : "0.14"/"version" : "0.99"/'
fresh_install; check "file://$WORK/feed-ver.json"; rc=$?
unsigned && ok "edited version in the feed: refused, app kept" || bad "edited version: exit $rc, installed $(installed), $(cat "$WORK/err")"
edit_feed "$WORK/feed-len.json" 's/"length" : [0-9]+/"length" : 1/'
fresh_install; check "file://$WORK/feed-len.json"; rc=$?
unsigned && ok "edited length in the feed: refused" || bad "edited length: exit $rc, installed $(installed), $(cat "$WORK/err")"
edit_feed "$WORK/feed-date.json" 's/"date" : "[^"]*"/"date" : "2031-01-01T00:00:00Z"/'
fresh_install; check "file://$WORK/feed-date.json"; rc=$?
unsigned && ok "tampered date in the feed: refused" || bad "tampered date: exit $rc, installed $(installed), $(cat "$WORK/err")"
edit_feed "$WORK/feed-notes.json" 's/"notes" : "Test notes"/"notes" : "Other text"/'
fresh_install; check "file://$WORK/feed-notes.json"; rc=$?
unsigned && ok "edited notes in the feed: refused" || bad "edited notes: exit $rc, installed $(installed), $(cat "$WORK/err")"
sed -E 's/"minimumSystemVersion" : "99.0"/"minimumSystemVersion" : "1.0"/' "$WORK/feed-min.json" > "$WORK/feed-min-edit.json"
fresh_install; check "file://$WORK/feed-min-edit.json"; rc=$?
unsigned && ok "edited minimum system in the feed: refused" || bad "edited minimum system: exit $rc, installed $(installed), $(cat "$WORK/err")"
edit_feed "$WORK/feed-schema1.json" 's/"schema" : 2/"schema" : 1/'
fresh_install; check "file://$WORK/feed-schema1.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "not in a format" "$WORK/err" && ok "feed in the old schema: refused" || bad "old schema: exit $rc, installed $(installed)"

# The archive is read only up to the length the feed promised.
head -c 1048576 /dev/zero >> "$WORK/v14.zip"
fresh_install; check "file://$WORK/feed.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "larger than the update feed promised" "$WORK/err" \
  && ok "oversized download: refused, app kept" || bad "oversized: exit $rc, installed $(installed), $(cat "$WORK/err")"
cp "$WORK/v14-orig.zip" "$WORK/v14.zip"
printf 'x' | dd of="$WORK/v14.zip" bs=1 seek=$(( $(stat -f %z "$WORK/v14.zip") - 1 )) conv=notrunc 2>/dev/null
fresh_install; check "file://$WORK/feed.json"; rc=$?
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "does not match the update feed" "$WORK/err" \
  && ok "archive changed at the same length: refused" || bad "same-length tamper: exit $rc, installed $(installed), $(cat "$WORK/err")"
cp "$WORK/v14-orig.zip" "$WORK/v14.zip"

# A correctly signed feed may still only name an https address under the
# release download base. All of these are refused before any request is made.
BASE="https://github.com/qant-au/RecoilEngine-AppleSilicon/releases/download"
for u in "https://example.com/v0.14/v14.zip" "http://${BASE#https://}/v0.14/v14.zip" \
         "$BASE/../../../../other/repo/releases/download/v14.zip" "$BASE/v0.14/%2e%2e/%2e%2e/%2e%2e/v14.zip" \
         "https://github.com.example.com/${BASE#https://github.com/}/v14.zip" "https://user@github.com/${BASE#https://github.com/}/v14.zip"; do
  "$U" sign --key "$WORK/priv" --archive "$WORK/v14.zip" --version 0.14 --url "$u" --out "$WORK/feed-url.json" >/dev/null
  fresh_install; check "file://$WORK/feed-url.json"; rc=$?
  [ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "outside the release site" "$WORK/err" \
    && ok "download address $u: refused" || bad "address $u: exit $rc, installed $(installed), $(cat "$WORK/err")"
done
# A local archive is for a local feed only; the same feed fetched over the
# network would be refused, which needs a server to show and is not run here.
# An address under the base is accepted (the feed is not newer, so nothing is
# fetched), and --download-base moves the base for a build published elsewhere.
"$U" sign --key "$WORK/priv" --archive "$WORK/v12.zip" --version 0.12 --url "$BASE/v0.12/v12.zip" --out "$WORK/feed-base.json" >/dev/null
fresh_install; check "file://$WORK/feed-base.json"; rc=$?
[ "$rc" = "0" ] && ! grep -q "outside the release site" "$WORK/err" && ok "download address under the release base: accepted" || bad "address under the base: exit $rc, $(cat "$WORK/err")"
"$U" sign --key "$WORK/priv" --archive "$WORK/v12.zip" --version 0.12 --url "https://downloads.example.com/a/v12.zip" --out "$WORK/feed-base2.json" >/dev/null
"$U" check --feed "file://$WORK/feed-base2.json" --key-file "$WORK/pub" --app "$WORK/inst/Accurona.app" --current 0.13 \
  --download-base "https://downloads.example.com/a" --yes --no-relaunch --wait-swap --timeout 2 >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = "0" ] && ! grep -q "outside the release site" "$WORK/err" && ok "--download-base moves the accepted base" || bad "--download-base: exit $rc, $(cat "$WORK/err")"

# An app signed with a Developer ID team must refuse an ad-hoc signed update,
# even one the release key vouches for. There is no certificate here to sign a
# test app with, so the installed app is stood in for by the signed core (the
# Info.plist, main executable and signature; nothing is run) of any team-signed
# app found on this Mac. Skipped where there is none.
TEAMED=0
for donor in /Applications/*.app; do
  exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$donor/Contents/Info.plist" 2>/dev/null) || continue
  id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$donor/Contents/Info.plist" 2>/dev/null) || continue
  rm -rf "$WORK/inst"; mkdir -p "$WORK/inst/Accurona.app/Contents/MacOS" "$WORK/inst/Accurona.app/Contents/Resources"
  cp "$donor/Contents/Info.plist" "$WORK/inst/Accurona.app/Contents/" 2>/dev/null \
    && cp "$donor/Contents/MacOS/$exe" "$WORK/inst/Accurona.app/Contents/MacOS/" 2>/dev/null \
    && cp -R "$donor/Contents/_CodeSignature" "$WORK/inst/Accurona.app/Contents/" 2>/dev/null || continue
  codesign -dv --verbose=2 "$WORK/inst/Accurona.app" 2>&1 | grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' && { TEAMED=1; break; }
done
if [ "$TEAMED" = 1 ]; then
  echo 0.13 > "$WORK/inst/Accurona.app/Contents/Resources/marker"
  mkzip 0.14 "$WORK/team.zip" "$id"
  "$U" sign --key "$WORK/priv" --archive "$WORK/team.zip" --version 0.14 --url "file://$WORK/team.zip" --out "$WORK/feed-team.json" >/dev/null
  check "file://$WORK/feed-team.json"; rc=$?
  [ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "different developer" "$WORK/err" \
    && ok "team-signed app: ad-hoc signed update refused" || bad "team-signed app took an ad-hoc update: exit $rc, installed $(installed), $(cat "$WORK/err")"
else
  echo "skip team-signed app refusing an ad-hoc update (no team-signed app on this Mac to stand in)"
fi

# an app this user cannot move is not offered an update it could not install
fresh_install; chmod 555 "$WORK/inst/Accurona.app"; check "file://$WORK/feed.json"; rc=$?
chmod 755 "$WORK/inst/Accurona.app"
[ "$rc" = "0" ] && [ "$(installed)" = "0.13" ] && grep -q "cannot be moved" "$WORK/err" \
  && ok "immovable app: update not offered, app kept" || bad "immovable app: exit $rc, installed $(installed), $(cat "$WORK/err")"

# no refusal or failure above may leave an unpacked update behind
LEFT=$(ls -d "${TMPDIR:-/tmp/}"TemporaryItems/NSIRD_updater_* 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "$STAGING_BEFORE" ] && ok "no staging folder left behind" || bad "staging folders left: $LEFT (were $STAGING_BEFORE)"

# launcher wiring: the check runs before the message config and quits on 3
grep -q '"\$HERE/updater" check' "$HERE_T/../launcher.sh" && ok "launcher calls the updater" || bad "launcher does not call the updater"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
