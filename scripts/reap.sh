#!/bin/bash
# Stop leftover engine processes from earlier builds and test runs: a straggler
# holds the host port and audio/GL state and makes the next run fatal or flaky.
#
# Only processes this checkout started are touched: the executable must be
# named exactly spring, spring-headless, spring-dedicated or pr-downloader AND
# live under this checkout or under a temporary folder (the test scripts run
# bundles copied there). A game running from /Applications, or from anywhere
# else, is listed as "left alone" and never stopped. SIGTERM first (lets OpenAL
# and EGL close), SIGKILL after a grace period for a genuine hang.
#
# Usage: scripts/reap.sh [--dry-run]
set -uo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
BAR="$(cd "$(dirname "$0")/.." && pwd)"
NAMES=(spring spring-headless spring-dedicated pr-downloader)

ours() { # ours <executable path>
  case "$1" in
    "$BAR"/*|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0;;
  esac
  return 1
}

pids=()
for n in "${NAMES[@]}"; do
  for p in $(pgrep -x "$n" 2>/dev/null); do
    exe=$(ps -o comm= -p "$p" 2>/dev/null)
    if ours "$exe"; then pids+=("$p"); echo "reap: $p $exe"
    else echo "reap: $p $exe (not from this checkout, left alone)"; fi
  done
done
if [ ${#pids[@]} -eq 0 ]; then echo "reap: nothing of ours running"; exit 0; fi
[ "$DRY" = 1 ] && { echo "reap: dry run, nothing stopped (${#pids[@]} would be)"; exit 0; }

kill -TERM "${pids[@]}" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" = 0 ] && { echo "reap: stopped ${#pids[@]} process(es)"; exit 0; }
  sleep 1
done
for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && { echo "reap: SIGKILL $p (no exit after SIGTERM)"; kill -KILL "$p" 2>/dev/null; }; done
echo "reap: done"
