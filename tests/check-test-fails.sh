#!/bin/sh
# `make check-test-fails`: proves that `make test` fails on a bad suite, by
# planting one in a copy of the tree. One case each:
#
#   fails      a suite with a failing test        make test names it FAIL
#   no-tests   a suite that runs no test          make test names it FAIL
#   hangs      a suite that never ends            make test names it HUNG
#   exit-line  a suite without the shared exit    check-suites names it,
#              form                               and no suite runs
#   no-suites  every suite deleted                make test refuses to pass
#
# The copy is the working tree without .git and build/, so `make deps` in
# it builds chez-libuv's shim and links SRFI-64 itself, and nothing is
# fetched: the container has no network. It holds no real suite, so none
# can run into the 5 s TEST_TIMEOUT. The plant is tests/test-0-plant.sps;
# after it sorts tests/test-1-after.sps, which passes: in the first three
# cases its pass line shows that make test goes on after a failure. Each
# plant but no-tests has a passing test of its own, so only the planted
# fault can fail it.
#
# A case requires a non-zero exit, and compares the lines starting
# "check-suites: " or "test: ", as its run_case names, as a whole: check-suites' verdict, the
# plant's outcome, the after-suite's pass line, and the count. Needs the
# MAKE, TIMEOUT and CHEZ variables the Makefile passes it, and tar.
set -u

: "${MAKE:=make}" "${TIMEOUT:=timeout}" "${CHEZ:?CHEZ is not set}"

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-test-fails.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

copy=$tmp/tree
mkdir "$copy"
( cd "$root" && tar -cf - --exclude=.git --exclude=./build --exclude=./.claude . ) \
  | ( cd "$copy" && tar -xf - ) || { echo "check-test-fails: could not copy the tree" >&2; exit 2; }

failures=0
fail() { echo "check-test-fails: FAILED $*" >&2; failures=$((failures + 1)); }

header='#!r6rs
(import (rnrs) (srfi :64) (techo-testing))
(define runner (test-runner-simple))
(test-runner-current runner)
'
exit_form='(exit (suite-exit-status runner))'

plant_fails="$header"'(test-begin "plant")
(test-equal "planted failure" 1 2)
(test-end "plant")
'"$exit_form"
plant_no_tests="$header"'(test-begin "plant")
(test-end "plant")
'"$exit_form"
plant_hangs="$header"'(test-begin "plant")
(test-equal "planted pass" 1 1)
(test-end "plant")
(let loop () (loop))
'"$exit_form"
plant_exit_line="$header"'(test-begin "plant")
(test-equal "planted pass" 1 1)
(test-end "plant")
(exit 0)'
after="$header"'(test-begin "after")
(test-equal "after passes" 1 1)
(test-end "after")
'"$exit_form"

# run_case PATTERN PLANT [AFTER]: PATTERN is the prefix of the lines to
# compare: "test" for make test's own, "check-suites" for that check's, so
# its pass line, which every other case prints too, is not among them. Resets the copy's suites to the plant and,
# with a third argument, the after-suite; runs make test there; leaves its
# exit status in $status and the lines to compare in $tmp/lines.
run_case() {
  rm -f "$copy"/tests/test-*.sps
  [ -n "$2" ] && printf '%s\n' "$2" > "$copy/tests/test-0-plant.sps"
  [ "${3:-}" = after ] && printf '%s\n' "$after" > "$copy/tests/test-1-after.sps"
  ( cd "$copy" && env TEST_TIMEOUT=5 $MAKE --no-print-directory test ) \
    > "$tmp/out" 2> "$tmp/err" < /dev/null
  status=$?
  cat "$tmp/out" "$tmp/err" | grep -E "^$1: " > "$tmp/lines"
}

# expect NAME LINE...: the case failed (non-zero) and its compared lines are
# exactly LINE..., in order.
expect() {
  name=$1; shift
  if [ "$status" -eq 0 ]; then
    fail "$name: make test exited 0"
    return
  fi
  printf '%s\n' "$@" > "$tmp/want"
  if ! diff "$tmp/want" "$tmp/lines" > "$tmp/diff"; then
    fail "$name: make test's lines are not the expected ones:"
    sed 's/^/  /' "$tmp/diff" >&2
    return
  fi
  echo "check-test-fails: ok $name (make test exited $status: $(head -n 1 "$tmp/lines"))"
}

run_case test "$plant_fails" after
expect fails \
  "test: FAIL tests/test-0-plant.sps (exit 1)" \
  "test: pass tests/test-1-after.sps" \
  "test: ran 2, passed 1, failed 1, hung 0"

run_case test "$plant_no_tests" after
expect no-tests \
  "test: FAIL tests/test-0-plant.sps (exit 1)" \
  "test: pass tests/test-1-after.sps" \
  "test: ran 2, passed 1, failed 1, hung 0"

run_case test "$plant_hangs" after
expect hangs \
  "test: HUNG tests/test-0-plant.sps (no exit within 5s)" \
  "test: pass tests/test-1-after.sps" \
  "test: ran 2, passed 1, failed 0, hung 1"

run_case check-suites "$plant_exit_line" after
expect exit-line \
  "check-suites: tests/test-0-plant.sps: its last datum is (exit 0), not (exit (suite-exit-status runner))"

run_case test ""
expect no-suites \
  "test: no suites: nothing matches tests/test-*.sps"

if [ "$failures" -ne 0 ]; then
  echo "check-test-fails: $failures case(s) failed" >&2
  exit 1
fi
echo "check-test-fails: make test failed on every planted fault, naming it"
