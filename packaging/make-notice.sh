#!/bin/bash
# make-notice.sh <bundle.app> <bar|engine> <release tag>
#
# Write Contents/Resources/NOTICE from what the bundle actually holds, so the
# notice cannot drift from the build: the dynamic libraries are read from
# Contents/Frameworks, the statically linked ones from the source table in
# scripts/build-static-libs.sh and the "#static" rows of LICENSES/MANIFEST.tsv.
# A library in the bundle that the manifest does not know fails the build.
set -euo pipefail

BUNDLE=${1:?usage: make-notice.sh <bundle.app> <bar|engine> <release tag>}
PROFILE=${2:?profile (bar|engine)}
TAG=${3:?release tag}
HERE=$(cd "$(dirname "$0")" && pwd)
BAR="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/LICENSES/MANIFEST.tsv"
REPO_URL="https://github.com/qant-au/RecoilEngine-AppleSilicon"
OUT="$BUNDLE/Contents/Resources/NOTICE"
[ -d "$BUNDLE/Contents/Frameworks" ] || { echo "FATAL: $BUNDLE has no Contents/Frameworks"; exit 1; }

# manifest row for a file name: prints "component<TAB>license"
row_for() {
  awk -F'\t' -v b="$1" '
    $0 ~ /^#/ {next}
    { pat=$1; gsub(/\./,"\\.",pat); gsub(/\*/,".*",pat); if (b ~ ("^" pat "$")) {print $2 "\t" $3; exit} }' "$MANIFEST"
}

case "$PROFILE" in
  bar)    TITLE="NOTICE: Accurona, a macOS build of the Recoil engine with a helper for Beyond All Reason";;
  engine) TITLE="NOTICE: Recoil engine for macOS";;
  *) echo "FATAL: unknown profile $PROFILE"; exit 1;;
esac

{
  echo "$TITLE"
  echo
  echo "This application is a build of the Recoil engine (GPL-2.0-or-later). The"
  echo "complete corresponding source code for every binary in this bundle, with"
  echo "all macOS changes and the scripts that build it, is published at"
  echo "  $REPO_URL"
  echo "under the release tag $TAG. The GPL text ships in this bundle as COPYING."
  echo
  echo "Graphics driver: Mesa (Zink and KosmicKrisp, MIT license), built from a"
  echo "pinned upstream Mesa commit plus the patches under patches/mesa/ in the"
  echo "repository above. KosmicKrisp is developed by LunarG and Google within"
  echo "upstream Mesa. The driver library contains SPIRV-Tools (Apache-2.0,"
  echo "LICENSES/Apache-2.0.txt) and zstd (BSD-3-Clause). LLVM, libclc and the"
  echo "SPIRV-LLVM-Translator are used to build the driver; none of their code"
  echo "is linked into it."
  echo
  echo "Libraries shipped beside the engine (Contents/Frameworks), each license"
  echo "text under LICENSES/:"
  echo
  seen=""
  for f in "$BUNDLE/Contents/Frameworks"/*.dylib; do
    [ -L "$f" ] && continue
    base=$(basename "$f")
    row=$(row_for "$base")
    [ -n "$row" ] || { echo "FATAL: $base is in the bundle but not in MANIFEST.tsv" >&2; exit 1; }
    line="- $(printf '%s' "$row" | cut -f1): $(printf '%s' "$row" | cut -f2)"
    case "$seen" in *"|$line|"*) continue;; esac
    seen="$seen|$line|"
    echo "$line"
  done
  echo
  echo "Libraries linked statically into the engine, built from pinned source"
  echo "(scripts/build-static-libs.sh in the repository above), each under its"
  echo "own license: texts in LICENSES/image-codecs-collection.txt,"
  echo "LICENSES/BSD-3-Clause-collection.txt and LICENSES/LGPL-2.1-DevIL.txt:"
  echo
  sed -n "/^SOURCES='/,/^'/p" "$BAR/scripts/build-static-libs.sh" | grep '|' | cut -d'|' -f1 \
    | sed -e 's/\.tar\.gz$//' -e 's/^jpegsrc\.v/libjpeg (IJG) /' -e 's/^tiff-/libtiff-/' -e 's/^/- /'
  echo
  echo "Other components linked statically, into the engine from its own source"
  echo "tree unless the driver library is named:"
  echo
  awk -F'\t' '$1 == "#static" { print "- " $2 ": " $3 }' "$MANIFEST"
  echo
  echo "LGPL components:"
  echo
  echo "- openal-soft (LGPL-2.1) is linked dynamically. You may replace the copy"
  echo "  under Contents/Frameworks with your own build."
  echo "- DevIL (LGPL-2.1) is linked statically into the engine. The engine's"
  echo "  complete source and build scripts are published at the address above,"
  echo "  so you can rebuild the engine with a modified DevIL (LGPL section 6)."
  echo "- streflop (LGPL-2.1) is compiled in from the engine's own source tree,"
  echo "  which is part of the source published above."
  echo
  echo "FreeType is used under the FreeType License: portions of this software"
  echo "are copyright The FreeType Project (freetype.org). All rights reserved."
  echo
  if [ "$PROFILE" = "bar" ]; then
    echo "Game content (units, maps, sounds, the game itself) is NOT distributed"
    echo "with this application. On first run the app downloads Beyond All Reason"
    echo "content from the BAR project's content network; that content belongs to"
    echo "the BAR project, under its own licenses."
    echo
  fi
  echo "Code signing: a signature on this bundle states who distributed it. It"
  echo "does not alter or supersede any license above."
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "notice: wrote $(wc -l < "$OUT" | tr -d ' ') lines for profile $PROFILE, tag $TAG"
