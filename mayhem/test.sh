#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the tests build.sh produced in build/tests: the unit tests (tests/unit) and the qtests (tests/qtest) that
# drive the qemu-system-i386 device models the 40 fuzz targets exercise (e1000, ide/ahci, virtio-*, ...).
# Each is a g_test binary: --tap prints one "ok N <path>" / "not ok N <path>" line per assertion-bearing test
# case. A binary that crashes, exits non-zero, or prints no "ok" lines at all (e.g. neutered to exit(0))
# counts as a failure.
. "$SRC/mayhem/unit-tests.list"
. "$SRC/mayhem/qtests.list"
passed=0; failed=0; skipped=0
export QTEST_QEMU_BINARY="$SRC/build/tests/qemu-system-i386" QTEST_QEMU_IMG="$SRC/build/tests/qemu-img"
for bin in qemu-system-i386 qemu-img; do
  [ -x "$SRC/build/tests/$bin" ] || { echo "MISSING $SRC/build/tests/$bin" >&2; failed=$((failed+1)); }
done
for t in $(printf 'unit/%s ' $UNIT_TESTS) $(printf 'qtest/%s ' $QTESTS); do
  bin="$SRC/build/tests/tests/$t"
  if [ ! -x "$bin" ]; then echo "MISSING test binary: $bin" >&2; failed=$((failed+1)); continue; fi
  out=$(timeout 900 "$bin" --tap 2>&1); rc=$?
  ok=$(printf '%s\n' "$out" | grep -c '^ok ')
  skip=$(printf '%s\n' "$out" | grep -c '^ok .*# SKIP')
  bad=$(printf '%s\n' "$out" | grep -c '^not ok ')
  if [ "$rc" -ne 0 ] || [ "$bad" -ne 0 ] || [ "$ok" -eq 0 ]; then
    echo "FAIL $t (rc=$rc ok=$ok not-ok=$bad)" >&2
    printf '%s\n' "$out" | tail -5 >&2
    failed=$((failed + (bad > 0 ? bad : 1)))
  else
    echo "PASS $t ($ok cases)"
  fi
  passed=$((passed + ok - skip)); skipped=$((skipped + skip))
done
emit_ctrf "qemu-unit-qtest-tap" "$passed" "$failed" "$skipped"
