#!/bin/sh
# tests/cases/20-symbol-audit.sh
# @brief Symbol-side cases over throwaway git fixtures: each symbol-audit
# finding (SYM-DEAD, SYM-NAME, SYM-DUP, SYM-HDR, SYM-KEY, SYM-CRLF,
# SYM-STALE, SYM-MISS) fires when it should and stays quiet when it
# should not; the exemption policy, language detection, the --gone
# contract and error propagation; the shared lookup script (find,
# dupecheck, deps, rdeps) and the symbol-* skills that call it.
#
# Run alone (sh tests/cases/20-symbol-audit.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

SA=scripts/symbol-audit/check.sh
LK=scripts/symbol-lookup/lookup.sh

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


section "one exemption policy: what is a symbol index"

# An index.cld is a directory index whatever its line 1 says: a bad
# header there is index-audit's BADHDR (a warning), never also a
# symbol-audit SYM-HDR block. (Was KNOWN in 40-combined.sh.)
d=$(fixture)
mkdir -p "$d/lib"
printf 'NOTANINDEX lib/\n' > "$d/lib/index.cld"
printf 'WIDGET lib/thing.js\nC Thing   x\n' > "$d/lib/odd.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/index.cld 2>&1); rc=$?
expect_miss "a bad index.cld header is not SYM-HDR" "SYM-HDR" "$out"
expect_rc   "a bad index.cld header does not block symbol-audit (exit 0)" 0 "$rc"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_miss "sweep: a bad index.cld header is not SYM-HDR" "SYM-HDR  lib/index.cld" "$out"
expect_hit  "control: the sweep still blocks an unknown species elsewhere" "SYM-HDR  lib/odd.cld" "$out"
out=$(cd "$d" && $SH $SA lib/odd.cld 2>&1); rc=$?
expect_hit  "control: SYM-HDR still blocks lib/odd.cld" "SYM-HDR" "$out"
expect_rc   "control: lib/odd.cld blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# CLD_NOT_DIR_INDEX_RE files are another domain too: not ours.
d=$(fixture)
mkdir -p "$d/docs/sessions"
printf 'SESSION 2026-10-01\nnotes of a session\n' > "$d/docs/sessions/2026.cld"
stage "$d"
out=$(cd "$d" && $SH $SA docs/sessions/2026.cld 2>&1); rc=$?
expect_hit "control: an unexempted foreign species is SYM-HDR" "SYM-HDR" "$out"
printf 'CLD_NOT_DIR_INDEX_RE=%s\n' "'^docs/sessions/'" > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA docs/sessions/2026.cld 2>&1); rc=$?
expect_miss "a CLD_NOT_DIR_INDEX_RE file is not symbol-audit's" "SYM-HDR" "$out"
expect_rc   "a CLD_NOT_DIR_INDEX_RE file passes (exit 0)" 0 "$rc"
rm -rf "$d"

# The SYM-DUP map honours the same exemptions as the checked list: a
# borrowed FILE header (CLD_NOT_SYMBOL_INDEX_RE) or an index.cld cannot
# make an honest index a twin.
d=$(fixture)
mkdir -p "$d/lib" "$d/notes"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing   A class\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/thing.js\nC Thing   borrowed header, other domain\n' > "$d/notes/plan.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit "control: an unexempted claimant is SYM-DUP" "notes/plan.cld" "$out"
printf 'CLD_NOT_SYMBOL_INDEX_RE=%s\n' "'^notes/'" > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "the SYM-DUP map skips CLD_NOT_SYMBOL_INDEX_RE files" "SYM-DUP" "$out"
expect_rc   "an exempted claimant does not block (exit 0)" 0 "$rc"
printf 'FILE lib/thing.js\nC Thing   an index.cld with a FILE header\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "the SYM-DUP map skips index.cld" "SYM-DUP" "$out"
printf 'FILE lib/thing.js\nC Thing   a real twin\n' > "$d/lib/twin.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit  "control: a real twin is still SYM-DUP" "SYM-DUP  lib/thing.js.cld: target lib/thing.js also claimed by: lib/twin.js.cld" "$out"
expect_miss "control: and only the real twin is named" "notes/plan.cld" "$out"
rm -rf "$d"

section "identity: SYM-NAME directory, SYM-DUP spelling, CRLF"

# The index must sit BESIDE its target, not just share its name.
d=$(fixture)
mkdir -p "$d/lib" "$d/docs"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing   A class\n' > "$d/docs/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA docs/thing.js.cld 2>&1); rc=$?
expect_hit "SYM-NAME fires on an index in another directory" "SYM-NAME docs/thing.js.cld: expected lib/thing.js.cld" "$out"
expect_rc  "an index away from its target blocks (exit 1)" 1 "$rc"
git -C "$d" mv -f docs/thing.js.cld lib/thing.js.cld >/dev/null 2>&1
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit "control: the same index beside its target is clean" "symbol-audit: clean" "$out"
expect_rc  "control: beside its target exits 0" 0 "$rc"
printf 'FILE ./lib//thing.js\nC Thing   A class\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "a ./ or // spelling of the target is not SYM-NAME" "SYM-NAME" "$out"
expect_rc   "a ./ or // spelling of the target exits 0" 0 "$rc"
rm -rf "$d"

