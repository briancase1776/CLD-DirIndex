#!/bin/sh
# tests/cases/20-symbol-audit.sh
# @brief Symbol-index checker cases: each finding code (SYM-DEAD,
# SYM-NAME, SYM-DUP, SYM-HDR, SYM-KEY, SYM-MISS) fires when it should and
# stays quiet when it should not, over throwaway git fixtures.
#
# Run alone (sh tests/cases/20-symbol-audit.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

section "symbol-audit"

# --- SYM-DEAD: the target is gone ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'FILE lib/gone.js\nC Thing        A class\n' > "$d/lib/gone.js.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/gone.js.cld 2>&1); rc=$?
expect_hit "SYM-DEAD fires on a missing target" "SYM-DEAD" "$out"
expect_rc  "SYM-DEAD blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# --- SYM-NAME: index not named after its target ---
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing        A class\n' > "$d/lib/thing.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/thing.cld 2>&1); rc=$?
expect_hit "SYM-NAME fires on the wrong filename" "SYM-NAME" "$out"
expect_hit "SYM-NAME says what it wanted" "thing.js.cld" "$out"
expect_rc  "SYM-NAME blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# --- SYM-DUP: two indexes claiming one target ---
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing        A class\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/thing.js\nC Thing        The twin\n' > "$d/lib/twin.js.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/thing.js.cld 2>&1); rc=$?
expect_hit "SYM-DUP fires on a shared target" "SYM-DUP" "$out"
expect_hit "SYM-DUP names the other claimant" "twin.js.cld" "$out"
expect_rc  "SYM-DUP blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# --- SYM-HDR: an unknown species ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'WIDGET lib/thing.js\nC Thing   x\n' > "$d/lib/odd.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/odd.cld 2>&1); rc=$?
expect_hit "SYM-HDR fires on an unknown token" "SYM-HDR" "$out"
expect_rc  "SYM-HDR blocks (exit 1)" 1 "$rc"

# same fixture, but the repo declares the species in cld.conf
printf 'CLD_EXTRA_SPECIES=%s\n' '"WIDGET"' > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/odd.cld 2>&1); rc=$?
expect_miss "a declared species is accepted" "SYM-HDR" "$out"
expect_rc   "declared species passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- INDEX-species .cld is out of symbol-audit's remit ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_miss "a dir index is not a symbol-audit finding" "SYM-" "$out"
expect_rc   "dir index passes symbol-audit (exit 0)" 0 "$rc"
rm -rf "$d"

# --- SYM-KEY: bare accessor keyword, duplicate key, unbalanced paren ---
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing        A class\nF get           value    leaked accessor\nF Thing.load    Loads\nF Thing.load    Loads again\nR (dangling     Unbalanced\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/thing.js.cld 2>&1); rc=$?
expect_hit "SYM-KEY catches a bare accessor keyword" "field 2 is the keyword" "$out"
expect_hit "SYM-KEY catches a duplicate key" "duplicate key" "$out"
expect_hit "SYM-KEY catches an unbalanced paren" "unbalanced parenthesis" "$out"
expect_rc  "SYM-KEY blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# --- documentation coverage is NOT this tool's business ---
# The version this was extracted from warned (SYM-BRIEF) when a symbol
# had no @brief above its declaration. It was removed as out of scope:
# doc coverage is a fact about source, not about whether the index is
# telling the truth. This asserts it stays gone -- an undocumented
# target must produce no finding at all.
d=$(fixture)
mkdir -p "$d/lib"
printf 'class Thing {\n  load() {}\n}\n' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing         A class\nF Thing.load    Loads it\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/thing.js.cld 2>&1); rc=$?
expect_miss "no doc-coverage finding on an undocumented target" "BRIEF" "$out"
expect_hit  "an honest index over undocumented source is clean" "symbol-audit: clean" "$out"
expect_rc   "undocumented target does not block (exit 0)" 0 "$rc"
rm -rf "$d"

# --- SYM-MISS warns on a declaring source with no index ---
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Orphaned {}' > "$d/lib/orphaned.js"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/orphaned.js 2>&1); rc=$?
expect_hit "SYM-MISS warns on an unindexed declarer" "SYM-MISS" "$out"
expect_rc  "SYM-MISS does not block (exit 0)" 0 "$rc"
rm -rf "$d"

# --- CLD_NOT_SYMBOL_INDEX_RE exempts a borrowed FILE header ---
d=$(fixture)
mkdir -p "$d/notes"
printf 'CLD_NOT_SYMBOL_INDEX_RE=%s\n' "'^notes/plan.*\\.cld\$'" > "$d/cld.conf"
printf 'FILE notes/does-not-exist.md\nC Whatever   borrowed header, other domain\n' > "$d/notes/plan.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh notes/plan.cld 2>&1); rc=$?
expect_miss "an exempted .cld raises nothing" "SYM-" "$out"
expect_rc   "exempted .cld passes (exit 0)" 0 "$rc"
rm -rf "$d"

finish
