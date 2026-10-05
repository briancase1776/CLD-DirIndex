#!/bin/sh
# tests/cases/30-gate.sh
# @brief Commit-gate cases: install the hooks into a throwaway fixture
# repo and make REAL commits, so the dispatcher, both drop-in gates and
# both checkers are exercised the way a host repo runs them.
#
# Run alone (sh tests/cases/30-gate.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

section "pre-commit gate"

# --- the installed hook actually blocks a real commit ---
d=$(fixture)
$SH "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js    Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
out=$(cd "$d" && git commit -m "unindexed file" 2>&1); rc=$?
expect_hit "the hook blocks a commit with an unindexed file" "NOENTRY" "$out"
expect_rc  "blocked commit exits non-zero" 1 "$rc"

# ...and lets it through once the index is honest
printf 'INDEX lib/\nF known.js    Indexed\nF stray.js    Now indexed too\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && git commit -m "indexed" 2>&1); rc=$?
expect_rc "an honest index commits cleanly" 0 "$rc"
rm -rf "$d"

# --- the symbol gate blocks a real commit too ---
d=$(fixture)
$SH "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
mkdir -p "$d/lib"
printf 'INDEX lib/\nF thing.js    A thing\n' > "$d/lib/index.cld"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing        A class\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/ghost.js\nC Ghost        Indexes a file that is not there\n' > "$d/lib/ghost.js.cld"
stage "$d"
out=$(cd "$d" && git commit -m "dead symbol index" 2>&1); rc=$?
expect_hit  "the hook blocks a commit with a dead symbol index" "SYM-DEAD" "$out"
expect_hit  "the symbol gate names the dead index" "lib/ghost.js.cld" "$out"
expect_rc   "blocked symbol commit exits non-zero" 1 "$rc"
expect_miss "the honest dir index is not what blocked it" "index-audit: BLOCKED" "$out"

# ...and lets it through once the dead index is gone
rm "$d/lib/ghost.js.cld"
stage "$d"
out=$(cd "$d" && git commit -m "honest symbol index" 2>&1); rc=$?
expect_rc  "an honest symbol index commits cleanly" 0 "$rc"
expect_eq  "the honest commit actually landed" "1" "$(git -C "$d" rev-list --count HEAD 2>/dev/null)"
rm -rf "$d"

# --- one commit, both gates: the dispatcher runs every check ---
d=$(fixture)
$SH "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js    Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
printf 'FILE lib/ghost.js\nC Ghost        Indexes a file that is not there\n' > "$d/lib/ghost.js.cld"
stage "$d"
out=$(cd "$d" && git commit -m "two violations" 2>&1); rc=$?
expect_hit "both gates report: the directory finding" "NOENTRY" "$out"
expect_hit "both gates report: the symbol finding" "SYM-DEAD" "$out"
expect_rc  "a commit failing both gates exits non-zero" 1 "$rc"
rm -rf "$d"

finish