# SYM-DUP compares targets in one spelling.
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing   A class\n' > "$d/lib/thing.js.cld"
printf 'FILE ./lib//thing.js\nC Thing   The twin\n' > "$d/lib/twin.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit "SYM-DUP sees a ./ and // spelling of the same target" "SYM-DUP  lib/thing.js.cld: target lib/thing.js also claimed by: lib/twin.js.cld" "$out"
expect_rc  "a respelled twin blocks (exit 1)" 1 "$rc"
printf 'FILE lib/thing.js/\nC Thing   The twin\n' > "$d/lib/twin.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1)
expect_hit "SYM-DUP sees a trailing-/ spelling of the same target" "also claimed by: lib/twin.js.cld" "$out"
printf 'FILE lib/other.js\nC Thing   Not a twin\n' > "$d/lib/twin.js.cld"
echo 'class Thing {}' > "$d/lib/other.js"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "control: a different target is not a twin" "SYM-DUP" "$out"
rm -rf "$d"

# CR-LF: say so, and read the index with the CR removed instead of
# reporting a target named "lib/thing.js<CR>".
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\r\nC Thing   A class\r\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit  "SYM-CRLF names a CR-LF index" "SYM-CRLF (warn) lib/thing.js.cld" "$out"
expect_miss "a CR-LF index is not SYM-DEAD" "SYM-DEAD" "$out"
expect_miss "a CR-LF index is not SYM-NAME" "SYM-NAME" "$out"
expect_miss "a CR-LF index has no stale entries" "SYM-STALE" "$out"
expect_rc   "SYM-CRLF warns (exit 0)" 0 "$rc"
printf 'FILE lib/thing.js\r\nC Thing   A class\r\nF Thing.a   one\r\nF Thing.a   two\r\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/thing.js\r\nC Thing   The twin\r\n' > "$d/lib/twin.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit "a CR-LF index still gets SYM-KEY" "duplicate key Thing.a" "$out"
expect_hit "a CR-LF twin is still SYM-DUP" "also claimed by: lib/twin.js.cld" "$out"
printf 'FILE lib/gone.js\r\nC Gone   Not there\r\n' > "$d/lib/gone.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/gone.js.cld 2>&1); rc=$?
expect_hit "control: a CR-LF index with a missing target is SYM-DEAD" "SYM-DEAD lib/gone.js.cld: target does not exist: lib/gone.js" "$out"
expect_rc  "control: the CR-LF dead index blocks (exit 1)" 1 "$rc"
rm -rf "$d"

section "SYM-STALE: an entry the target no longer has"

d=$(fixture)
mkdir -p "$d/lib"
printf 'class Thing {\n  load() { return bxc; }\n}\n. ./lib/util.sh\n' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing          A class\nF Thing.load     Loads it\nF Thing.unload   Renamed away\nR (listener)     Placeholder\nI ./lib/util.sh  Sourced\nI ./lib/gone.sh  Not sourced any more\nK b*c            Fixed string, not a pattern\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit  "SYM-STALE names an entry the target lacks" "SYM-STALE (warn) lib/thing.js.cld line 4: unload (of Thing.unload)" "$out"
expect_miss "a qualified entry is matched on its last part" "line 3:" "$out"
expect_miss "an entry the target has is not stale" "SYM-STALE (warn) lib/thing.js.cld line 2" "$out"
expect_miss "an R placeholder is not looked for" "(listener)" "$out"
expect_miss "an I entry the target has is not stale" "line 6:" "$out"
expect_hit  "an I entry is matched as its whole token" "SYM-STALE (warn) lib/thing.js.cld line 7: ./lib/gone.sh does not occur" "$out"
expect_hit  "the match is a fixed string, not a pattern" "line 8: b*c does not occur" "$out"
expect_rc   "SYM-STALE warns (exit 0)" 0 "$rc"
rm -rf "$d"

section "languages: the accessor rule, the lang line, #!, extension, file(1)"

