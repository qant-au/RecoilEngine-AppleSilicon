#!/bin/bash
# Stop leftover engine processes from earlier runs (docs/AGENT_FAILURE_MODES.md
# AB-7): a straggler holds the host port and audio/GL state and makes the next
# run fatal or flaky. Matches EXACT process names only (pgrep -x), never a
# substring, so nothing else on the machine can be caught. SIGTERM first (lets
# OpenAL/EGL close), SIGKILL after a grace period for a genuine hang.
#
# Usage: scripts/reap.sh [--dry-run]
set -uo pipefail
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
NAMES=(spring spring-headless spring-dedicated pr-downloader)

pids=()
for n in "${NAMES[@]}"; do
  for p in $(pgrep -x "$n" 2>/dev/null); do pids+=("$p"); done
done
if [ ${#pids[@]} -eq 0 ]; then echo "reap: nothing running"; exit 0; fi
for p in "${pids[@]}"; do echo "reap: $p $(ps -o comm= -p "$p" 2>/dev/null)"; done
[ "$DRY" = 1 ] && { echo "reap: dry run, nothing stopped"; exit 0; }

kill -TERM "${pids[@]}" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ "$alive" = 0 ] && { echo "reap: stopped ${#pids[@]} process(es)"; exit 0; }
  sleep 1
done
for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && { echo "reap: SIGKILL $p (no exit after SIGTERM)"; kill -KILL "$p" 2>/dev/null; }; done
echo "reap: done"
