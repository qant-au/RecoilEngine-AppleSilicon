#!/bin/bash
# In-app updater (packaging/updater.swift), end to end with no window
# (--yes): build two tiny ad-hoc-signed app bundles, sign v2's zip with a fresh
# key, point a file:// feed at it, and check that a real swap happens, and that
# a wrong key, a tampered archive, a different app, a version mismatch, an
# older feed and a missing feed all leave the installed app alone.
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