d=$(fixture)
mkdir -p "$d/lib"
printf 'def get():\n  pass\n' > "$d/lib/store.py"
printf 'FILE lib/store.py\nF get   Reads a value\n' > "$d/lib/store.py.cld"
echo 'class Thing { get() {} }' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nF get   leaked accessor\n' > "$d/lib/thing.js.cld"
printf '#!/usr/bin/env node\nfunction get() {}\n' > "$d/lib/tool"
printf 'FILE lib/tool\nF get   leaked accessor\n' > "$d/lib/tool.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/store.py.cld 2>&1); rc=$?
expect_miss "the accessor rule does not apply to py" "SYM-KEY" "$out"
expect_rc   "a py index with an entry named get passes (exit 0)" 0 "$rc"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_hit  "control: the accessor rule applies to js" "field 2 is the keyword get" "$out"
expect_rc   "control: a js bare get blocks (exit 1)" 1 "$rc"
out=$(cd "$d" && $SH $SA lib/tool.cld 2>&1); rc=$?
expect_hit  "#!/usr/bin/env node makes an extensionless target js" "field 2 is the keyword get" "$out"
# the lang line in the header block beats the extension
printf 'FILE lib/thing.js\nlang py\nF get   a py-style name\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/store.py\nlang js\nF get   now js\n' > "$d/lib/store.py.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "a lang py line turns the js rule off" "SYM-KEY" "$out"
out=$(cd "$d" && $SH $SA lib/store.py.cld 2>&1); rc=$?
expect_hit  "a lang js line turns the js rule on" "field 2 is the keyword get" "$out"
# ...but only in the header block, before the first entry
printf 'FILE lib/thing.js\nF get   leaked accessor\nlang py\n' > "$d/lib/thing.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/thing.js.cld 2>&1)
expect_hit  "a lang line after the first entry is ignored" "field 2 is the keyword get" "$out"
# CLD_LANG_EXT_MAP extends the extension step
# (content file(1) calls plain "ASCII text", so step 4 stays out of it)
echo 'get = 1' > "$d/lib/m.mjs"
printf 'FILE lib/m.mjs\nF get   leaked accessor\n' > "$d/lib/m.mjs.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/m.mjs.cld 2>&1)
expect_miss "control: an unmapped extension is not js" "SYM-KEY" "$out"
printf 'CLD_LANG_EXT_MAP="$CLD_LANG_EXT_MAP mjs:js"\n' > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA lib/m.mjs.cld 2>&1)
expect_hit  "CLD_LANG_EXT_MAP maps mjs to js" "field 2 is the keyword get" "$out"
rm -rf "$d"

# Detection order, seen through the lookup's --lang filter.
d=$(fixture)
mkdir -p "$d/bin" "$d/lib"
printf '#!/bin/bash\nrun() { :; }\n' > "$d/bin/deploy"
printf 'FILE bin/deploy\nF run   Deploys\n' > "$d/bin/deploy.cld"
printf '#!/bin/sh\nrun() { :; }\n' > "$d/bin/odd.js"
printf 'FILE bin/odd.js\nF run   A sh script with a js name\n' > "$d/bin/odd.js.cld"
printf '#! /usr/bin/env -S python3 -u\ndef run(): pass\n' > "$d/bin/pytool"
printf 'FILE bin/pytool\nF run   Runs\n' > "$d/bin/pytool.cld"
printf 'def run(): pass\n' > "$d/lib/plain.py"
printf 'FILE lib/plain.py\nF run   By extension\n' > "$d/lib/plain.py.cld"
printf 'run = 1\n' > "$d/lib/mystery"
printf 'FILE lib/mystery\nF run   Only file(1) can tell\n' > "$d/lib/mystery.cld"
printf 'run() { :; }\n' > "$d/lib/q.sh"
printf 'FILE lib/q.sh\nF run   sh by its extension\n' > "$d/lib/q.sh.cld"
stage "$d"
out=$(cd "$d" && $SH $LK find run --lang bash 2>&1)
expect_hit  "#!/bin/bash is bash" "in  bin/deploy  --" "$out"
expect_miss "bash: nothing else is bash" "bin/odd.js" "$out"
out=$(cd "$d" && $SH $LK find run --lang sh 2>&1)
expect_hit  "the #! line beats the extension" "in  bin/odd.js  --" "$out"
out=$(cd "$d" && $SH $LK find run --lang js 2>&1); rc=$?
expect_miss "control: the sh script named .js is not js" "bin/odd.js" "$out"
expect_hit  "--lang js with no js index says NOTFOUND" "NOTFOUND run (among js indexes)" "$out"
expect_rc   "NOTFOUND exits 1" 1 "$rc"
out=$(cd "$d" && $SH $LK find run --lang py 2>&1)
expect_hit  "#!/usr/bin/env -S python3 is py" "in  bin/pytool  --" "$out"
expect_hit  "the .py extension is py" "in  lib/plain.py  --" "$out"
# file(1), the last resort: a fake one that calls everything Python ...
fb=$(mktemp -d "$CLD_TEST_ROOT/bin.XXXXXX")
printf '#!/bin/sh\necho "Python script, ASCII text executable"\n' > "$fb/file"
chmod +x "$fb/file"
out=$(cd "$d" && PATH="$fb:$PATH" $SH $LK find run --lang py 2>&1)
expect_hit  "file(1) answers when nothing else does" "in  lib/mystery  --" "$out"
expect_miss "file(1) does not override the extension" "lib/q.sh" "$out"
expect_miss "file(1) does not override the #! line" "bin/deploy" "$out"
# ... and none at all: skipped silently.
nb=$(mktemp -d "$CLD_TEST_ROOT/bin.XXXXXX")
for c in sh dash bash git awk grep sed sort mktemp mv rm cat tr dirname cp find head; do
  p=$(command -v "$c" 2>/dev/null) && ln -s "$p" "$nb/$c"
done
out=$(cd "$d" && PATH="$nb" $SH $LK find run --lang py 2>&1); rc=$?
expect_miss "with no file(1), an undecidable target is no language" "lib/mystery" "$out"
expect_hit  "control: with no file(1), the rest still works" "in  bin/pytool  --" "$out"
expect_no_shell_error "with no file(1), no error" "$out"
expect_rc   "with no file(1), exit 0" 0 "$rc"
rm -rf "$d" "$fb" "$nb"

section "SYM-MISS per language (CLD_SYM_MISS_LANGS)"

