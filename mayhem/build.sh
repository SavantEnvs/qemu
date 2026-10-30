#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# qemu's meson build resolves these subprojects from subprojects/<name>; the image pre-fetches the pinned
# revisions from the .wrap files (mayhem/Dockerfile) so no build ever needs the network. They are
# gitignored, so (re)create them here (the graded rebuild runs after `git clean -ffdX`). The two
# berkeley-* wraps ship a `patch_directory` (meson.build overlay), which meson applies only when it
# downloads, so overlay it by hand.
SUBPROJECT_CACHE=/opt/toolchains/qemu
for sp in keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do
  if [ ! -f "subprojects/$sp/meson.build" ]; then
    rm -rf "subprojects/$sp"
    cp -a "$SUBPROJECT_CACHE/$sp" "subprojects/$sp"
    if [ -d "subprojects/packagefiles/$sp" ]; then cp -a "subprojects/packagefiles/$sp/." "subprojects/$sp/"; fi
  fi
done

mkdir -p build

# 1) Sanitized fuzz build: i386-softmmu qemu-fuzz-i386 (what OSS-Fuzz builds). ASan+UBSan halt; the one
#    relaxed UBSan check is -fno-sanitize=function (qemu's RCU/QOM callbacks are cast to rcu_head*-style
#    function types by design, which aborts on the first RCU callback). LIB_FUZZING_ENGINE is dropped for
#    configure only: set, qemu assumes OSS-Fuzz already supplied -fsanitize=fuzzer-no-link and omits it,
#    leaving the code with no coverage instrumentation (0 edges).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
# Overrides ASan's weak swapcontext interceptor, which prints a stderr warning Mayhem counts as a crash.
$CC -fno-sanitize=all $DEBUG_FLAGS -O2 -c "$SRC/mayhem/swapcontext_quiet.c" -o build/swapcontext_quiet.o
mkdir -p build/fuzz
cd build/fuzz
if [ ! -f build.ninja ]; then
  env -u LIB_FUZZING_ENGINE ../../configure --disable-werror --cc="$CC" --cxx="$CXX" \
      --enable-fuzzing --disable-tests --target-list=i386-softmmu \
      --extra-cflags="$SANITIZER_FLAGS -fno-sanitize=function $DEBUG_FLAGS" \
      --extra-ldflags="$SANITIZER_FLAGS $SRC/build/lsan_off.o $SRC/build/swapcontext_quiet.o"
fi
ninja -j"$MAYHEM_JOBS" qemu-fuzz-i386

# One executable per OSS-Fuzz generic-fuzz-<config> target: qemu selects the target from the
# "-target-<name>" suffix of argv[0] (scripts/oss-fuzz/build.sh does the same). Hard links keep the
# executable's directory (and thus qemu's data-file lookup) inside build/fuzz.
targets=$(ASAN_OPTIONS=detect_leaks=0 ./qemu-fuzz-i386 2>&1 | awk '$1 == "*" && $2 ~ /^generic-fuzz-/ {print $2}')
[ -n "$targets" ] || { echo "no generic-fuzz targets found" >&2; exit 1; }
for t in $targets; do
  ln -f qemu-fuzz-i386 "qemu-fuzz-i386-target-$t"
done
cd "$SRC"

# 2) No standalone (non-fuzzer) reproducers: a second full qemu build would be needed to swap the engine;
#    reproduce a crash by running the libFuzzer binary on the crashing input file instead.

# 3) Test suite, NORMAL flags (no sanitizers, no -gdwarf-3): qemu's own tests in a separate build dir —
#    the unit tests, plus qemu-system-i386 and the qtests that drive its device models (mayhem/qtests.list).
#    Both build dirs live under build/, which upstream's .gitignore covers.
mkdir -p build/tests
cd build/tests
if [ ! -f build.ninja ]; then
  env -u CFLAGS -u LDFLAGS -u LIB_FUZZING_ENGINE ../../configure --disable-werror --cc="$CC" --cxx="$CXX" \
      --target-list=i386-softmmu --disable-user --disable-docs \
      --extra-cflags="$COVERAGE_FLAGS" --extra-ldflags="$COVERAGE_FLAGS"
fi
. "$SRC/mayhem/unit-tests.list"
. "$SRC/mayhem/qtests.list"
ninja -j"$MAYHEM_JOBS" qemu-system-i386 qemu-img \
    $(printf 'tests/unit/%s ' $UNIT_TESTS) $(printf 'tests/qtest/%s ' $QTESTS)
