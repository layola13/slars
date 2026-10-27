#!/bin/bash
# M3 gate: every sa_std .sla checks clean from a .slars root + async/timer
# runtime proof. Usage: bash tests/run_m3.sh
set -u
export PATH=/content/sa_all/sci/zig-out/bin:$PATH
export SA_PLUGIN_DEV=1 SA_STD_DIR=/content/sa_all/sci/sa_std SLA_NO_FRESHNESS_CACHE=1
cd "$(dirname "$0")/.."
rm -rf tests/m3/.sla-cache .sla-cache
ok=0; total=0
for f in tests/m3/import_*.slars; do
  total=$((total+1))
  if timeout 120 sa check "$f" > /tmp/slars_m3.log 2>&1; then ok=$((ok+1)); else echo "M3 CHECK FAILED: $f"; tail -3 /tmp/slars_m3.log; fi
done
echo "m3 imports: $ok/$total"
if timeout 300 sa build-exe tests/m3/run_async_timer.slars -o /tmp/slars_m3run > /tmp/slars_m3.log 2>&1 && timeout 30 /tmp/slars_m3run > /tmp/slars_m3.out 2>&1 && cmp -s /tmp/slars_m3.out tests/m3/run_async_timer.slars.expected.txt; then
  echo "m3 runtime: PASS (async fn driven by sched_block_on_timeout printed 5)"
else
  echo "m3 runtime: FAIL"; tail -3 /tmp/slars_m3.log; cat /tmp/slars_m3.out 2>/dev/null
  exit 1
fi
[ "$ok" = "$total" ] && echo "M3: ALL GREEN" || { echo "M3: FAILURES"; exit 1; }
