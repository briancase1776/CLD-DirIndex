#!/bin/sh
# tests/cases/40-combined.sh
# @brief Cases for a host running BOTH checkers on one config: the
# adopt-both regression, and the places where the two checkers still
# disagree about the same file.
#
# Run alone (sh tests/cases/40-combined.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

IA=scripts/index-audit/check.sh
SA=scripts/symbol-audit/check.sh

section "adopting both: an older cld.conf"

# While the toolkit was split in two, a host adopting both halves had one
# scripts/cld-config.sh -- whichever installer ran second -- and one
# cld.conf. With the directory half's three-key loader, symbol-audit read
# keys nothing had set and died under set -u. The merged loader defaults
# every key after sourcing, so the directory half's old three-key
# cld.conf (verbatim below) must run both checkers.
d=$(fixture)
cat > "$d/cld.conf" <<'EOF'
CLD_SKIP_RE='\.git/\|node_modules/\|vendor/\|dist/\|build/'
CLD_INDEXABLE_EXTS="js md txt html css json sh"
CLD_NOT_DIR_INDEX_RE=''
EOF
mkdir -p "$d/lib"
printf 'INDEX lib/\nF thing.js      A thing\nF orphaned.js   Declares a class, has no symbol index\nF ghost.js      Not here\n' > "$d/lib/index.cld"
echo 'class Thing {}' > "$d/lib/thing.js"
echo 'class Orphaned {}' > "$d/lib/orphaned.js"
printf 'FILE lib/thing.js\nC Thing        A class\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/gone.js\nC Gone         Indexes a file that is not there\n' > "$d/lib/gone.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_no_shell_error "symbol-audit on a three-key cld.conf does not crash" "$out"
expect_hit "symbol-audit on a three-key cld.conf still finds SYM-DEAD" "SYM-DEAD lib/gone.js.cld" "$out"
expect_hit "symbol-only keys get their defaults (SYM-MISS warns)" "SYM-MISS" "$out"
expect_rc  "symbol-audit on a three-key cld.conf blocks (exit 1)" 1 "$rc"
out=$(cd "$d" && $SH $IA 2>&1); rc=$?
expect_no_shell_error "index-audit on a three-key cld.conf does not crash" "$out"
expect_hit "index-audit on a three-key cld.conf still finds ORPHAN" "ghost.js" "$out"
expect_rc  "index-audit on a three-key cld.conf blocks (exit 1)" 1 "$rc"
# ...and once the tree is honest, both say clean
rm "$d/lib/gone.js.cld"
printf 'INDEX lib/\nF thing.js      A thing\nF orphaned.js   Declares a class, has no symbol index\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_hit "honest tree on a three-key cld.conf: symbol-audit clean" "symbol-audit: clean" "$out"
expect_rc  "honest tree on a three-key cld.conf: symbol-audit exit 0" 0 "$rc"
out=$(cd "$d" && $SH $IA 2>&1); rc=$?
expect_hit "honest tree on a three-key cld.conf: index-audit clean" "index-audit: clean" "$out"
expect_rc  "honest tree on a three-key cld.conf: index-audit exit 0" 0 "$rc"
rm -rf "$d"

section "where the two checkers disagree"

# KNOWN CONFLICT: an index.cld whose line 1 is wrong. index-audit calls
# that BADHDR, a warning -- an odd header is not a lie about the
# directory. symbol-audit reads every .cld, sees an unknown species, and
# BLOCKS it as SYM-HDR. One file, two policies. The agreed fix (scope D)
# is that symbol-audit leaves index.cld (and CLD_NOT_DIR_INDEX_RE) to
# index-audit, so the bad header is BADHDR only. Until then this is
# recorded as KNOWN, not asserted either way; when it reads RESOLVED,
# move the assertion into the case file that owns the fix.
d=$(fixture)
mkdir -p "$d/lib"
printf 'NOTANINDEX lib/\n' > "$d/lib/index.cld"
printf 'WIDGET lib/thing.js\nC Thing   x\n' > "$d/lib/odd.cld"
stage "$d"
out=$(cd "$d" && $SH $IA lib/index.cld 2>&1); rc=$?
expect_hit "index-audit: a bad index.cld header is BADHDR" "BADHDR" "$out"
expect_rc  "index-audit: BADHDR warns (exit 0)" 0 "$rc"
out=$(cd "$d" && $SH $SA lib/index.cld 2>&1)
known_issue "symbol-audit also blocks a bad index.cld header as SYM-HDR (scope D)" "SYM-HDR" "$out"
out=$(cd "$d" && $SH $SA lib/odd.cld 2>&1); rc=$?
expect_hit "control: symbol-audit still blocks an unknown species elsewhere" "SYM-HDR" "$out"
expect_rc  "control: unknown species blocks (exit 1)" 1 "$rc"
rm -rf "$d"

finish
