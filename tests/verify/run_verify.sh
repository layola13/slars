#!/bin/bash
# slars phase-2 (AG6): plugin_* std semantic verification pack.
# Usage: bash tests/verify/run_verify.sh
#
# POSITIVES (must pass exactly): the three plugin_* std surfaces driven
# for real -- http server loopback via curl, async http client/server in
# one process, sqlite CRUD cross-checked with python3 sqlite3. Where the
# SA-macro facade is not drivable from surface code (DESIGN SS11.1), the
# positives drive the same std ABI through its externs and say so.
#
# REPROS (must fail with the documented signatures at this HEAD): the
# facade drive attempts. If a repro starts passing, the lowering defect
# is fixed -- flip the DESIGN SS11.1 registration and promote the repro.
set -u
export PATH=/content/sa_all/sci/zig-out/bin:$PATH
export SA_PLUGIN_DEV=1 SA_STD_DIR=/content/sa_all/sci/sa_std SLA_NO_FRESHNESS_CACHE=1
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
rm -rf work .sla-cache
mkdir -p work
cp *.slars *.sla "$ROOT/acceptance/byteseq.sa" work/
cd work
fail=0
note_fail() { echo "FAIL: $1"; fail=1; }

# port hygiene: the std server allows multiple listeners on one port, so
# a stale listener would fake a pass. Kill anything on our ports first.
for port in 18097 18098 18099; do
  pid=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -o "pid=[0-9]*" | head -1 | cut -d= -f2)
  if [ -n "${pid:-}" ]; then echo "killing stale listener pid $pid on $port"; kill "$pid" 2>/dev/null; sleep 1; fi
done

build() { # $1 src, $2 out, $3 log
  rm -rf .sla-cache
  timeout 300 sa build-exe "$1" -o "$2" > "$3" 2>&1
}

echo "== positives =="
# --- sqlite ---
if build run_plugin_sqlite.slars sqlt sqlite_build.log; then
  rm -f verify_sqlite.db
  timeout 60 ./sqlt > sqlite.out 2>&1; rc=$?
  [ $rc -eq 0 ] || note_fail "sqlite run rc=$rc"
  cmp -s sqlite.out ../expected_run_plugin_sqlite.txt || note_fail "sqlite stdout differs"
  py=$(python3 -c "import sqlite3; c=sqlite3.connect('verify_sqlite.db'); print(c.execute('SELECT k, v FROM kv ORDER BY k').fetchall())")
  [ "$py" = "[('answer', 42), ('other', 7)]" ] || note_fail "sqlite python cross-check: $py"
  echo "sqlite: run rc=$rc, stdout ok, python cross-check $py"
else
  note_fail "sqlite build"; tail -3 sqlite_build.log
fi
# --- http server loopback ---
if build run_plugin_http_server.slars httpsrv http_build.log; then
  ( timeout 60 ./httpsrv > httpsrv.out 2>&1; echo $? > httpsrv.rc ) &
  sleep 2
  curl -s -m 10 http://127.0.0.1:18097/hello > curl_body.txt; crc=$?
  wait
  [ $crc -eq 0 ] || note_fail "curl rc=$crc"
  [ "$(cat httpsrv.rc)" = "0" ] || note_fail "http server rc=$(cat httpsrv.rc)"
  cmp -s httpsrv.out ../expected_run_plugin_http_server.txt || note_fail "http server stdout differs"
  cmp -s curl_body.txt ../expected_http_body.txt || note_fail "http body differs: $(cat curl_body.txt)"
  echo "http_server: loopback ok, body $(cat curl_body.txt)"
else
  note_fail "http server build"; tail -3 http_build.log
fi
# --- async http ---
if build run_plugin_async_http.slars asynchttp async_build.log; then
  timeout 60 ./asynchttp > async.out 2>&1; rc=$?
  [ $rc -eq 0 ] || note_fail "async http run rc=$rc"
  cmp -s async.out ../expected_run_plugin_async_http.txt || note_fail "async http stdout differs"
  echo "async_http: run rc=$rc, stdout ok"
else
  note_fail "async http build"; tail -3 async_build.log
fi

echo "== repros (expected failure signatures, DESIGN SS11.1) =="
repro_check() { # $1 name, $2 condition-already-evaluated(0/1), $3 detail
  if [ "$2" -eq 0 ]; then echo "REPRO $1: signature confirmed ($3)"; else note_fail "REPRO $1: signature CHANGED ($3) -- update DESIGN SS11.1"; fi
}
# (a) macros are not callable through the .sla surface alone
rm -rf .sla-cache
timeout 240 sa check repro_sla_surface_macros.slars > surf_check.log 2>&1; rc=$?
grep -q "Undefined call: PLUGIN_ASYNC_OP_NEW" surf_check.log; g=$?
[ $rc -ne 0 ] && [ $g -eq 0 ]; repro_check sla_surface_macros $? "check rc=$rc"
# (b) plugin_async facade from a .slars root: build ok, segfault
if build repro_plugin_facades.slars repro_facades facades_build.log; then
  timeout 30 ./repro_facades > /dev/null 2>&1; rc=$?
  [ $rc -eq 139 ]; repro_check plugin_async_facades_slars $? "run rc=$rc"
else
  note_fail "REPRO plugin_async_facades_slars: build failed unexpectedly"; tail -3 facades_build.log
fi
# (c) same from a pure .sla root: segfault (shared lowering, not transform)
if build repro_plugin_facades_twin.sla repro_twin twin_build.log; then
  timeout 30 ./repro_twin > /dev/null 2>&1; rc=$?
  [ $rc -eq 139 ]; repro_check plugin_async_facades_sla $? "run rc=$rc"
else
  note_fail "REPRO plugin_async_facades_sla: build failed unexpectedly"; tail -3 twin_build.log
fi
# (d) wrapper-fn path: poll pointer comes back NULL -> exit 2
if build run_wrap_probe.slars wrap wrap_build.log; then
  timeout 30 ./wrap > /dev/null 2>&1; rc=$?
  [ $rc -eq 2 ]; repro_check poll_wrapper_null $? "run rc=$rc"
else
  note_fail "REPRO poll_wrapper_null: build failed unexpectedly"; tail -3 wrap_build.log
fi
# (e) SA_HTTP_SERVER_ACCEPT_V2 in isolation: segfault
if build repro_accept_v2.slars repro_accept accept_build.log; then
  timeout 30 ./repro_accept > /dev/null 2>&1; rc=$?
  [ $rc -eq 139 ]; repro_check accept_v2 $? "run rc=$rc"
else
  note_fail "REPRO accept_v2: build failed unexpectedly"; tail -3 accept_build.log
fi
# (f) SA_HTTP_SERVER_RESP_SEND_V2: build trap CapabilityMismatch
build repro_resp_send.sla repro_resp resp_build.log; rc=$?
grep -q "CapabilityMismatch" resp_build.log; g=$?
[ $rc -ne 0 ] && [ $g -eq 0 ]; repro_check resp_send_v2 $? "build rc=$rc"
# (g) SA_SQLITE_OPEN/PREPARE facade: build trap RegisterRedefinition
build repro_sqlite_facade.sla repro_sqlf sqlf_build.log; rc=$?
grep -q "RegisterRedefinition" sqlf_build.log; g=$?
[ $rc -ne 0 ] && [ $g -eq 0 ]; repro_check sqlite_facade_open $? "build rc=$rc"

[ $fail -eq 0 ] && echo "VERIFY: ALL PASS (positives pass, repro signatures confirmed)" || echo "VERIFY: FAILURES"
exit $fail
