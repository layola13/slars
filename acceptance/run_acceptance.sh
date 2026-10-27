#!/bin/bash
# slars phase-1 acceptance: ts_walk.slars vs ref_walk.sla on frozen samples.
# Usage: bash acceptance/run_acceptance.sh
set -u
export PATH=/content/sa_all/sci/zig-out/bin:$PATH
export SA_PLUGIN_DEV=1 SA_STD_DIR=/content/sa_all/sci/sa_std SLA_NO_FRESHNESS_CACHE=1
export SA_TREE_SITTER_DIR=/content/sa_all/sci/artifacts/tree_sitter
cd "$(dirname "$0")"
rm -rf work .sla-cache
mkdir -p work
cp ref_walk.sla ts_walk.slars byteseq.sa append.sa work/
cd work
timeout 300 sa build-exe ref_walk.sla -o ref_walk > ref_build.log 2>&1 || { echo "REF BUILD FAIL"; tail -5 ref_build.log; exit 1; }
timeout 300 sa build-exe ts_walk.slars -o ts_walk > ts_build.log 2>&1 || { echo "TS BUILD FAIL"; tail -5 ts_build.log; exit 1; }
fail=0
run_case() {
  local sample="$1" lang="$2" expected="$3"
  cp "../samples/$sample" input.src
  TS_WALK_LANG=$lang ./ref_walk > ref.out; local rrc=$?
  TS_WALK_LANG=$lang ./ts_walk > ts.out; local trc=$?
  if [ $rrc -ne 0 ] || [ $trc -ne 0 ]; then echo "FAIL $sample rc ref=$rrc ts=$trc"; fail=1; return; fi
  if ! cmp -s ref.out ts.out; then echo "FAIL $sample: slars output differs from SLA reference"; fail=1; return; fi
  if ! cmp -s ref.out "../$expected"; then echo "FAIL $sample: output differs from frozen expected"; fail=1; return; fi
  echo "PASS $sample ($(wc -c < ref.out) bytes, byte-identical)"
}
run_case sample.ts typescript expected_sample.txt
run_case staticAssetContentType.ts typescript expected_staticAssetContentType.txt
run_case CliBackendIcon.tsx tsx expected_CliBackendIcon.txt
[ $fail -eq 0 ] && echo "ACCEPTANCE: ALL PASS" || echo "ACCEPTANCE: FAILURES"
exit $fail