d=$(fixture)
mkdir -p "$d/lib" "$d/bin"
echo 'function orphaned() {}' > "$d/lib/orphaned.js"
printf 'import os\n\nasync def fetch():\n  pass\n' > "$d/lib/fetch.py"
printf 'class Store:\n  def get(self):\n    pass\n' > "$d/lib/store.py"
printf 'print(1)\n' > "$d/lib/script.py"
printf 'function deploy {\n  :\n}\n' > "$d/lib/deploy.bash"
printf '#!/bin/bash\nbuild() {\n  :\n}\n' > "$d/lib/build.sh"
printf 'function only_bash {\n  :\n}\n' > "$d/lib/kw.sh"
printf 'tidy () {\n  :\n}\n' > "$d/lib/tidy.sh"
printf '#!/usr/bin/env bash\nrelease() { :; }\n' > "$d/bin/release"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_hit  "control: SYM-MISS warns on js by default" "SYM-MISS (warn) lib/orphaned.js" "$out"
expect_miss "by default no new SYM-MISS warnings (py)" "lib/fetch.py" "$out"
expect_miss "by default no new SYM-MISS warnings (bash)" "bin/release" "$out"
printf 'CLD_SYM_MISS_LANGS="js py sh bash"\n' > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_hit  "py: an async def declares" "SYM-MISS (warn) lib/fetch.py" "$out"
expect_hit  "py: a class declares" "SYM-MISS (warn) lib/store.py" "$out"
expect_miss "py: no declaration, no warning" "lib/script.py" "$out"
expect_hit  "bash: function name declares" "SYM-MISS (warn) lib/deploy.bash" "$out"
expect_hit  "bash: the #! line makes a .sh file bash" "SYM-MISS (warn) lib/build.sh" "$out"
expect_miss "sh: the function keyword is not sh" "lib/kw.sh" "$out"
expect_hit  "sh: name () declares" "SYM-MISS (warn) lib/tidy.sh" "$out"
expect_hit  "an extensionless script is found by its #! line" "SYM-MISS (warn) bin/release" "$out"
expect_hit  "control: js still warns" "SYM-MISS (warn) lib/orphaned.js" "$out"
expect_rc   "SYM-MISS still never blocks (exit 0)" 0 "$rc"
out=$(cd "$d" && $SH $SA lib/fetch.py lib/script.py 2>&1)
expect_hit  "named args: py is checked too" "SYM-MISS (warn) lib/fetch.py" "$out"
expect_miss "named args: an undeclaring py is quiet" "lib/script.py" "$out"
printf 'CLD_SYM_MISS_LANGS="js bash"\n' > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1)
expect_hit  "only the listed languages: bash" "SYM-MISS (warn) lib/build.sh" "$out"
expect_miss "only the listed languages: not sh" "lib/tidy.sh" "$out"
expect_miss "only the listed languages: not py" "lib/fetch.py" "$out"
printf 'CLD_SYM_MISS_LANGS="py"\n' > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA 2>&1)
expect_miss "js left out of the list: no js SYM-MISS" "lib/orphaned.js" "$out"
expect_hit  "control: py still listed" "SYM-MISS (warn) lib/fetch.py" "$out"
rm -rf "$d"

section "the I letter"

d=$(fixture)
mkdir -p "$d/lib"
printf 'import get from "get"\nimport util from "./util.js"\nfunction util2() {}\n' > "$d/lib/a.js"
printf 'FILE lib/a.js\nI get         An npm module named get\nI ./util.js   Helpers\nF util2       Uses util\n' > "$d/lib/a.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/a.js.cld 2>&1); rc=$?
expect_miss "an I entry named get is a module, not an accessor" "SYM-KEY" "$out"
expect_rc   "an index with I entries passes (exit 0)" 0 "$rc"
printf 'FILE lib/a.js\nI ./util.js   Helpers\nF ./util.js   a symbol key that looks the same\n' > "$d/lib/a.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/a.js.cld 2>&1)
expect_miss "an I token and a symbol key never clash" "duplicate key" "$out"
printf 'FILE lib/a.js\nI ./util.js   Helpers\nI ./util.js   Helpers again\n' > "$d/lib/a.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/a.js.cld 2>&1); rc=$?
expect_hit  "control: two I entries for one module are a duplicate" "duplicate key ./util.js" "$out"
expect_rc   "control: the duplicate I entry blocks (exit 1)" 1 "$rc"
rm -rf "$d"

section "--gone: deleted or renamed-away paths"

