#!/bin/bash
# Pre-run checks for unattended builds and test runs on macOS
# (docs/TROUBLESHOOTING.md). Reports only: it changes nothing on the machine.
# Leftover engine processes are listed; scripts/reap.sh stops them.
# Exit 0 = ready, 1 = a blocker.
#
# Usage: scripts/preflight.sh
set -uo pipefail
BAR="$(cd "$(dirname "$0")/.." && pwd)"   # always this checkout: an inherited $BAR is ignored
BLOCK=0; ok(){ echo "  ok    $*"; }; warn(){ echo "  warn  $*"; }; bad(){ echo "  FAIL  $*"; BLOCK=1; }

echo "toolchain:"
xcode-select -p >/dev/null 2>&1 && ok "Xcode tools at $(xcode-select -p)" || bad "no Xcode command line tools (xcode-select --install)"
[ -x /opt/homebrew/bin/g++-15 ] && ok "gcc@15 (libm dbl-64 swap)" || bad "gcc@15 missing (brew install gcc@15)"
command -v ninja >/dev/null && ok "ninja" || bad "ninja missing (brew install ninja)"
{ command -v timeout || command -v gtimeout; } >/dev/null && ok "timeout" || bad "no timeout/gtimeout (brew install coreutils)"
[ -x /opt/homebrew/bin/bash ] && ok "bash 4+ for docker-build-v2" || warn "no Homebrew bash: scripts/check-nonmac.sh cannot run (brew install bash)"
command -v docker >/dev/null && docker info >/dev/null 2>&1 && ok "docker running" || warn "docker not running: scripts/check-nonmac.sh and Linux replays unavailable"
git -C "$BAR" describe --tags --abbrev=0 --match '[0-9]*' >/dev/null 2>&1 \
  && ok "upstream release tag: $(git -C "$BAR" describe --tags --abbrev=0 --match '[0-9]*')" \
  || bad "no Recoil release tag (git fetch upstream --tags)"

echo "autonomy blockers:"
dt=$(defaults read com.apple.CrashReporter DialogType 2>/dev/null || echo "default")
if [ "$dt" = "none" ]; then ok "crash-reporter dialog suppressed"
else warn "crash-reporter dialog is '$dt': a crash pops a modal that halts unattended runs. To suppress (a user setting, decide before running): defaults write com.apple.CrashReporter DialogType none"; fi

echo "stragglers:"
"$BAR/scripts/reap.sh" --dry-run | sed 's/^/  /'

[ "$BLOCK" = 0 ] && echo "PREFLIGHT_OK" || { echo "PREFLIGHT_FAIL"; exit 1; }
