#!/bin/sh
# tests/cases/30-gate.sh
# @brief Commit-gate cases: install the hooks into throwaway fixture
# repos and make REAL commits, so the installer, the dispatcher, both
# drop-in gates and both checkers are exercised the way a host repo runs
# them.
#
# Routing is tested twice. First with STUB checkers that only record how
# they were called (their arguments, where they ran, what their git
# sees), so the dispatcher's half of the --gone contract is pinned down
# independently of the checkers' half; then the same kinds of commit go
# through the REAL checkers, so the two halves are tested together.
# Everything else runs the real checkers.
#
# Run alone (sh tests/cases/30-gate.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

# --- helpers for this file -------------------------------------------------

# stub_checkers <repo> <log> -- replace both checkers with stubs that log
# every call to <log>: "CALL <name>", where they ran (TOP, PWD), how many
# files their git sees in the index (LS), then one "ARG <arg>" per
# argument. A stub exits with the number in <log>.rc if that file exists.
stub_checkers() {
  for _w in index-audit symbol-audit; do
    cat > "$1/scripts/$_w/check.sh" <<EOF
#!/bin/sh
{
  printf 'CALL %s\n' '$_w'
  printf 'TOP %s\n' "\$(git rev-parse --show-toplevel 2>&1)"
  printf 'PWD %s\n' "\$(pwd -P)"
  printf 'LS %s\n' "\$(git ls-files 2>/dev/null | wc -l | tr -d ' ')"
  for a in "\$@"; do printf 'ARG %s\n' "\$a"; done
} >> '$2'
if [ -f '$2.rc' ]; then exit "\$(cat '$2.rc')"; fi
exit 0
EOF
    chmod +x "$1/scripts/$_w/check.sh"
  done
}

# args_of <log> <checker> -- every argument that checker was given, in
# order, each followed by "|" (all calls run together).
args_of() {
  awk -v w="$2" '
    /^CALL / { on = ($2 == w); next }
    on && /^ARG / { sub(/^ARG /, ""); printf "%s|", $0 }
  ' "$1"
}

# field_of <log> <checker> <TOP|PWD|LS> -- that field of the first call.
field_of() {
  awk -v w="$2" -v k="$3" '
    /^CALL / { on = ($2 == w); next }
    on && $1 == k { sub(/^[A-Z]+ /, ""); print; exit }
  ' "$1"
}

# calls_of <log> <checker> -- how many times it was called.
calls_of() {
  grep -c "^CALL $2\$" "$1" 2>/dev/null || :
}

# stub_repo -- a fixture with stub checkers and the hooks installed, and a
# base commit of a small lib/ tree. The log is "<repo>.log", emptied.
stub_repo() {
  _r=$(fixture)
  stub_checkers "$_r" "$_r.log"
  $SH "$_r/scripts/git-hooks/install.sh" >/dev/null 2>&1
  mkdir -p "$_r/lib/sub/deeper"
  printf 'INDEX lib/\nF a.js    A\nF c.js    C\nF xa.js   XA\nF thing   Thing\nD sub/    Sub\n' > "$_r/lib/index.cld"
  for _f in a c xa; do echo "// $_f" > "$_r/lib/$_f.js"; done
  echo thing > "$_r/lib/thing"
  printf 'INDEX lib/sub/\nF x.js     X\nD deeper/  Deeper\n' > "$_r/lib/sub/index.cld"
  echo '// x' > "$_r/lib/sub/x.js"
  echo '// y' > "$_r/lib/sub/deeper/y.js"
  stage "$_r"
  git -C "$_r" commit -qm base >/dev/null 2>&1
  : > "$_r.log"
  printf '%s' "$_r"
}

# try_commit <repo> <message> -- commit what is staged; sets out and rc.
try_commit() {
  out=$(cd "$1" && git commit -m "$2" 2>&1)
  rc=$?
}

# commits <repo> -- how many commits HEAD has.
commits() { git -C "$1" rev-list --count HEAD 2>/dev/null; }

# lib_repo -- a fixture with the REAL checkers, the hooks installed, and an
# honest base commit: lib/index.cld lists known.js, lib/known.js has a
# symbol index.
lib_repo() {
  _r=$(fixture)
  $SH "$_r/scripts/git-hooks/install.sh" >/dev/null 2>&1
  mkdir -p "$_r/lib"
  printf 'INDEX lib/\nF known.js    Indexed\n' > "$_r/lib/index.cld"
  echo 'function known() {}' > "$_r/lib/known.js"
  printf 'FILE lib/known.js\nF known      A function\n' > "$_r/lib/known.js.cld"
  stage "$_r"
  git -C "$_r" commit -qm base >/dev/null 2>&1
  printf '%s' "$_r"
}

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

section "routing: what each check is handed (stub checkers)"

# A rename is a deletion plus an addition: the new path is present, the
# old one is passed after --gone.
d=$(stub_repo)
git -C "$d" mv lib/a.js lib/b.js
try_commit "$d" "rename"
expect_rc "control: a commit through stub checkers lands" 0 "$rc"
expect_eq "rename: index-audit gets the new path and --gone the old" \
  "lib/b.js|--gone|lib/a.js|" "$(args_of "$d.log" index-audit)"
expect_eq "rename: symbol-audit gets the same routing" \
  "lib/b.js|--gone|lib/a.js|" "$(args_of "$d.log" symbol-audit)"