d=$(fixture)
mkdir -p "$d/lib"
echo 'function a() {}' > "$d/lib/a.js"
printf 'FILE lib/a.js\nF a   A function\nF a   duplicate, pre-existing\n' > "$d/lib/a.js.cld"
echo 'function b() {}' > "$d/lib/b.js"
printf 'FILE lib/b.js\nF b   B\n' > "$d/lib/b.js.cld"
printf 'FILE lib/z.js\nF z   someone else'"'"'s old dead index\n' > "$d/lib/z.js.cld"
printf 'INDEX lib/\nF a.js   A\n' > "$d/lib/index.cld"
stage "$d"
git -C "$d" commit -qm base >/dev/null 2>&1
git -C "$d" rm -q lib/a.js
out=$(cd "$d" && $SH $SA --gone lib/a.js 2>&1); rc=$?
expect_hit  "--gone: an index left beside a deleted source is SYM-DEAD" "SYM-DEAD lib/a.js.cld: target does not exist: lib/a.js" "$out"
expect_rc   "--gone: the leftover index blocks (exit 1)" 1 "$rc"
expect_miss "--gone is narrow: the leftover is not re-audited" "SYM-KEY" "$out"
expect_miss "--gone is narrow: --gone alone is not a sweep" "lib/z.js.cld" "$out"
out=$(cd "$d" && $SH $SA 2>&1)
expect_hit  "control: the sweep does see the other dead index" "SYM-DEAD lib/z.js.cld" "$out"
out=$(cd "$d/lib" && $SH ../$SA --gone a.js 2>&1)
expect_hit  "--gone paths are relative to where you stand" "SYM-DEAD lib/a.js.cld" "$out"
out=$(cd "$d" && $SH $SA lib/b.js.cld --gone lib/a.js 2>&1); rc=$?
expect_hit  "--gone with checked files: the gone path is asked about" "SYM-DEAD lib/a.js.cld" "$out"
expect_rc   "--gone with checked files blocks (exit 1)" 1 "$rc"
out=$(cd "$d" && $SH $SA lib/b.js.cld 2>&1); rc=$?
expect_hit  "control: the checked file alone is clean" "symbol-audit: clean" "$out"
out=$(cd "$d" && $SH $SA lib/a.js.cld --gone lib/a.js 2>&1)
n=$(printf '%s\n' "$out" | grep -c 'SYM-DEAD lib/a.js.cld')
expect_eq   "an index both named and --gone is reported once" "1" "$n"
out=$(cd "$d" && $SH $SA --gone lib/index 2>&1); rc=$?
expect_miss "--gone: <path>.cld that is an index.cld is not a symbol index" "SYM-DEAD" "$out"
expect_rc   "--gone lib/index exits 0" 0 "$rc"
out=$(cd "$d" && $SH $SA --gone lib/b.js 2>&1); rc=$?
expect_miss "--gone: a path still in the tree is not gone" "SYM-DEAD" "$out"
expect_rc   "--gone on a present path exits 0" 0 "$rc"
out=$(cd "$d" && $SH $SA --gone 2>&1); rc=$?
expect_hit  "--gone with no paths checks nothing" "symbol-audit: clean" "$out"
expect_miss "--gone with no paths is not a sweep" "lib/z.js.cld" "$out"
git -C "$d" rm -q lib/a.js.cld
out=$(cd "$d" && $SH $SA --gone lib/a.js lib/a.js.cld 2>&1); rc=$?
expect_hit  "--gone: source and index both removed is clean" "symbol-audit: clean" "$out"
expect_rc   "--gone: source and index both removed exits 0" 0 "$rc"
rm -rf "$d"

