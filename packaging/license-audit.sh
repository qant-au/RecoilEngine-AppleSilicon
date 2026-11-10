#!/bin/bash
# license-audit.sh <bundle.app> — release-gate license compliance check.
#
# Everything is checked in the BUNDLE, which is what ships: the manifest, the
# license texts and the notice are read from Contents/Resources, never from
# the repository.
#
# Asserts:
#   1. every Mach-O binary/dylib in the bundle matches a row of the bundle's
#      LICENSES/MANIFEST.tsv, and at least one Mach-O was found;
#   2. the row's license is one this script knows, and its text is in the
#      bundle's LICENSES/;
#   3. no license text in the bundle is empty or holds a "MISSING" placeholder;
#   4. OpenAL (LGPL) is linked dynamically: the engine binary must not define
#      its symbols. (DevIL, also LGPL, is linked statically by design; NOTICE
#      carries the statement that covers it.)
#   5. COPYING and NOTICE are present, COPYING and LICENSES/GPL-2.0.txt hold
#      the GPL version 2 text itself, and NOTICE names where the source is.
# Exits non-zero on any violation. A bundle that fails this audit must not ship.
set -euo pipefail

BUNDLE=${1:?usage: license-audit.sh <bundle.app>}
RES="$BUNDLE/Contents/Resources"
LICDIR="$RES/LICENSES"
MANIFEST="$LICDIR/MANIFEST.tsv"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST missing"; exit 1; }

# license-text presence: map license id -> expected file in LICENSES/.
# "-" means the text ships as COPYING (checked below).
lic_file() {
  case "$1" in
    GPL-2.0|GPL-2.0-or-later) echo "GPL-2.0.txt";;
    MIT|MIT-style*) echo "MIT-collection.txt";;
    Zlib) echo "Zlib.txt";;
    LGPL-2.1*) echo "LGPL-2.1.txt";;
    FTL*) echo "FTL.txt";;
    BSD-3-Clause*) echo "BSD-3-Clause-collection.txt";;
    Apache-2.0) echo "Apache-2.0.txt";;
    curl*) echo "curl.txt";;
    *) echo "";;
  esac
}

fail=0
found=0

# 5. bundle-level docs
for doc in COPYING NOTICE; do
  if [ ! -s "$RES/$doc" ]; then
    echo "VIOLATION: $doc not present in bundle"; fail=1
  fi
done
if [ -s "$RES/NOTICE" ] && ! grep -q 'https://github.com/' "$RES/NOTICE"; then
  echo "VIOLATION: NOTICE does not say where the source code is published"; fail=1
fi

# the GPL text itself must ship, not a file of that name pointing elsewhere
for gpl in "$RES/COPYING" "$LICDIR/GPL-2.0.txt"; do
  if [ ! -f "$gpl" ] || [ "$(wc -c < "$gpl")" -lt 15000 ] \
     || ! grep -q "GNU GENERAL PUBLIC LICENSE" "$gpl" || ! grep -q "Version 2, June 1991" "$gpl"; then
    echo "VIOLATION: ${gpl#"$BUNDLE"/} is not the GPL version 2 text"; fail=1
  fi
done

# 3. no empty or placeholder text
for txt in "$LICDIR"/*.txt; do
  [ -e "$txt" ] || { echo "VIOLATION: no license texts in ${LICDIR#"$BUNDLE"/}"; fail=1; break; }
  if [ ! -s "$txt" ]; then
    echo "VIOLATION: ${txt#"$BUNDLE"/} is empty"; fail=1
  elif grep -q -E '^MISSING|LICENSE MISSING' "$txt"; then
    echo "VIOLATION: ${txt#"$BUNDLE"/} holds a MISSING placeholder"; fail=1
  fi
done

# 1+2. every Mach-O maps to a manifest row with a known license whose text ships
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q "Mach-O" || continue
  found=$((found+1))
  base=$(basename "$f")
  row=$(awk -F'\t' -v b="$base" '
    $0 ~ /^#/ {next}
    { pat=$1; gsub(/\*/,".*",pat); if (b ~ ("^" pat "$")) {print; exit} }' "$MANIFEST")
  if [ -z "$row" ]; then
    echo "VIOLATION: $base has no MANIFEST.tsv entry"; fail=1; continue
  fi
  lic=$(printf '%s' "$row" | cut -f3)
  txt=$(lic_file "$lic")
  if [ -z "$txt" ]; then
    echo "VIOLATION: $base has license \"$lic\", which this audit does not know"; fail=1
  elif [ ! -s "$LICDIR/$txt" ]; then
    echo "VIOLATION: $base ($lic): license text LICENSES/$txt is not in the bundle"; fail=1
  fi
done < <(find "$BUNDLE" -type f -print0)
if [ "$found" -eq 0 ]; then
  echo "VIOLATION: no Mach-O file found in $BUNDLE, so nothing was audited"; fail=1
fi

# 4. OpenAL must be dynamic: the engine imports, not defines, its symbols
ENGINE=$(find "$BUNDLE" -type f -name spring | head -1)
if [ -n "$ENGINE" ]; then
  if nm -gU "$ENGINE" 2>/dev/null | grep -q " _alcOpenDevice$"; then
    echo "VIOLATION: engine binary DEFINES OpenAL symbols (static LGPL link)"; fail=1
  fi
  if ! otool -L "$ENGINE" | grep -q "libopenal"; then
    echo "WARNING: engine does not link libopenal dynamically (NO_SOUND build?)"
  fi
fi

echo "license-audit: scanned $found Mach-O files in $BUNDLE"
if [ "$fail" -ne 0 ]; then
  echo "license-audit: FAILED"
  exit 1
fi
echo "license-audit: OK"