top=$(field_of "$d.log" index-audit TOP)
expect_eq "the check runs at the root of the tree it checks" "$top" "$(field_of "$d.log" index-audit PWD)"
case "$top" in
  "$d"|"$d"/*|'') bad "the check runs in a temp tree, not the working tree" "TOP was [$top]" ;;
  *) ok "the check runs in a temp tree, not the working tree" ;;
esac
if [ -n "$top" ] && [ ! -e "$top" ]; then ok "the temp tree is removed afterwards"
else bad "the temp tree is removed afterwards" "[$top] still exists"; fi
expect_eq "the check's git sees the staged index" \
  "$(git -C "$d" ls-files | wc -l | tr -d ' ')" "$(field_of "$d.log" index-audit LS)"

# A plain deletion: only the deleted path, after --gone. The index.cld
# beside it is NOT dragged in -- that would re-audit a whole index
# because of a deletion.
: > "$d.log"
git -C "$d" rm -q lib/c.js
try_commit "$d" "delete"
expect_eq "deletion: only --gone and the deleted path" \
  "--gone|lib/c.js|" "$(args_of "$d.log" index-audit)"
expect_eq "deletion: symbol-audit is handed the same" \
  "--gone|lib/c.js|" "$(args_of "$d.log" symbol-audit)"

# A deleted directory: every file, plus every directory that is gone
# with them (so the parent's "D sub/" entry can be found), and no more.
: > "$d.log"
git -C "$d" rm -rq lib/sub
try_commit "$d" "delete a dir"
expect_eq "deleted dir: the files and the gone directories" \
  "--gone|lib/sub|lib/sub/deeper|lib/sub/deeper/y.js|lib/sub/index.cld|lib/sub/x.js|" \
  "$(args_of "$d.log" index-audit)"

# A file replaced by a directory of the same name is not gone.
: > "$d.log"
git -C "$d" rm -q lib/thing
mkdir "$d/lib/thing"
echo '// z' > "$d/lib/thing/z.js"
stage "$d"
try_commit "$d" "file becomes dir"
expect_eq "a path that exists again is not passed as gone" \
  "lib/thing/z.js|" "$(args_of "$d.log" index-audit)"

# Names: spaces, non-ASCII, quote, backslash, glob characters, a leading
# dash -- each passed exactly once, exactly as named.
: > "$d.log"
echo 1 > "$d/lib/a b.js"
echo 2 > "$d/lib/ünï.js"
echo 3 > "$d/lib/q\"uote.js"
echo 4 > "$d/lib/back\\slash.js"
echo 5 > "$d/lib/x*.js"
echo 6 > "$d/-dash.js"
echo 7 > "$d/--gone"
stage "$d"
try_commit "$d" "odd names"
expect_eq "odd names reach the checks exactly as named" \
  './--gone|./-dash.js|lib/a b.js|lib/back\slash.js|lib/q"uote.js|lib/x*.js|lib/ünï.js|' \
  "$(args_of "$d.log" index-audit)"

# Symlinks that dangle or point at a directory are entries too.
: > "$d.log"
ln -s nowhere "$d/lib/dangle.json"
mkdir "$d/lib/sub2"
echo '// w' > "$d/lib/sub2/w.js"
ln -s sub2 "$d/lib/dirlink"
stage "$d"
try_commit "$d" "symlinks"
expect_eq "dangling and directory symlinks reach the checks" \
  "lib/dangle.json|lib/dirlink|lib/sub2/w.js|" "$(args_of "$d.log" index-audit)"

# A commit run from a subdirectory: git hands the hook a RELATIVE
# GIT_INDEX_FILE, which must still mean this repo's index inside the
# temp tree.
: > "$d.log"
echo '// e' > "$d/lib/e.js"
git -C "$d" add lib/e.js
out=$(cd "$d/lib" && git commit -m "from a subdir" 2>&1); rc=$?
expect_rc "control: the commit from a subdirectory lands" 0 "$rc"
expect_eq "from a subdirectory: the check's git still sees the staged index" \
  "$(git -C "$d" ls-files | wc -l | tr -d ' ')" "$(field_of "$d.log" index-audit LS)"

# A check that exits 2 ("could not check") blocks like a finding.
: > "$d.log"
echo 2 > "$d.log.rc"
echo '// f' > "$d/lib/f.js"
git -C "$d" add lib/f.js
n=$(commits "$d")
try_commit "$d" "checker cannot check"
expect_rc  "a check that could not check blocks" 1 "$rc"
expect_hit "...and says so" "could not check" "$out"
expect_eq  "...and nothing landed" "$n" "$(commits "$d")"
rm -f "$d.log.rc"

# A path with a newline in it cannot be handed on safely: refuse loudly.
git -C "$d" reset -q
rm -f "$d/lib/f.js"
printf 'x\n' > "$d/lib/new
line.js"
stage "$d"
n=$(commits "$d")
try_commit "$d" "newline"
expect_rc  "a staged name holding a newline blocks" 1 "$rc"
expect_hit "...and says why" "newline" "$out"
expect_eq  "...and nothing landed" "$n" "$(commits "$d")"
rm -rf "$d" "$d.log"

# A huge commit is split into calls that each fit in ARG_MAX.
d=$(stub_repo)
long=$(printf '%0200d' 0)
mkdir "$d/big"
i=0
while [ "$i" -lt 11000 ]; do
  : > "$d/big/$long-$i.txt"
  i=$((i + 1))
done
stage "$d"
try_commit "$d" "huge"
expect_rc "a commit too big for one argument list still goes through" 0 "$rc"
expect_eq "...every path reaches the check exactly once" "11000" \
  "$(args_of "$d.log" index-audit | tr '|' '\n' | grep -c "^big/$long-[0-9]*\.txt\$")"
n=$(calls_of "$d.log" index-audit)
if [ "${n:-0}" -ge 2 ]; then ok "...in more than one call"; else bad "...in more than one call" "calls: $n"; fi
rm -rf "$d" "$d.log"

section "the gate judges the STAGED content"

# Staged index names a ghost; the working copy was put back honest.
d=$(lib_repo)
printf 'INDEX lib/\nF known.js    Indexed\nF ghost.js    Staged, never written\n' > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
git -C "$d" show HEAD:lib/index.cld > "$d/lib/index.cld"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: the working copy alone is clean" "index-audit: clean" "$out"
try_commit "$d" "ghost staged"
expect_rc  "a staged ORPHAN blocks though the working copy is honest" 1 "$rc"
expect_hit "...and names it" "ghost.js" "$out"
git -C "$d" reset -q

# Staged content honest; an unstaged deletion in the working tree.
echo '// fresh' > "$d/lib/fresh.js"
printf 'INDEX lib/\nF known.js    Indexed\nF fresh.js    Fresh\n' > "$d/lib/index.cld"
git -C "$d" add lib/fresh.js lib/index.cld
rm "$d/lib/fresh.js"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: the working tree alone has an ORPHAN" "ORPHAN" "$out"
try_commit "$d" "honest staged, dirty tree"
expect_rc "an honest staged commit lands despite an unstaged deletion" 0 "$rc"

# An untracked file must not stand in for a staged entry.
git -C "$d" checkout -q -- lib/fresh.js
printf 'INDEX lib/\nF known.js    Indexed\nF fresh.js    Fresh\nF loose.js    Untracked\n' > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
echo '// loose' > "$d/lib/loose.js"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: in the working tree the untracked file answers for the entry" "index-audit: clean" "$out"
try_commit "$d" "untracked stand-in"
expect_rc  "an entry naming an untracked file blocks" 1 "$rc"
expect_hit "...as an ORPHAN for that file" "entry 'loose.js' names a missing target" "$out"
rm -f "$d/lib/loose.js"
git -C "$d" checkout -q HEAD -- lib/index.cld
git -C "$d" checkout -q HEAD -- lib/fresh.js 2>/dev/null || :

# A partial commit (git commit <paths>) leaves the staged index.cld out.
echo '// part' > "$d/lib/part.js"
printf 'INDEX lib/\nF known.js    Indexed\nF fresh.js    Fresh\nF part.js     Part\n' > "$d/lib/index.cld"
git -C "$d" add lib/part.js lib/index.cld
out=$(cd "$d" && git commit -m "partial" -- lib/part.js 2>&1); rc=$?
expect_rc  "a partial commit that leaves the index entry out blocks" 1 "$rc"
expect_hit "...with NOENTRY for the file it does commit" "NOENTRY" "$out"
try_commit "$d" "whole"
expect_rc  "control: the whole staged set commits" 0 "$rc"
rm -rf "$d"

section "a check that cannot run blocks"

d=$(stub_repo)
echo '// g' > "$d/lib/g.js"
git -C "$d" rm -q scripts/index-audit/check.sh
git -C "$d" add lib/g.js
try_commit "$d" "checker removed"
expect_rc  "a commit that removes a checker blocks" 1 "$rc"
expect_hit "...loudly" "scripts/index-audit/check.sh is missing" "$out"
expect_eq  "...and the other check still ran" "1" "$(calls_of "$d.log" symbol-audit)"
git -C "$d" reset -q
git -C "$d" checkout -q -- scripts/index-audit/check.sh

: > "$d.log"
chmod -x "$d/scripts/symbol-audit/check.sh"
git -C "$d" add scripts/symbol-audit/check.sh lib/g.js
try_commit "$d" "checker not executable"
expect_rc  "a non-executable checker blocks" 1 "$rc"
expect_hit "...loudly" "scripts/symbol-audit/check.sh is not executable" "$out"
chmod +x "$d/scripts/symbol-audit/check.sh"
git -C "$d" add scripts/symbol-audit/check.sh

: > "$d.log"
chmod -x "$d/scripts/git-hooks/pre-commit.d/20-index-audit"
git -C "$d" add scripts/git-hooks/pre-commit.d/20-index-audit
try_commit "$d" "check not executable"
expect_rc  "a non-executable check in pre-commit.d blocks" 1 "$rc"
expect_hit "...loudly" "20-index-audit is not executable" "$out"
expect_eq  "...and the other check still ran" "1" "$(calls_of "$d.log" symbol-audit)"
chmod +x "$d/scripts/git-hooks/pre-commit.d/20-index-audit"
git -C "$d" add scripts/git-hooks/pre-commit.d/20-index-audit

# The checker that runs is the staged one: deleting it from the working
# tree only changes nothing.
: > "$d.log"
rm "$d/scripts/index-audit/check.sh"
try_commit "$d" "checker gone from the working tree only"
expect_rc "a checker missing only from the working tree does not matter" 0 "$rc"
expect_eq "...the staged checker ran" "1" "$(calls_of "$d.log" index-audit)"
git -C "$d" checkout -q -- scripts/index-audit/check.sh

# A pre-commit.d with no checks in it is not a gate.
git -C "$d" rm -q scripts/git-hooks/pre-commit.d/20-index-audit scripts/git-hooks/pre-commit.d/30-symbol-audit
try_commit "$d" "no checks"
expect_rc  "a pre-commit.d emptied of checks blocks" 1 "$rc"
expect_hit "...loudly" "holds no checks" "$out"
git -C "$d" reset -q
git -C "$d" checkout -q -- scripts/git-hooks/pre-commit.d

# A commit cannot remove the gate it is judged by.
git -C "$d" rm -rq scripts/git-hooks/pre-commit.d
try_commit "$d" "remove the gate"
expect_rc  "a commit removing pre-commit.d blocks" 1 "$rc"
expect_hit "...loudly" "removes scripts/git-hooks/pre-commit.d" "$out"
git -C "$d" reset -q
git -C "$d" checkout -q -- scripts/git-hooks/pre-commit.d
rm -rf "$d" "$d.log"

# A repo that never carried the toolkit (a shared core.hooksPath, an old
# branch): no checks run, and it says so; a chained hook still runs.
d=$(mktemp -d "$CLD_TEST_ROOT/plain.XXXXXX")
git -C "$d" init -q
git -C "$d" config user.email t@example.com
git -C "$d" config user.name Test
git -C "$d" config commit.gpgsign false
hd=$(cd "$d" && git rev-parse --git-path hooks)
case $hd in /*) : ;; *) hd=$d/$hd ;; esac
mkdir -p "$hd"
cp "$TOOLKIT/scripts/git-hooks/pre-commit" "$hd/pre-commit"
chmod +x "$hd/pre-commit"
echo hi > "$d/readme.txt"
stage "$d"
try_commit "$d" "no toolkit here"
expect_rc  "a tree that never had the toolkit commits" 0 "$rc"
expect_hit "...and the hook says no checks ran" "no .cld checks run" "$out"
printf '#!/bin/sh\necho "foreign says no"\nexit 1\n' > "$hd/pre-commit.cld-chained"
chmod +x "$hd/pre-commit.cld-chained"
echo again >> "$d/readme.txt"
stage "$d"
try_commit "$d" "chained fails"
expect_rc  "control: the hook is live there -- a failing chained hook blocks" 1 "$rc"
rm -rf "$d"

section "installer"

# A foreign pre-commit is chained, keeps running, and the gate still bites.
d=$(lib_repo)
hd=$d/.git/hooks
rm -f "$hd/pre-commit"
printf '#!/bin/sh\necho foreign >> "%s"\nexit 0\n' "$d.flog" > "$hd/pre-commit"
chmod +x "$hd/pre-commit"
cp "$hd/pre-commit" "$d.foreign"
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc  "install over a foreign hook succeeds" 0 "$rc"
expect_hit "...and says it chained it" "Chained" "$out"
if cmp -s "$d.foreign" "$hd/pre-commit.cld-chained"; then ok "the foreign hook is kept, byte for byte, as pre-commit.cld-chained"
else bad "the foreign hook is kept, byte for byte, as pre-commit.cld-chained" "missing or changed"; fi
expect_hit "the dispatcher is now the pre-commit hook" "marker: cld-dispatcher" "$(cat "$hd/pre-commit" 2>&1)"
echo '// one' > "$d/lib/one.js"
printf 'INDEX lib/\nF known.js    Indexed\nF one.js      One\n' > "$d/lib/index.cld"
stage "$d"
try_commit "$d" "clean"
expect_rc "a clean commit lands with a chained hook" 0 "$rc"
expect_eq "the chained foreign hook ran" "foreign" "$(cat "$d.flog" 2>/dev/null)"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
try_commit "$d" "stray"
expect_hit "the .cld gate still blocks behind a chained hook" "NOENTRY" "$out"
expect_rc  "...exit non-zero" 1 "$rc"
expect_eq  "the chained hook ran again" "2" "$(grep -c foreign "$d.flog" 2>/dev/null)"

# A re-run changes nothing it should not.
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc   "a re-run succeeds" 0 "$rc"
expect_miss "a re-run chains nothing new" "Chained" "$out"
if cmp -s "$d.foreign" "$hd/pre-commit.cld-chained"; then ok "a re-run leaves the chained hook as it was"
else bad "a re-run leaves the chained hook as it was" "changed"; fi

# Another tool replaced the dispatcher: two foreign hooks, so refuse and
# touch neither.
printf '#!/bin/sh\necho second\n' > "$hd/pre-commit"
cp "$hd/pre-commit" "$d.second"
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc  "a second foreign hook over a chained one: install refuses" 1 "$rc"
expect_hit "...and says so" "NOT INSTALLED" "$out"
if cmp -s "$d.second" "$hd/pre-commit"; then ok "...the second foreign hook is untouched"
else bad "...the second foreign hook is untouched" "overwritten"; fi
if cmp -s "$d.foreign" "$hd/pre-commit.cld-chained"; then ok "...the earlier chained hook is untouched"
else bad "...the earlier chained hook is untouched" "overwritten"; fi

# A chained hook that fails blocks the commit.
rm -f "$hd/pre-commit"
$SH "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
printf '#!/bin/sh\necho "foreign says no"\nexit 3\n' > "$hd/pre-commit.cld-chained"
rm -f "$d/lib/stray.js"
echo '// two' > "$d/lib/two.js"
printf 'INDEX lib/\nF known.js    Indexed\nF one.js      One\nF two.js      Two\n' > "$d/lib/index.cld"
git -C "$d" add -A
try_commit "$d" "foreign fails"
expect_rc  "a failing chained hook blocks an otherwise clean commit" 1 "$rc"
expect_hit "...and the dispatcher names it" "chained hook" "$out"
expect_hit "...and the hook's own output shows" "foreign says no" "$out"
rm -rf "$d" "$d.flog" "$d.foreign" "$d.second"

# The chained hook runs FIRST: what it re-stages is what the gate judges.
d=$(lib_repo)
hd=$d/.git/hooks
rm -f "$hd/pre-commit"
printf '#!/bin/sh\nprintf "F stray.js    Added by the chained hook\\n" >> lib/index.cld\ngit add lib/index.cld\n' > "$hd/pre-commit"
chmod +x "$hd/pre-commit"
$SH "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
echo '// stray' > "$d/lib/stray.js"
git -C "$d" add lib/stray.js
try_commit "$d" "fixed by the chained hook"
expect_rc  "the gate judges the index the chained hook left" 0 "$rc"
expect_hit "...which is what was committed" "stray.js" "$(git -C "$d" show HEAD:lib/index.cld 2>&1)"
rm -rf "$d"

# The legacy backup of an older install.sh is never overwritten, and an
# older dispatcher is recognised as ours (replaced, not chained).
d=$(fixture)
hd=$d/.git/hooks
mkdir -p "$hd"
printf '#!/bin/sh\n# @brief Pre-commit dispatcher: run every executable in\n# scripts/git-hooks/pre-commit.d/ in lexical order.\nrepo=$(git rev-parse --show-toplevel)\ndispatch_dir="$repo/scripts/git-hooks/pre-commit.d"\n' > "$hd/pre-commit"
chmod +x "$hd/pre-commit"
printf '#!/bin/sh\necho legacy\n' > "$hd/pre-commit.pre-cld"
cp "$hd/pre-commit.pre-cld" "$d.legacy"
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc "install over an older dispatcher succeeds" 0 "$rc"
if [ -e "$hd/pre-commit.cld-chained" ]; then bad "an older dispatcher is replaced, not chained" "it was chained"
else ok "an older dispatcher is replaced, not chained"; fi
expect_hit "...by the current one" "marker: cld-dispatcher" "$(cat "$hd/pre-commit" 2>&1)"
if cmp -s "$d.legacy" "$hd/pre-commit.pre-cld"; then ok "the legacy pre-commit.pre-cld is left as it was"
else bad "the legacy pre-commit.pre-cld is left as it was" "changed"; fi
expect_hit "...and pointed out" "pre-commit.pre-cld" "$out"
rm -rf "$d" "$d.legacy"

# A linked worktree: the hooks live in the main repo's git dir.
d=$(lib_repo)
rm -f "$d/.git/hooks/pre-commit"
wt=$CLD_TEST_ROOT/wt.$$
git -C "$d" worktree add -q "$wt" -b side >/dev/null 2>&1
out=$($SH "$wt/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc  "install from a linked worktree succeeds" 0 "$rc"
expect_hit "...into the shared hooks dir" "marker: cld-dispatcher" "$(cat "$d/.git/hooks/pre-commit" 2>&1)"
echo '// stray' > "$wt/lib/stray.js"
git -C "$wt" add lib/stray.js
try_commit "$wt" "stray in a worktree"
expect_rc  "a commit in the worktree is gated" 1 "$rc"
expect_hit "...by its own staged tree" "NOENTRY" "$out"
printf 'INDEX lib/\nF known.js    Indexed\nF stray.js    Indexed now\n' > "$wt/lib/index.cld"
git -C "$wt" add lib/index.cld
try_commit "$wt" "honest worktree commit"
expect_rc  "control: an honest worktree commit lands" 0 "$rc"
git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1
rm -rf "$d" "$wt"

# core.hooksPath: install where git looks, and warn.
d=$(lib_repo)
rm -f "$d/.git/hooks/pre-commit"
hp=$(mktemp -d "$CLD_TEST_ROOT/hooks.XXXXXX")
git -C "$d" config core.hooksPath "$hp"
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_rc  "install under core.hooksPath succeeds" 0 "$rc"
expect_hit "...with a warning" "WARNING: core.hooksPath" "$out"
expect_hit "...into core.hooksPath" "marker: cld-dispatcher" "$(cat "$hp/pre-commit" 2>&1)"
if [ -e "$d/.git/hooks/pre-commit" ]; then bad "...and not into .git/hooks, which git ignores" "it is there"
else ok "...and not into .git/hooks, which git ignores"; fi
echo '// stray' > "$d/lib/stray.js"
git -C "$d" add lib/stray.js
try_commit "$d" "stray under hooksPath"
expect_rc "a commit under core.hooksPath is gated" 1 "$rc"
# a relative core.hooksPath is relative to the work tree top
git -C "$d" config core.hooksPath myhooks
out=$($SH "$d/scripts/git-hooks/install.sh" 2>&1); rc=$?
expect_hit "a relative core.hooksPath lands at the work tree top" "marker: cld-dispatcher" "$(cat "$d/myhooks/pre-commit" 2>&1)"
expect_hit "...with a warning that it is inside the work tree" "inside this work tree" "$out"
rm -rf "$d" "$hp"

section "pre-commit --audit (what the index-audit-partial skill runs)"

d=$(lib_repo)
hd=$d/.git/hooks
git -C "$d" mv lib/known.js "lib/re named.js"
git -C "$d" mv lib/known.js.cld "lib/re named.js.cld"
printf 'FILE lib/re named.js\nF known      A function\n' > "$d/lib/re named.js.cld"
printf 'INDEX lib/\nF re named.js    Indexed\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/git-hooks/pre-commit --audit 2>&1); rc=$?
expect_rc  "--audit on an honest rename: would pass" 0 "$rc"
expect_hit "...shows the new name as present" "    lib/re named.js" "$out"
expect_hit "...shows the old name as gone" "    lib/known.js" "$out"
expect_hit "...and says what the hook would do" "would let this commit through" "$out"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
out=$(cd "$d/lib" && $SH ../scripts/git-hooks/pre-commit --audit 2>&1); rc=$?
expect_rc  "--audit with a violation, from a subdirectory: would block" 1 "$rc"
expect_hit "...with the finding" "NOENTRY" "$out"
expect_hit "...and the verdict" "would BLOCK" "$out"
# the skill runs exactly the command its SKILL.md gives, from anywhere
skill_cmd=$(sed -n 's/^ *`\(.*pre-commit.* --audit\)`$/\1/p' \
  "$TOOLKIT/.claude/skills/index-audit-partial/SKILL.md" 2>/dev/null | head -n 1)
if [ -n "$skill_cmd" ]; then
  out=$(cd "$d/lib" && sh -c "$skill_cmd" 2>&1); rc=$?
else
  out="no --audit command in SKILL.md"; rc=x
fi
expect_rc  "the index-audit-partial skill's own command runs the audit" 1 "$rc"
expect_hit "...and sees the same finding" "NOENTRY" "$out"
# --audit never runs a chained hook, even through the installed copy
printf '#!/bin/sh\necho ran >> "%s"\n' "$d.flog" > "$hd/pre-commit.cld-chained"
chmod +x "$hd/pre-commit.cld-chained"
out=$(cd "$d" && $SH .git/hooks/pre-commit --audit 2>&1); rc=$?
expect_hit "control: the installed copy audits too" "NOENTRY" "$out"
if [ -e "$d.flog" ]; then bad "--audit does not run the chained hook" "it ran"
else ok "--audit does not run the chained hook"; fi
git -C "$d" reset -q --hard
out=$(cd "$d" && $SH scripts/git-hooks/pre-commit --audit 2>&1); rc=$?
expect_rc  "--audit with nothing staged" 0 "$rc"
expect_hit "...says so" "nothing staged" "$out"
out=$(cd "$d" && $SH scripts/git-hooks/pre-commit --bogus 2>&1); rc=$?
expect_rc  "an unknown option is a usage error" 2 "$rc"
rm -rf "$d" "$d.flog"

section "deletions and renames reach the real checkers (--gone)"

# Narrow: deleting one file never re-audits a whole index, so an old
# orphan (and an old dead symbol index) elsewhere do not block it.
d=$(lib_repo)
printf 'INDEX lib/\nF known.js    Indexed\nF ghost.js    Long gone\n' > "$d/lib/index.cld"
printf 'FILE lib/ghost.js\nF ghost      Long gone\n' > "$d/lib/ghost.js.cld"
echo png > "$d/lib/pic.png"
stage "$d"
git -C "$d" commit -qm "old debt" --no-verify >/dev/null 2>&1
out=$(cd "$d" && $SH scripts/index-audit/check.sh 2>&1)
expect_hit "control: the sweep sees the old orphan" "ghost.js" "$out"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh 2>&1)
expect_hit "control: the sweep sees the old dead symbol index" "SYM-DEAD lib/ghost.js.cld" "$out"
git -C "$d" rm -q lib/pic.png
try_commit "$d" "unrelated deletion"
expect_rc "an honest deletion is not blocked by someone else's old orphan" 0 "$rc"
rm -rf "$d"

# A deletion whose index.cld entry stays behind (no symbol index involved).
d=$(lib_repo)
echo notes > "$d/lib/notes.txt"
printf 'INDEX lib/\nF known.js    Indexed\nF notes.txt   Notes\n' > "$d/lib/index.cld"
stage "$d"
git -C "$d" commit -qm "notes" >/dev/null 2>&1
git -C "$d" rm -q lib/notes.txt
n=$(commits "$d")
try_commit "$d" "delete, entry stays"
expect_rc  "deleting a file whose index.cld entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN for that entry" "ORPHAN   lib/index.cld:3  entry 'notes.txt'" "$out"
expect_eq  "...and nothing landed" "$n" "$(commits "$d")"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: the tree really has that ORPHAN" "notes.txt" "$out"
printf 'INDEX lib/\nF known.js    Indexed\n' > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete, entry removed"
expect_rc  "control: the same deletion with its entry removed commits" 0 "$rc"
rm -rf "$d"

# A deletion whose <file>.cld stays behind (the dir index is updated).
d=$(lib_repo)
git -C "$d" rm -q lib/known.js
printf 'INDEX lib/\n' > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete, symbol index stays"
expect_rc  "deleting a file whose <file>.cld stays is blocked" 1 "$rc"
expect_hit "...as SYM-DEAD for the index left behind" "SYM-DEAD lib/known.js.cld" "$out"
expect_miss "...and not as a directory finding" "index-audit: BLOCKED" "$out"
out=$(cd "$d" && $SH scripts/symbol-audit/check.sh lib/known.js.cld 2>&1)
expect_hit "control: the tree really has that SYM-DEAD" "SYM-DEAD lib/known.js.cld" "$out"
git -C "$d" rm -q lib/known.js.cld
try_commit "$d" "delete with its symbol index"
expect_rc  "control: the same deletion with its <file>.cld removed commits" 0 "$rc"
rm -rf "$d"

# A renamed directory whose "D old/" entry stays behind.
d=$(lib_repo)
mkdir -p "$d/lib/sub"
printf 'INDEX lib/sub/\nF s.txt    S\n' > "$d/lib/sub/index.cld"
echo s > "$d/lib/sub/s.txt"
printf 'INDEX lib/\nF known.js    Indexed\nD sub/        Sub\n' > "$d/lib/index.cld"
stage "$d"
git -C "$d" commit -qm "sub" >/dev/null 2>&1
git -C "$d" mv lib/sub lib/sub2
try_commit "$d" "rename dir, entry stays"
expect_rc  "renaming a directory whose D entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN for the D entry" "ORPHAN   lib/index.cld:3  entry 'sub/'" "$out"
expect_hit "...and the moved index's old header is a WRONGPATH warning" "WRONGPATH" "$out"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: the tree really has that ORPHAN" "sub/" "$out"
printf 'INDEX lib/\nF known.js    Indexed\nD sub2/       Sub\n' > "$d/lib/index.cld"
printf 'INDEX lib/sub2/\nF s.txt    S\n' > "$d/lib/sub2/index.cld"
stage "$d"
try_commit "$d" "rename dir, indexes follow"
expect_rc  "control: the rename with both indexes updated commits" 0 "$rc"
expect_miss "...without a WRONGPATH warning once the header follows too" "WRONGPATH" "$out"
rm -rf "$d"

section "routing reaches the real checkers"

# The stub cases above pin down what the dispatcher hands over; these run
# the same kinds of commit through the REAL checkers, so the two halves
# of the --gone contract are tested together. Each has a control: the
# honest version of the same commit goes through.

# real_repo -- the real checkers, the hooks installed, and an honest base
# commit with the names the stub cases use: a spaced name, a non-ASCII
# name with a symbol index, a symlink, a subdirectory.
real_repo() {
  _r=$(fixture)
  $SH "$_r/scripts/git-hooks/install.sh" >/dev/null 2>&1
  mkdir -p "$_r/lib/sub"
  printf 'INDEX lib/\nF a.js      A\nF a b.js    Spaced\nF ünï.js    Unicode\nL link.js   Link\nD sub/      Sub\n' > "$_r/lib/index.cld"
  echo 'function a() {}' > "$_r/lib/a.js"
  printf 'FILE lib/a.js\nF a     A\n' > "$_r/lib/a.js.cld"
  echo 'x' > "$_r/lib/a b.js"
  echo 'const x = 1' > "$_r/lib/ünï.js"
  printf 'FILE lib/ünï.js\nK x     X\n' > "$_r/lib/ünï.js.cld"
  ln -s a.js "$_r/lib/link.js"
  printf 'INDEX lib/sub/\nF s.txt    S\n' > "$_r/lib/sub/index.cld"
  echo s > "$_r/lib/sub/s.txt"
  stage "$_r"
  git -C "$_r" commit -qm base >/dev/null 2>&1
  printf '%s' "$_r"
}
# lib_without <entry-name> -- lib/index.cld of real_repo minus that entry
lib_without() {
  printf 'INDEX lib/\nF a.js      A\nF a b.js    Spaced\nF ünï.js    Unicode\nL link.js   Link\nD sub/      Sub\n' |
    grep -v -F -e " $1 "
}

d=$(real_repo)
expect_eq "control: the base commit landed" "1" "$(commits "$d")"
out=$(cd "$d" && $SH scripts/index-audit/check.sh 2>&1 && $SH scripts/symbol-audit/check.sh 2>&1); rc=$?
expect_rc "control: the base tree sweeps clean with both checkers" 0 "$rc"
rm -rf "$d"

# A rename with nothing updated: the old name is an ORPHAN and a dead
# symbol index, the new name has no entry.
d=$(real_repo)
git -C "$d" mv lib/a.js lib/b.js
try_commit "$d" "rename, nothing updated"
expect_rc  "a bare rename is blocked" 1 "$rc"
expect_hit "...the old entry is an ORPHAN" "ORPHAN   lib/index.cld:2  entry 'a.js'" "$out"
expect_hit "...the new name has no entry" "NOENTRY  lib/b.js:-  no entry in lib/index.cld" "$out"
expect_hit "...and the old <file>.cld is SYM-DEAD" "SYM-DEAD lib/a.js.cld" "$out"
git -C "$d" mv lib/a.js.cld lib/b.js.cld
printf 'FILE lib/b.js\nF a     A\n' > "$d/lib/b.js.cld"
lib_without a.js > "$d/lib/index.cld"
printf 'F b.js      B\n' >> "$d/lib/index.cld"
stage "$d"
try_commit "$d" "rename, indexes follow"
expect_rc  "control: the rename with both indexes updated commits" 0 "$rc"
rm -rf "$d"

# A deleted name holding a space: the entry that names it is found.
d=$(real_repo)
git -C "$d" rm -q "lib/a b.js"
try_commit "$d" "delete a spaced name"
expect_rc  "deleting a spaced name whose entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN naming it in full" "entry 'a b.js' names a missing target" "$out"
lib_without "a b.js" > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete a spaced name and its entry"
expect_rc  "control: with its entry removed it commits" 0 "$rc"
rm -rf "$d"

# A deleted non-ASCII name (git would C-quote it without quotePath=false)
# whose <file>.cld stays.
d=$(real_repo)
git -C "$d" rm -q "lib/ünï.js"
lib_without "ünï.js" > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete a non-ASCII name"
expect_rc  "deleting a non-ASCII name whose <file>.cld stays is blocked" 1 "$rc"
expect_hit "...as SYM-DEAD, spelled as named" "SYM-DEAD lib/ünï.js.cld" "$out"
git -C "$d" rm -q "lib/ünï.js.cld"
try_commit "$d" "delete a non-ASCII name and its index"
expect_rc  "control: with its <file>.cld removed it commits" 0 "$rc"
rm -rf "$d"

# A deleted symlink whose L entry stays.
d=$(real_repo)
git -C "$d" rm -q lib/link.js
try_commit "$d" "delete a symlink"
expect_rc  "deleting a symlink whose entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN" "entry 'link.js' names a missing target" "$out"
lib_without link.js > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete a symlink and its entry"
expect_rc  "control: with its entry removed it commits" 0 "$rc"
rm -rf "$d"

# A deleted directory whose D entry stays: the gone directory reaches the
# parent's index, although no path in it was ever named "sub".
d=$(real_repo)
git -C "$d" rm -rq lib/sub
try_commit "$d" "delete a dir"
expect_rc  "deleting a directory whose D entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN for the D entry" "entry 'sub/' names a missing target" "$out"
lib_without sub/ > "$d/lib/index.cld"
git -C "$d" add lib/index.cld
try_commit "$d" "delete a dir and its entry"
expect_rc  "control: with its entry removed it commits" 0 "$rc"
rm -rf "$d"

# A file replaced by a directory of the same name is not gone: no
# ORPHAN for its entry (the letter is now wrong, which only warns).
d=$(real_repo)
git -C "$d" rm -q "lib/a b.js"
mkdir "$d/lib/a b.js"
echo s > "$d/lib/a b.js/inner.txt"
stage "$d"
try_commit "$d" "file becomes dir"
expect_rc  "a file replaced by a directory is not an ORPHAN" 0 "$rc"
expect_miss "...no ORPHAN is reported" "ORPHAN" "$out"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1)
expect_hit "control: the entry's letter is now wrong (WRONGTYPE warns)" "WRONGTYPE" "$out"
rm -rf "$d"

# New entries the gate must see: a dangling symlink, a symlink to a
# directory, a non-ASCII name, none of them indexed.
d=$(real_repo)
ln -s nowhere "$d/lib/dangle.json"
ln -s sub "$d/lib/dirlink.js"
echo y > "$d/lib/nëw.js"
stage "$d"
try_commit "$d" "unindexed odd entries"
expect_rc  "unindexed odd entries are blocked" 1 "$rc"
expect_hit "...a dangling symlink has no entry" "NOENTRY  lib/dangle.json:-" "$out"
expect_hit "...a symlink to a directory has no entry" "NOENTRY  lib/dirlink.js:-" "$out"
expect_hit "...a non-ASCII name has no entry" "NOENTRY  lib/nëw.js:-" "$out"
{ lib_without nothing; printf 'L dangle.json   Dangles\nL dirlink.js    Points at sub/\nF nëw.js        New\n'; } > "$d/lib/index.cld"
stage "$d"
try_commit "$d" "odd entries indexed"
expect_rc  "control: indexed, they commit" 0 "$rc"
rm -rf "$d"

# Names that look like options or patterns go through the real checkers
# without being read as one: a root-level "-dash.js", a file literally
# named "--gone" (the gate passes both as ./name, and a checker that took
# ./--gone for the marker would treat every later path as deleted, so the
# NOENTRY for lib/x*.js, sorted after it, is the proof), and "x*.js".
d=$(real_repo)
printf 'INDEX ./\nD lib/        Lib\nD scripts/    Toolkit\n' > "$d/index.cld"
echo 1 > "$d/-dash.js"
echo 2 > "$d/--gone"
echo 3 > "$d/lib/x*.js"
stage "$d"
try_commit "$d" "option-like names"
expect_rc  "option-like names are checked, not obeyed" 1 "$rc"
expect_hit "...-dash.js has no entry" "NOENTRY  -dash.js:-  no entry in index.cld" "$out"
expect_hit "...a file named --gone is not the marker: x*.js after it is still checked" "NOENTRY  lib/x*.js:-" "$out"
expect_no_shell_error "...and nothing crashed" "$out"
printf 'INDEX ./\nD lib/        Lib\nD scripts/    Toolkit\nF -dash.js     D\nF --gone      G\n' > "$d/index.cld"
{ lib_without nothing; printf 'F x*.js      Star\n'; } > "$d/lib/index.cld"
stage "$d"
try_commit "$d" "option-like names indexed"
expect_rc  "control: indexed, they commit" 0 "$rc"
git -C "$d" rm -q -- -dash.js
try_commit "$d" "delete -dash.js, entry stays"
expect_rc  "deleting -dash.js whose entry stays is blocked" 1 "$rc"
expect_hit "...as an ORPHAN" "entry '-dash.js' names a missing target" "$out"
rm -rf "$d"

finish