# the gate's way: the staged tree, materialised, with the real git dir
R=$(fixture)
R=$(cd "$R" && pwd -P)
mkdir -p "$R/lib"
echo 'function a() {}' > "$R/lib/a.js"
printf 'FILE lib/a.js\nF a   A function\n' > "$R/lib/a.js.cld"
stage "$R"
git -C "$R" commit -qm base >/dev/null 2>&1
git -C "$R" mv lib/a.js lib/renamed.js
t=$(mktemp -d "$CLD_TEST_ROOT/staged.XXXXXX")
t=$(cd "$t" && pwd -P)
git -C "$R" checkout-index -a --prefix="$t/"
out=$(cd "$t" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t" $SH $SA lib/renamed.js --gone lib/a.js 2>&1); rc=$?
expect_hit "staged tree: a rename that left its index behind is SYM-DEAD" "SYM-DEAD lib/a.js.cld" "$out"
expect_rc  "staged tree: the left-behind index blocks (exit 1)" 1 "$rc"
git -C "$R" mv lib/a.js.cld lib/renamed.js.cld
printf 'FILE lib/renamed.js\nF a   A function\n' > "$R/lib/renamed.js.cld"
git -C "$R" add lib/renamed.js.cld
rm -rf "$t"; t=$(mktemp -d "$CLD_TEST_ROOT/staged.XXXXXX"); t=$(cd "$t" && pwd -P)
git -C "$R" checkout-index -a --prefix="$t/"
out=$(cd "$t" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t" $SH $SA lib/renamed.js lib/renamed.js.cld --gone lib/a.js lib/a.js.cld 2>&1); rc=$?
expect_hit "staged tree: the index renamed with its source is clean" "symbol-audit: clean" "$out"
expect_rc  "staged tree: the honest rename exits 0" 0 "$rc"
rm -rf "$R" "$t"

section "errors propagate: a failed listing is not a clean tree"

d=$(fixture)
mkdir -p "$d/lib"
echo 'class Thing {}' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nC Thing   A class\n' > "$d/lib/thing.js.cld"
printf 'FILE lib/thing.js\nC Thing   The twin\n' > "$d/lib/twin.js.cld"
stage "$d"
fg=$(mktemp -d "$CLD_TEST_ROOT/bin.XXXXXX")
real_git=$(command -v git)
cat > "$fg/git" <<EOF
#!/bin/sh
case " \$* " in *" ls-files "*) echo "fake git: ls-files refused" >&2; exit 128 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$fg/git"
out=$(cd "$d" && $SH $SA lib/ 2>&1); rc=$?
expect_hit "control: lib/ has a SYM-DUP" "SYM-DUP" "$out"
out=$(cd "$d" && PATH="$fg:$PATH" $SH $SA lib/ 2>&1); rc=$?
expect_miss "a dir argument whose listing fails is not clean" "symbol-audit: clean" "$out"
expect_rc   "a dir argument whose listing fails exits 2" 2 "$rc"
out=$(cd "$d" && PATH="$fg:$PATH" $SH $SA lib/thing.js.cld 2>&1); rc=$?
expect_miss "a failed SYM-DUP listing is not clean" "symbol-audit: clean" "$out"
expect_rc   "a failed SYM-DUP listing exits 2" 2 "$rc"
out=$(cd "$d" && $SH $LK find Thing 2>&1); rc=$?
expect_hit  "control: the lookup finds Thing" "C Thing  in  lib/thing.js" "$out"
expect_rc   "control: the lookup exits 0" 0 "$rc"
out=$(cd "$d" && PATH="$fg:$PATH" $SH $LK find Thing 2>&1); rc=$?
expect_miss "a lookup whose listing fails finds nothing" "C Thing" "$out"
expect_rc   "a lookup whose listing fails exits 2" 2 "$rc"
rm -rf "$d" "$fg"

# A pattern in cld.conf that grep rejects is a setup error, not "no
# match": it must not quietly switch a check (or an exemption) off.
d=$(fixture)
mkdir -p "$d/lib"
echo 'class Orphaned {}' > "$d/lib/orphaned.js"
printf 'FILE lib/gone.js\nC Gone   Not there\n' > "$d/lib/gone.js.cld"
stage "$d"
out=$(cd "$d" && $SH $SA lib/orphaned.js lib/gone.js.cld 2>&1); rc=$?
expect_hit  "control: SYM-MISS and SYM-DEAD with a sane cld.conf" "SYM-MISS (warn) lib/orphaned.js" "$out"
expect_hit  "control: and SYM-DEAD" "SYM-DEAD lib/gone.js.cld" "$out"
printf 'CLD_DECL_RE=%s\n' "'('" > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA lib/orphaned.js 2>&1); rc=$?
expect_miss "a CLD_DECL_RE grep rejects is not clean" "symbol-audit: clean" "$out"
expect_rc   "a CLD_DECL_RE grep rejects exits 2" 2 "$rc"
printf 'CLD_NOT_SYMBOL_INDEX_RE=%s\n' "'\\('" > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $SA lib/gone.js.cld 2>&1); rc=$?
expect_miss "a CLD_NOT_SYMBOL_INDEX_RE grep rejects is not clean" "symbol-audit: clean" "$out"
expect_rc   "a CLD_NOT_SYMBOL_INDEX_RE grep rejects exits 2" 2 "$rc"
out=$(cd "$d" && $SH $LK find Gone 2>&1); rc=$?
expect_rc   "the lookup on that cld.conf exits 2 too" 2 "$rc"
rm -rf "$d"

section "symbol-lookup: find and dupecheck"

