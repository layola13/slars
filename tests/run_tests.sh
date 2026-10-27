#!/bin/bash
# slars corpus runner: pass/ (check rc=0), fail/ (rc!=0 + EXPECT code in
# stderr), run/ (build-exe + stdout == .expected.txt), unit (sa test).
# Serial, timeout-wrapped. Usage: bash tests/run_tests.sh
set -u
export PATH=/content/sa_all/sci/zig-out/bin:$PATH
export SA_PLUGIN_DEV=1 SA_STD_DIR=/content/sa_all/sci/sa_std SLA_NO_FRESHNESS_CACHE=1
cd "$(dirname "$0")/.."
rm -rf .sla-cache tests/.sla-cache
pass_ok=0; pass_total=0; fail_ok=0; fail_total=0; run_ok=0; run_total=0
for f in tests/pass/*.slars; do
  pass_total=$((pass_total+1))
  if timeout 120 sa check "$f" > /tmp/slars_t.log 2>&1; then pass_ok=$((pass_ok+1)); else echo "PASS-CASE FAILED: $f"; tail -3 /tmp/slars_t.log; fi
done
for f in tests/fail/*.slars; do
  fail_total=$((fail_total+1))
  code=$(head -1 "$f" | sed -n 's/.*EXPECT: \([A-Z0-9-]*\).*/\1/p')
  if timeout 120 sa check "$f" > /tmp/slars_t.log 2>&1; then echo "FAIL-CASE PASSED UNEXPECTEDLY: $f"; continue; fi
  if grep -q "slars check error \[$code\]" /tmp/slars_t.log; then fail_ok=$((fail_ok+1)); else echo "FAIL-CASE WRONG DIAGNOSTIC: $f (want $code)"; tail -3 /tmp/slars_t.log; fi
done
for f in tests/run/*.slars; do
  run_total=$((run_total+1))
  bin=/tmp/slars_run_$(basename "$f" .slars)
  if ! timeout 300 sa build-exe "$f" -o "$bin" > /tmp/slars_t.log 2>&1; then echo "RUN-CASE BUILD FAILED: $f"; tail -3 /tmp/slars_t.log; continue; fi
  if timeout 30 "$bin" > /tmp/slars_out.txt 2>&1 && cmp -s /tmp/slars_out.txt "$f.expected.txt"; then run_ok=$((run_ok+1)); else echo "RUN-CASE OUTPUT MISMATCH: $f"; diff "$f.expected.txt" /tmp/slars_out.txt | head -5; fi
done
unit_line=$(timeout 300 sa test tests/unit_core.slars 2>&1 | tail -3)
echo "unit: $unit_line"
echo "pass: $pass_ok/$pass_total  fail: $fail_ok/$fail_total  run: $run_ok/$run_total"
if [ "$pass_ok" = "$pass_total" ] && [ "$fail_ok" = "$fail_total" ] && [ "$run_ok" = "$run_total" ]; then echo "CORPUS: ALL GREEN"; exit 0; fi
echo "CORPUS: FAILURES PRESENT"; exit 1
