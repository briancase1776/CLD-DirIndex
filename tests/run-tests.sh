#!/bin/sh
# @brief Test runner: runs every tests/cases/*.sh in name order, each in
# its own shell, and prints the combined totals.
#
# Usage: tests/run-tests.sh [prefix...]   (exit 0 = all pass, 1 = any failure)
#   tests/run-tests.sh          every case file
#   tests/run-tests.sh 10 40    only the case files whose names start so
#
# The helpers and the fixture builder live in tests/lib.sh; each case file
# owns one area. A case file that dies before reporting its totals counts
# as a failure -- a suite that stops early must not read as a clean run.
# See tests/lib.sh for CLD_TEST_TOOLKIT and CLD_TEST_SH.

set -u

TESTS=$(CDPATH= cd "$(dirname "$0")" && pwd)
RUN_SH=${CLD_TEST_SH:-sh}
TALLY=$(mktemp) || exit 2
trap 'rm -f "$TALLY"' EXIT

pass=0
fail=0
known=0
files=0

wanted() {
  [ "$#" -le 1 ] && return 0
  _name=$1; shift
  for _p in "$@"; do
    case "$_name" in "$_p"*) return 0 ;; esac
  done
  return 1
}

for c in "$TESTS"/cases/*.sh; do
  [ -f "$c" ] || continue
  name=${c##*/}
  wanted "$name" "$@" || continue
  files=$((files + 1))
  echo ""
  echo "=== $name"
  : > "$TALLY"
  CLD_TEST_TALLY=$TALLY $RUN_SH "$c"
  rc=$?
  p=0; f=0; k=0
  if [ -s "$TALLY" ]; then
    read -r p f k < "$TALLY"
  fi
  if [ ! -s "$TALLY" ] || { [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; }; then
    echo "  FAIL  $name exited $rc before reporting its totals"
    f=$((f + 1))
  fi
  pass=$((pass + p))
  fail=$((fail + f))
  known=$((known + k))
done

if [ "$files" -eq 0 ]; then
  echo "run-tests: no case files matched" >&2
  exit 1
fi

echo ""
echo "================================"
echo "  $pass passed, $fail failed, $known known  ($files case files)"
echo "================================"
[ "$fail" -eq 0 ] || exit 1
exit 0
