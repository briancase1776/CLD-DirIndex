# tests/lib.sh
# @brief Shared helpers for the test cases: fixture repos and the
# assertion functions. Sourced (never executed) by every tests/cases/*.sh.
#
# A case file starts with
#   . "$(dirname "$0")/../lib.sh"
# and ends with
#   finish
# and can be run on its own (sh tests/cases/10-index-audit.sh) or through
# tests/run-tests.sh, which runs every case file and adds up the totals.
#
# Environment knobs:
#   CLD_TEST_TOOLKIT  the toolkit under test (default: this checkout).
#                     Point it at an older checkout to watch a new test
#                     fail against the code it was written to catch.
#   CLD_TEST_SH       the shell the checkers run under (default: sh), e.g.
#                     CLD_TEST_SH=dash or CLD_TEST_SH='bash --posix'.
#   CLD_TEST_TALLY    set by run-tests.sh: where finish writes the counts.
#
# A checker that silently stops finding things is the failure mode that
# matters most -- a gate that never blocks looks exactly like a clean
# repo. So every case that expects silence also expects a finding
# somewhere (a positive control): a dead check fails a test.

set -u

# Never let a fixture's git command reach a real repository: a suite run
# from inside a git hook (or under a gate's temp-tree environment) would
# otherwise inherit GIT_DIR and point every fixture at the real one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

TOOLKIT=${CLD_TEST_TOOLKIT:-$(CDPATH= cd "$(dirname "$0")/../.." && pwd)}
SH=${CLD_TEST_SH:-sh}
PASS=0
FAIL=0
KNOWN=0

# Every fixture lives under one per-run directory that is removed on exit,
# so a case that dies half way leaves nothing behind.
CLD_TEST_ROOT=$(mktemp -d) || { echo "tests: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$CLD_TEST_ROOT"' EXIT

# fixture [--conf] -- print a fresh temp git repo with the WHOLE toolkit
# scripts/ dir copied in (checkers, shared library, loader, hooks). With
# --conf, the shipped cld.conf is copied to its root as well; without it
# the repo has no cld.conf and runs on the loader's defaults.
fixture() {
  _fx=$(mktemp -d "$CLD_TEST_ROOT/fx.XXXXXX") || return 1
  cp -R "$TOOLKIT/scripts" "$_fx/"
  [ "${1:-}" = "--conf" ] && cp "$TOOLKIT/cld.conf" "$_fx/"
  git -C "$_fx" init -q
  git -C "$_fx" config user.email t@example.com
  git -C "$_fx" config user.name Test
  # A fixture commit must not depend on the caller's signing setup.
  git -C "$_fx" config commit.gpgsign false
  printf '%s' "$_fx"
}

# plain_dir -- print a fresh temp directory that git will NOT treat as part
# of any repository (for the no-git fallback). Use it with
#   GIT_CEILING_DIRECTORIES="$CLD_TEST_ROOT"
# in the environment of the command run inside it.
plain_dir() {
  mktemp -d "$CLD_TEST_ROOT/plain.XXXXXX"
}

# stage <repo> -- git add -A, quietly.
stage() { git -C "$1" add -A >/dev/null 2>&1; }

# section <title> -- a heading in the output.
section() {
  echo ""
  echo "$1"
  echo "$1" | sed 's/./-/g'
}

# ok <name> -- record a pass
ok() { PASS=$((PASS + 1)); echo "  PASS  $1"; }

# bad <name> <detail> -- record a failure and show the detail
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL  $1"
  echo "        $2"
}

# expect_hit <name> <needle> <output>
expect_hit() {
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "expected '$2' in output; got: $(echo "$3" | tr '\n' '|')" ;;
  esac
}

# expect_miss <name> <needle> <output>
expect_miss() {
  case "$3" in
    *"$2"*) bad "$1" "did NOT expect '$2'; got: $(echo "$3" | tr '\n' '|')" ;;
    *) ok "$1" ;;
  esac
}

# expect_rc <name> <want> <got>
expect_rc() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted exit $2, got $3"; fi
}

# expect_eq <name> <want> <got> -- exact string equality
expect_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else
    bad "$1" "wanted [$(echo "$2" | tr '\n' '|')], got [$(echo "$3" | tr '\n' '|')]"
  fi
}

# expect_no_shell_error <name> <output> -- the checker did not die of a
# shell error part way (an unset variable under set -u, a syntax error, a
# missing command). A crash inside a pipeline subshell can still end in
# "clean", so the message is the evidence, not the exit code.
expect_no_shell_error() {
  case "$2" in
    *"parameter not set"*|*"unbound variable"*|*"yntax error"*|*": not found"*)
      bad "$1" "shell error in output: $(echo "$2" | tr '\n' '|')" ;;
    *) ok "$1" ;;
  esac
}

# known_issue <name> <needle> <output> -- a KNOWN defect, recorded on
# purpose rather than asserted away. While <needle> is still in <output>
# the defect is present: prints KNOWN and counts it, neither pass nor
# fail. Once it is gone, prints RESOLVED so whoever fixed it replaces
# the marker with a real assertion in the case file that owns the fix.
known_issue() {
  case "$3" in
    *"$2"*) KNOWN=$((KNOWN + 1)); echo "  KNOWN $1" ;;
    *) echo "  RESOLVED  $1"
       echo "        the known issue no longer reproduces -- replace this marker with an assertion" ;;
  esac
}

# finish -- print this file's totals, hand them to run-tests.sh, and exit
# 0 (all passed) or 1 (anything failed).
finish() {
  echo ""
  echo "  $PASS passed, $FAIL failed, $KNOWN known"
  if [ -n "${CLD_TEST_TALLY:-}" ]; then
    printf '%s %s %s\n' "$PASS" "$FAIL" "$KNOWN" > "$CLD_TEST_TALLY"
  fi
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}