d=$(fixture)
mkdir -p "$d/lib" "$d/my dir" "$d/notes" "$d/docs"
printf 'class Thing {\n  load() {}\n  #aColors = []\n}\n' > "$d/lib/thing.js"
printf 'FILE lib/thing.js\nlang notes: load is mentioned here in prose\nC Thing          A class; load is in this description\nF Thing.load     Loads it\nD Thing.#aColors  Colour table\nK a.b            A dotted key\nI load           A module named load\n' > "$d/lib/thing.js.cld"
printf 'def load(): pass\n' > "$d/my dir/a b.py"
printf 'FILE my dir/a b.py\r\nF load   Loads, in py\r\n' > "$d/my dir/a b.py.cld"
printf 'FILE lib/thing.js\nF load   an index.cld with a FILE header\n' > "$d/lib/index.cld"
printf 'FILE lib/thing.js\nF load   borrowed header\n' > "$d/notes/plan.cld"
printf 'FILE lib/thing.js\nF load   matched by CLD_NOT_DIR_INDEX_RE\n' > "$d/docs/sessions.cld"
printf 'CLD_NOT_SYMBOL_INDEX_RE=%s\nCLD_NOT_DIR_INDEX_RE=%s\n' "'^notes/'" "'^docs/'" > "$d/cld.conf"
stage "$d"
out=$(cd "$d" && $SH $LK find load 2>&1); rc=$?
expect_hit  "find: a qualified entry answers for its last part" "F Thing.load  in  lib/thing.js  --  Loads it" "$out"
expect_hit  "find: a path with spaces and CR-LF lines" "F load  in  my dir/a b.py  --  Loads, in py" "$out"
expect_miss "find: a mention in a description is not a hit" "C Thing" "$out"
expect_miss "find: a prose line is not a hit" "lang notes" "$out"
expect_miss "find: an I entry is not a definition" "I load" "$out"
expect_miss "find: index.cld is never a symbol index" "an index.cld with a FILE header" "$out"
expect_miss "find: CLD_NOT_SYMBOL_INDEX_RE is honoured" "borrowed header" "$out"
expect_miss "find: CLD_NOT_DIR_INDEX_RE is honoured" "CLD_NOT_DIR_INDEX_RE" "$out"
expect_rc   "find: a hit exits 0" 0 "$rc"
n=$(printf '%s\n' "$out" | grep -c .)
expect_eq   "find: exactly the two definitions" "2" "$n"
out=$(cd "$d/my dir" && $SH ../$LK find '#aColors' 2>&1)
expect_hit  "find: from a subdirectory, the whole repo; # in a name" "D Thing.#aColors  in  lib/thing.js" "$out"
out=$(cd "$d" && $SH $LK find axb 2>&1); rc=$?
expect_hit  "find: a.b is not a pattern that matches axb" "NOTFOUND axb" "$out"
expect_rc   "find: NOTFOUND exits 1" 1 "$rc"
out=$(cd "$d" && $SH $LK find a.b 2>&1)
expect_hit  "control: find a.b finds a.b" "K a.b  in  lib/thing.js" "$out"
out=$(cd "$d" && $SH $LK find 'Thing.load' --lang py 2>&1)
expect_hit  "find --lang: another language's index does not answer" "NOTFOUND Thing.load (among py indexes)" "$out"
out=$(cd "$d" && $SH $LK find --lang=js Thing.load 2>&1)
expect_hit  "find --lang=js before the name" "F Thing.load  in  lib/thing.js" "$out"
out=$(cd "$d" && $SH $LK dupecheck load 2>&1); rc=$?
expect_hit  "dupecheck: a defined name is TAKEN" "TAKEN load" "$out"
expect_hit  "dupecheck: and shows where" "in  lib/thing.js  --  Loads it" "$out"
expect_rc   "dupecheck: TAKEN exits 1" 1 "$rc"
out=$(cd "$d" && $SH $LK dupecheck load --lang py 2>&1)
expect_hit  "dupecheck --lang py: only the py definition" "F load  in  my dir/a b.py" "$out"
expect_miss "dupecheck --lang py: not the js one" "lib/thing.js" "$out"
out=$(cd "$d" && $SH $LK dupecheck unload 2>&1); rc=$?
expect_hit  "dupecheck: an unused name is FREE" "FREE unload" "$out"
expect_rc   "dupecheck: FREE exits 0" 0 "$rc"
out=$(cd "$d" && $SH $LK dupecheck oad 2>&1)
expect_hit  "dupecheck: a name is not a substring match" "FREE oad" "$out"
out=$(cd "$d" && $SH $LK 2>&1); rc=$?
expect_hit  "no arguments: usage" "usage: lookup.sh" "$out"
expect_rc   "no arguments: exit 2" 2 "$rc"
out=$(cd "$d" && $SH $LK find 2>&1); rc=$?
expect_rc   "find with no name: exit 2" 2 "$rc"
out=$(cd "$d" && $SH $LK frobnicate x 2>&1); rc=$?
expect_rc   "an unknown subcommand: exit 2" 2 "$rc"
rm -rf "$d"

section "symbol-lookup: deps and rdeps"

d=$(fixture)
mkdir -p "$d/scripts/lib" "$d/app" "$d/py"
printf '. "$HERE/../lib/util.sh"\n. ./lib/log.sh\nmain() { :; }\n' > "$d/scripts/run.sh"
printf 'FILE scripts/run.sh\nI $HERE/../lib/util.sh   die, warn\nI ./lib/log.sh   log\nF main   Entry point\n' > "$d/scripts/run.sh.cld"
printf 'import x from "../../icc-lib/scripts/lib"\n' > "$d/app/x.js"
printf 'FILE app/x.js\nI ../../icc-lib/scripts/lib   the shared lib\n' > "$d/app/x.js.cld"
printf 'import os.path\n' > "$d/py/p y.py"
printf 'FILE py/p y.py\r\nI os.path   join\r\n' > "$d/py/p y.py.cld"
printf 'x=1\n' > "$d/scripts/lib/util.sh"
printf 'FILE scripts/lib/util.sh\nK x   no deps here\n' > "$d/scripts/lib/util.sh.cld"
stage "$d"
out=$(cd "$d" && $SH $LK deps scripts/run.sh 2>&1); rc=$?
expect_hit  "deps: the I entries of FILE's index" "I \$HERE/../lib/util.sh  --  die, warn" "$out"
expect_hit  "deps: every one" "I ./lib/log.sh  --  log" "$out"
expect_miss "deps: not the other entries" "main" "$out"
expect_rc   "deps: exit 0" 0 "$rc"
out=$(cd "$d/scripts" && $SH ../$LK deps run.sh 2>&1)
expect_hit  "deps: FILE is relative to where you stand" "I ./lib/log.sh" "$out"
out=$(cd "$d" && $SH $LK deps "py/p y.py" 2>&1)
expect_hit  "deps: a path with spaces, CR-LF index" "I os.path  --  join" "$out"
out=$(cd "$d" && $SH $LK deps scripts/lib/util.sh 2>&1); rc=$?
expect_hit  "deps: an index with no I entries says NONE" "NONE scripts/lib/util.sh" "$out"
out=$(cd "$d" && $SH $LK deps app/none.js 2>&1); rc=$?
expect_hit  "deps: a file with no index says NOINDEX" "NOINDEX app/none.js" "$out"
expect_rc   "deps: NOINDEX exits 1" 1 "$rc"
out=$(cd "$d" && $SH $LK rdeps scripts/lib/util.sh 2>&1); rc=$?
expect_hit  "rdeps: a \$VAR/../ token answers for the repo path" "scripts/run.sh  I \$HERE/../lib/util.sh  --  die, warn" "$out"
expect_rc   "rdeps: exit 0" 0 "$rc"
out=$(cd "$d" && $SH $LK rdeps util.sh 2>&1)
expect_hit  "rdeps: a bare file name answers as a suffix" "scripts/run.sh  I \$HERE/../lib/util.sh" "$out"
expect_miss "rdeps: util.sh is not log.sh" "log.sh" "$out"
out=$(cd "$d" && $SH $LK rdeps scripts/lib 2>&1)
expect_hit  "rdeps: TARGET a suffix of the token" "app/x.js  I ../../icc-lib/scripts/lib  --  the shared lib" "$out"
out=$(cd "$d" && $SH $LK rdeps ../../icc-lib/scripts/lib 2>&1)
expect_hit  "rdeps: the token exactly as written" "app/x.js  I ../../icc-lib/scripts/lib" "$out"
out=$(cd "$d" && $SH $LK rdeps os.path 2>&1)
expect_hit  "rdeps: a module name, path with spaces" "py/p y.py  I os.path  --  join" "$out"
out=$(cd "$d" && $SH $LK rdeps cripts/lib 2>&1); rc=$?
expect_hit  "rdeps: a suffix only counts on a / boundary" "NONE cripts/lib" "$out"
expect_rc   "rdeps: NONE exits 1" 1 "$rc"
out=$(cd "$d" && $SH $LK rdeps os 2>&1)
expect_hit  "rdeps: os is not os.path" "NONE os" "$out"
rm -rf "$d"

section "the symbol-* skills"

SK="$TOOLKIT/.claude/skills"
for gone in filename-find filename-dupecheck; do
  if [ -e "$SK/$gone" ]; then bad "$gone is gone" "still at $SK/$gone"; else ok "$gone is gone"; fi
done
d=$(fixture)
mkdir -p "$d/lib"
for l in js py sh bash; do
  case "$l" in
    js)   printf 'function ping() {}\n' > "$d/lib/p.js" ;;
    py)   printf 'def ping(): pass\n' > "$d/lib/p.py" ;;
    sh)   printf 'ping() { :; }\n' > "$d/lib/p.sh" ;;
    bash) printf 'function ping { :; }\n' > "$d/lib/p.bash" ;;
  esac
  printf 'FILE lib/p.%s\nF ping   Pings, in %s\n' "$l" "$l" > "$d/lib/p.$l.cld"
done
printf '. ./p.sh\n' >> "$d/lib/p.bash"
printf 'I ./p.sh   ping\n' >> "$d/lib/p.bash.cld"
stage "$d"
for s in symbol-find-js symbol-find-py symbol-find-sh symbol-find-bash \
         symbol-dupecheck-js symbol-dupecheck-py symbol-dupecheck-sh symbol-dupecheck-bash \
         symbol-deps; do
  f="$SK/$s/SKILL.md"
  if [ ! -f "$f" ]; then bad "skill $s exists" "no $f"; continue; fi
  expect_eq "skill $s: frontmatter name" "name: $s" "$(sed -n 2p "$f")"
  expect_hit "skill $s: has a description" "description: " "$(sed -n 3p "$f")"
  expect_hit "skill $s: listed in .claude/skills/index.cld" "D $s/" "$(cat "$SK/index.cld")"
  case "$s" in
    symbol-deps)
      line=$(grep 'lookup.sh deps' "$f" | head -n 1)
      out=$(cd "$d" && eval "$(echo "$line" | sed 's/^ *//; s,"FILE",lib/p.bash,')" 2>&1)
      expect_hit "skill $s: its deps command runs" "I ./p.sh  --  ping" "$out"
      line=$(grep 'lookup.sh rdeps' "$f" | head -n 1)
      out=$(cd "$d" && eval "$(echo "$line" | sed 's/^ *//; s,"TARGET",lib/p.sh,')" 2>&1)
      expect_hit "skill $s: its rdeps command runs" "lib/p.bash  I ./p.sh" "$out" ;;
    *)
      l=${s##*-}
      line=$(grep 'lookup.sh' "$f" | head -n 1)
      expect_hit "skill $s: calls the shared script for $l" "--lang $l" "$line"
      out=$(cd "$d" && ARGUMENTS=ping && eval "$line" 2>&1)
      case "$s" in
        symbol-find-*)      expect_hit "skill $s: finds the $l definition only" "F ping  in  lib/p.$l  --  Pings, in $l" "$out" ;;
        symbol-dupecheck-*) expect_hit "skill $s: TAKEN in $l" "TAKEN ping (among $l indexes)" "$out" ;;
      esac
      n=$(printf '%s\n' "$out" | grep -c ' in  lib/p\.')
      expect_eq "skill $s: and no other language" "1" "$n" ;;
  esac
done
rm -rf "$d"

finish
