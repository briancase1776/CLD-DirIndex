#!/bin/sh
# tests/cases/00-foundation.sh
# @brief Foundation cases shared by both checkers: the cld-lib.sh helpers,
# how a checker finds the repo and spells a path, the temp-tree contract
# the commit gate builds on, and the config loader with the shipped
# cld.conf.
#
# Run alone (sh tests/cases/00-foundation.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

IA=scripts/index-audit/check.sh
SA=scripts/symbol-audit/check.sh

# lib <command...> -- run a command with cld-lib.sh sourced, in a shell of
# its own, from the current directory.
lib() {
  $SH -c '. "$0/scripts/cld-lib.sh" && "$@"' "$TOOLKIT" "$@"
}

section "cld-lib.sh: cld_norm"

norm_case() {
  _got=$(cd "$TOOLKIT" && lib cld_norm "$1")
  expect_eq "cld_norm '$1' -> '$2'" "$2" "$_got"
}
norm_case 'lib'                 'lib'
norm_case 'lib/'                'lib'
norm_case './lib'               'lib'
norm_case './lib/'              'lib'
norm_case 'lib///'              'lib'
norm_case 'a//b'                'a/b'
norm_case 'a/./b'               'a/b'
norm_case 'a/../b'              'b'
norm_case '.'                   '.'
norm_case './'                  '.'
norm_case '../x'                '../x'
norm_case '/a/../b'             '/b'
norm_case './a b//c/'           'a b/c'
norm_case 'Tree Palette.html'   'Tree Palette.html'
# run where files exist, so a pathname expansion would show
norm_case '*'                   '*'

section "cld-lib.sh: listing and locating"

# --- cld_ls_files/cld_ls_under: names git would C-quote come out verbatim ---
d=$(fixture)
mkdir -p "$d/lib" "$d/ünï dir"
echo a > "$d/lib/a.js"
echo q > "$d/lib/q\"x.js"
echo s > "$d/lib/back\\slash.js"
echo b > "$d/ünï dir/b c.js"
stage "$d"
want=$(printf '%s\n' 'lib/a.js' 'lib/back\slash.js' 'lib/q"x.js' 'ünï dir/b c.js' | LC_ALL=C sort)
got=$(cd "$d" && $SH -c '. "$0/scripts/cld-lib.sh" && cld_init && cld_ls_under lib && cld_ls_under "ünï dir"' "$TOOLKIT" 2>&1 | LC_ALL=C sort)
expect_eq "tracked names with non-ASCII, quote and backslash list verbatim" "$want" "$got"
got=$(cd "$d" && $SH -c '. "$0/scripts/cld-lib.sh" && cld_init && cld_ls_files' "$TOOLKIT" 2>&1)
expect_hit "the whole-repo listing includes the non-ASCII name" "ünï dir/b c.js" "$got"
expect_miss "the whole-repo listing never C-quotes" '\303' "$got"
rm -rf "$d"

# --- cld_init: the root comes from where the caller stands ---
d=$(fixture)
mkdir -p "$d/ünï dir"
echo b > "$d/ünï dir/b.js"
stage "$d"
real=$(cd "$d" && pwd -P)
got=$(cd "$d/ünï dir" && $SH -c '. "$0/scripts/cld-lib.sh" && cld_init && printf "%s|%s|%s" "$CLD_REPO" "$CLD_PREFIX" "$(pwd -P)"' "$TOOLKIT" 2>&1)
expect_eq "from a subdirectory: root, prefix, and cwd left at the root" "$real|ünï dir/|$real" "$got"

# --- cld_init honours GIT_DIR/GIT_WORK_TREE, and pins relative ones ---
t=$(mktemp -d "$CLD_TEST_ROOT/wt.XXXXXX")
treal=$(cd "$t" && pwd -P)
got=$(cd "$t" && GIT_DIR="$d/.git" GIT_WORK_TREE="$t" $SH -c '. "$0/scripts/cld-lib.sh" && cld_init && printf "%s" "$CLD_REPO"' "$TOOLKIT" 2>&1)
expect_eq "GIT_WORK_TREE decides the root, not the repo GIT_DIR belongs to" "$treal" "$got"
got=$(cd "$d/ünï dir" && GIT_DIR=../.git GIT_WORK_TREE=.. $SH -c '. "$0/scripts/cld-lib.sh" && cld_init && printf "%s|%s|" "$CLD_REPO" "$CLD_PREFIX" && cld_ls_under "ünï dir"' "$TOOLKIT" 2>&1)
expect_eq "relative GIT_DIR/GIT_WORK_TREE still work after the cd to the root" "$real|ünï dir/|ünï dir/b.js" "$got"

# --- inside .git there is no tree to check: say so, do not guess ---
out=$(cd "$d/.git" && $SH "$d/$IA" 2>&1); rc=$?
expect_rc  "index-audit inside .git is a setup error (exit 2)" 2 "$rc"
expect_hit "index-audit inside .git says why" "not inside its work tree" "$out"
out=$(cd "$d/.git" && $SH "$d/$SA" 2>&1); rc=$?
expect_rc  "symbol-audit inside .git is a setup error (exit 2)" 2 "$rc"
out=$(cd "$d" && $SH "$d/$IA" 2>&1); rc=$?
expect_rc  "control: the same checker from the work tree runs (exit 0)" 0 "$rc"
rm -rf "$d" "$t"

# --- no git at all: index-audit checks the plain directory ---
p=$(plain_dir)
cp -R "$TOOLKIT/scripts" "$p/"
mkdir -p "$p/lib"
printf 'INDEX lib/\nF a.js       Here\nF ghost.js   Not here\n' > "$p/lib/index.cld"
echo a > "$p/lib/a.js"
echo s > "$p/lib/stray.js"
out=$(cd "$p" && GIT_CEILING_DIRECTORIES="$CLD_TEST_ROOT" $SH $IA 2>&1); rc=$?
expect_hit "plain dir sweep: ORPHAN" "ghost.js" "$out"
expect_hit "plain dir sweep: NOENTRY" "lib/stray.js" "$out"
expect_rc  "plain dir sweep blocks (exit 1)" 1 "$rc"
out=$(cd "$p" && GIT_CEILING_DIRECTORIES="$CLD_TEST_ROOT" $SH $IA lib/ 2>&1)
expect_hit "plain dir, dir argument lib/: ORPHAN" "ghost.js" "$out"
printf 'INDEX lib/\nF a.js       Here\nF stray.js   Here too\n' > "$p/lib/index.cld"
out=$(cd "$p" && GIT_CEILING_DIRECTORIES="$CLD_TEST_ROOT" $SH $IA 2>&1); rc=$?
expect_hit "plain dir, honest index: clean" "index-audit: clean" "$out"
expect_rc  "plain dir, honest index: exit 0" 0 "$rc"
rm -rf "$p"

section "both checkers: the repo is where you stand"

# A toolkit checkout T, and a host repo H that carries no toolkit at all.
# Run from inside H, T's checkers must check H, with H's cld.conf.
T=$(fixture)
stage "$T"
H=$(mktemp -d "$CLD_TEST_ROOT/host.XXXXXX")
H=$(cd "$H" && pwd -P)
git -C "$H" init -q
printf "CLD_SKIP_RE='third_party/'\n" > "$H/cld.conf"
mkdir -p "$H/lib" "$H/other" "$H/clean" "$H/third_party"
printf 'INDEX lib/\nF real.js    Here\nF ghost.js   Not here\n' > "$H/lib/index.cld"
echo '// real' > "$H/lib/real.js"
printf 'FILE lib/gone.js\nC Gone       Indexes a file that is not there\n' > "$H/lib/gone.js.cld"
printf 'INDEX other/\nF nothere.txt   Not here either\n' > "$H/other/index.cld"
printf 'INDEX clean/\nF ok.js   Here\n' > "$H/clean/index.cld"
echo '// ok' > "$H/clean/ok.js"
printf 'INDEX third_party/\n' > "$H/third_party/index.cld"
echo '// vendored' > "$H/third_party/vendored.js"
stage "$H"

out=$(cd "$H" && $SH "$T/$IA" lib/index.cld third_party/vendored.js 2>&1); rc=$?
expect_hit  "index-audit run from H checks H" "ghost.js" "$out"
expect_miss "index-audit run from H uses H's cld.conf" "NOENTRY" "$out"
expect_rc   "index-audit run from H blocks on H (exit 1)" 1 "$rc"
out=$(cd "$H" && $SH "$T/$SA" 2>&1); rc=$?
expect_hit  "symbol-audit run from H sweeps H" "SYM-DEAD lib/gone.js.cld" "$out"
expect_rc   "symbol-audit run from H blocks on H (exit 1)" 1 "$rc"
out=$(cd "$T" && $SH "$T/$IA" 2>&1); rc=$?
expect_hit  "control: the toolkit's own repo is index-clean" "index-audit: clean" "$out"
out=$(cd "$T" && $SH "$T/$SA" 2>&1); rc=$?
expect_hit  "control: the toolkit's own repo is symbol-clean" "symbol-audit: clean" "$out"

section "both checkers: arguments relative to where you stand"

out=$(cd "$H/lib" && $SH "$T/$SA" gone.js.cld 2>&1); rc=$?
expect_hit "symbol-audit from lib/ resolves gone.js.cld" "SYM-DEAD lib/gone.js.cld" "$out"
expect_rc  "symbol-audit from lib/ blocks (exit 1)" 1 "$rc"
out=$(cd "$H/lib" && $SH "$T/$IA" index.cld 2>&1); rc=$?
expect_hit "index-audit from lib/ resolves index.cld, reported root-relative" "lib/index.cld:3" "$out"
expect_rc  "index-audit from lib/ blocks (exit 1)" 1 "$rc"
out=$(cd "$H/clean" && $SH "$T/$IA" 2>&1); rc=$?
expect_hit "index-audit with no argument sweeps the whole repo, not just cwd" "other/index.cld" "$out"
out=$(cd "$H/clean" && $SH "$T/$SA" 2>&1); rc=$?
expect_hit "symbol-audit with no argument sweeps the whole repo, not just cwd" "SYM-DEAD lib/gone.js.cld" "$out"

section "both checkers: a directory argument, however it is spelled"

for spell in lib lib/ ./lib ./lib/ "$H/lib" . ./; do
  out=$(cd "$H" && $SH "$T/$IA" "$spell" 2>&1)
  expect_hit "index-audit '$spell' checks lib" "ghost.js" "$out"
  out=$(cd "$H" && $SH "$T/$SA" "$spell" 2>&1)
  expect_hit "symbol-audit '$spell' checks lib" "SYM-DEAD lib/gone.js.cld" "$out"
done
# the repo reached through a symlink is still the repo
ln -s "$H" "$CLD_TEST_ROOT/host-link"
out=$(cd "$H" && $SH "$T/$IA" "$CLD_TEST_ROOT/host-link/lib" 2>&1)
expect_hit "index-audit: an absolute path through a symlink checks lib" "ghost.js" "$out"
out=$(cd "$H" && $SH "$T/$SA" "$CLD_TEST_ROOT/host-link/lib" 2>&1)
expect_hit "symbol-audit: an absolute path through a symlink checks lib" "SYM-DEAD lib/gone.js.cld" "$out"
out=$(cd "$H" && $SH "$T/$IA" "$CLD_TEST_ROOT/host-link/lib/index.cld" 2>&1)
expect_hit "index-audit: an absolute FILE path through a symlink resolves" "lib/index.cld:3" "$out"
out=$(cd "$H" && $SH "$T/$IA" "$CLD_TEST_ROOT/host-link" 2>&1)
expect_hit "index-audit: the repo root through a symlink is the whole repo" "other/index.cld" "$out"
rm -f "$CLD_TEST_ROOT/host-link"
out=$(cd "$H" && $SH "$T/$IA" clean/ 2>&1); rc=$?
expect_hit "control: index-audit clean/ checks only clean/" "index-audit: clean" "$out"
out=$(cd "$H" && $SH "$T/$SA" clean/ 2>&1); rc=$?
expect_hit "control: symbol-audit clean/ checks only clean/" "symbol-audit: clean" "$out"

section "both checkers: names git would quote, names that look like patterns"

d=$(fixture)
mkdir -p "$d/ünï dir" "$d/a[1]" "$d/a1"
printf 'INDEX ünï dir/\nF known.js   Indexed\n' > "$d/ünï dir/index.cld"
echo '// known' > "$d/ünï dir/known.js"
echo '// stray' > "$d/ünï dir/a b.js"
printf 'FILE ünï dir/x y.js\nC Gone   Indexes a file that is not there\n' > "$d/ünï dir/x y.js.cld"
printf 'INDEX a[1]/\nF bracket-ghost.js   Not here\n' > "$d/a[1]/index.cld"
printf 'FILE a[1]/g.js\nC G   Not here\n' > "$d/a[1]/g.js.cld"
printf 'INDEX a1/\nF plain-ghost.js   Not here\n' > "$d/a1/index.cld"
printf 'FILE a1/h.js\nC H   Not here\n' > "$d/a1/h.js.cld"
stage "$d"
out=$(cd "$d" && $SH $IA "ünï dir" 2>&1)
expect_hit "index-audit dir argument with a non-ASCII name finds NOENTRY" "ünï dir/a b.js" "$out"
out=$(cd "$d" && $SH $IA 2>&1)
expect_hit "index-audit sweep reaches a non-ASCII path" "ünï dir/a b.js" "$out"
out=$(cd "$d" && $SH $SA 2>&1)
expect_hit "symbol-audit sweep reaches a non-ASCII path" "SYM-DEAD ünï dir/x y.js.cld" "$out"
out=$(cd "$d" && $SH $IA 'a[1]' 2>&1)
expect_hit  "index-audit 'a[1]' checks the directory named a[1]" "bracket-ghost.js" "$out"
expect_miss "index-audit 'a[1]' is not a glob that also matches a1" "plain-ghost.js" "$out"
out=$(cd "$d" && $SH $SA 'a[1]' 2>&1)
expect_hit  "symbol-audit 'a[1]' checks the directory named a[1]" "a[1]/g.js.cld" "$out"
expect_miss "symbol-audit 'a[1]' is not a glob that also matches a1" "a1/h.js.cld" "$out"
out=$(cd "$d" && $SH $IA a1 2>&1)
expect_hit  "control: index-audit a1 checks a1" "plain-ghost.js" "$out"

# a CDPATH in the environment must not move a checker off its own files
# (cd consults CDPATH for a relative name, and prints where it went)
out=$(cd "$d" && CDPATH="$T" $SH $IA a1 2>&1)
expect_hit  "index-audit runs correctly with CDPATH set" "plain-ghost.js" "$out"
out=$(cd "$d" && CDPATH="$T" $SH $SA a1 2>&1)
expect_hit  "symbol-audit runs correctly with CDPATH set" "a1/h.js.cld" "$out"
rm -rf "$d"

section "temp tree from the index (the commit gate's contract)"

# The gate materialises the STAGED tree with checkout-index and runs the
# checkers inside it with GIT_DIR=<real git dir> GIT_WORK_TREE=<tmp>.
# Both checkers must then answer about that tree, wherever the script
# they run from lives, and never about the real working tree.
R=$(fixture)
R=$(cd "$R" && pwd -P)
mkdir -p "$R/lib"
printf 'INDEX lib/\nF a.js    A file\n' > "$R/lib/index.cld"
echo 'function a() {}' > "$R/lib/a.js"
printf 'FILE lib/a.js\nF a       A function\n' > "$R/lib/a.js.cld"
stage "$R"
git -C "$R" commit -qm base >/dev/null 2>&1

# 1. index clean, working tree dirty (an unstaged deletion)
rm "$R/lib/a.js"
out=$(cd "$R" && $SH $IA lib/index.cld 2>&1)
expect_hit "control: the dirty working tree has an ORPHAN" "ORPHAN" "$out"
out=$(cd "$R" && $SH $SA lib/a.js.cld 2>&1)
expect_hit "control: the dirty working tree has a SYM-DEAD" "SYM-DEAD" "$out"
t1=$(mktemp -d "$CLD_TEST_ROOT/staged.XXXXXX")
t1=$(cd "$t1" && pwd -P)
git -C "$R" checkout-index -a --prefix="$t1/"
out=$(cd "$t1" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t1" $SH $IA lib/index.cld 2>&1); rc=$?
expect_hit "staged tree: index-audit sees the staged file, not the deletion" "index-audit: clean" "$out"
expect_rc  "staged tree: index-audit exit 0" 0 "$rc"
out=$(cd "$t1" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t1" $SH $SA lib/a.js.cld 2>&1); rc=$?
expect_hit "staged tree: symbol-audit sees the staged target" "symbol-audit: clean" "$out"
expect_rc  "staged tree: symbol-audit exit 0" 0 "$rc"

# 2. index dirty, working tree clean
git -C "$R" checkout -- lib/a.js
printf 'INDEX lib/\nF a.js    A file\nF ghost.js   Staged, never written\n' > "$R/lib/index.cld"
printf 'FILE lib/b.js\nF b       Staged, target never written\n' > "$R/lib/b.js.cld"
git -C "$R" add lib/index.cld lib/b.js.cld
git -C "$R" show HEAD:lib/index.cld > "$R/lib/index.cld"
rm "$R/lib/b.js.cld"
out=$(cd "$R" && $SH $IA lib/index.cld 2>&1)
expect_hit "control: the working tree itself is index-clean" "index-audit: clean" "$out"
t2=$(mktemp -d "$CLD_TEST_ROOT/staged.XXXXXX")
t2=$(cd "$t2" && pwd -P)
git -C "$R" checkout-index -a --prefix="$t2/"
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH $IA lib/index.cld 2>&1); rc=$?
expect_hit "staged tree: index-audit sees the staged ORPHAN" "ghost.js" "$out"
expect_rc  "staged tree: index-audit blocks (exit 1)" 1 "$rc"
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH $SA lib/b.js.cld 2>&1); rc=$?
expect_hit "staged tree: symbol-audit sees the staged SYM-DEAD" "SYM-DEAD lib/b.js.cld" "$out"
expect_rc  "staged tree: symbol-audit blocks (exit 1)" 1 "$rc"
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH $IA 2>&1)
expect_hit "staged tree: index-audit sweep finds the ORPHAN" "ghost.js" "$out"
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH $SA 2>&1)
expect_hit "staged tree: symbol-audit sweep finds the SYM-DEAD" "SYM-DEAD lib/b.js.cld" "$out"
# the real repo's scripts, run from inside the temp tree, answer the same
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH "$R/$IA" lib/index.cld 2>&1)
expect_hit "staged tree via the real repo's index-audit: same answer" "ghost.js" "$out"
out=$(cd "$t2" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t2" $SH "$R/$SA" lib/b.js.cld 2>&1)
expect_hit "staged tree via the real repo's symbol-audit: same answer" "SYM-DEAD lib/b.js.cld" "$out"
rm -rf "$R" "$t1" "$t2"

section "shipped cld.conf and the loader"

# The repo ships a real cld.conf, not a sample: it is what a host repo
# copies, and this repo runs on it. These guard the ways that goes
# wrong -- it stops parsing, or it drifts out of sync with the fallback
# defaults in cld-config.sh (a key added to one and not the other means
# an adopter silently gets a default they cannot see in their config).

if sh -n "$TOOLKIT/cld.conf" 2>/dev/null; then
  ok "the shipped cld.conf parses"
else
  bad "the shipped cld.conf parses" "sh -n rejected it"
fi

conf_keys=$(grep -o '^CLD_[A-Z_]*=' "$TOOLKIT/cld.conf" | sort -u)
def_keys=$(grep -o '^CLD_[A-Z_]*=' "$TOOLKIT/scripts/cld-config.sh" | sort -u)
missing=$(printf '%s\n' "$def_keys" | grep -vxF "$conf_keys" || true)
extra=$(printf '%s\n' "$conf_keys" | grep -vxF "$def_keys" || true)
if [ -z "$missing" ]; then
  ok "every default in cld-config.sh appears in cld.conf"
else
  bad "every default in cld-config.sh appears in cld.conf" \
      "absent from cld.conf: $(echo "$missing" | tr '\n' ' ')"
fi
if [ -z "$extra" ]; then
  ok "cld.conf defines no key the loader ignores"
else
  bad "cld.conf defines no key the loader ignores" \
      "unknown to cld-config.sh: $(echo "$extra" | tr '\n' ' ')"
fi

# value_of <dir-holding-cld.conf-or-not> <key> -- what the loader decides
value_of() {
  $SH -c 'set -u; CLD_REPO=$1; . "$0/scripts/cld-config.sh"; eval "printf %s \"\${$2}\""' \
      "$TOOLKIT" "$1" "$2" 2>&1
}
# conf_drift <dir> -- the keys whose value differs from the no-conf default
conf_drift() {
  _drift=
  for _k in $(printf '%s\n' "$def_keys" | tr -d =); do
    [ "$(value_of "$noconf" "$_k")" = "$(value_of "$1" "$_k")" ] || _drift="$_drift $_k"
  done
  printf '%s' "$_drift"
}
noconf=$(mktemp -d "$CLD_TEST_ROOT/noconf.XXXXXX")
shipped=$(mktemp -d "$CLD_TEST_ROOT/shipped.XXXXXX")
cp "$TOOLKIT/cld.conf" "$shipped/"
expect_eq "the shipped cld.conf sets every key to the loader's default" "" "$(conf_drift "$shipped")"
edited=$(mktemp -d "$CLD_TEST_ROOT/edited.XXXXXX")
{ cat "$TOOLKIT/cld.conf"; echo 'CLD_INDEXABLE_EXTS="js"'; } > "$edited/cld.conf"
expect_eq "control: a changed value is seen as drift" " CLD_INDEXABLE_EXTS" "$(conf_drift "$edited")"
rm -rf "$noconf" "$shipped" "$edited"

# ...and a fixture carrying the shipped conf verbatim still runs clean.
d=$(fixture --conf)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF a.js       First\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"
stage "$d"
out=$(cd "$d" && $SH $IA lib/ 2>&1); rc=$?
expect_hit "a repo using the shipped conf verbatim is clean" "index-audit: clean" "$out"
expect_rc  "shipped conf exits 0 on a clean tree" 0 "$rc"
out=$(cd "$d" && $SH $SA 2>&1); rc=$?
expect_hit "a repo using the shipped conf verbatim is symbol-clean" "symbol-audit: clean" "$out"
expect_rc  "shipped conf: symbol-audit exits 0 on a clean tree" 0 "$rc"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
out=$(cd "$d" && $SH $IA lib/ 2>&1); rc=$?
expect_hit "control: the shipped conf still lets NOENTRY fire" "NOENTRY" "$out"
rm -rf "$d"

# --- config comes from cld.conf only, never from the environment ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js   Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
out=$(cd "$d" && CLD_SKIP_RE='lib/' $SH $IA lib/stray.js 2>&1)
expect_hit "a CLD_SKIP_RE in the environment is ignored" "NOENTRY" "$out"
printf "CLD_SKIP_RE='lib/'\n" > "$d/cld.conf"
out=$(cd "$d" && $SH $IA lib/stray.js 2>&1)
expect_miss "control: the same value in cld.conf is honoured" "NOENTRY" "$out"
rm -rf "$d"

# --- a cld.conf may build on a default ---
d=$(fixture)
mkdir -p "$d/lib" "$d/third_party" "$d/node_modules/dep"
printf 'CLD_SKIP_RE="$CLD_SKIP_RE\\|third_party/"\n' > "$d/cld.conf"
printf 'INDEX lib/\nF known.js   Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
printf 'INDEX third_party/\n' > "$d/third_party/index.cld"
echo '// vendored' > "$d/third_party/vendored.js"
printf 'INDEX node_modules/dep/\n' > "$d/node_modules/dep/index.cld"
echo '// dep' > "$d/node_modules/dep/dep.js"
stage "$d"
out=$(cd "$d" && $SH $IA 2>&1)
expect_no_shell_error "a cld.conf extending a default does not crash" "$out"
expect_miss "the added skip applies" "third_party/vendored.js" "$out"
expect_miss "the default skips still apply" "node_modules/dep/dep.js" "$out"
expect_hit  "control: an unskipped stray still raises NOENTRY" "lib/stray.js" "$out"
rm -rf "$d"

# --- a cld.conf that unsets a key cannot leave it unset under set -u ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'unset CLD_DECL_RE CLD_SYM_MISS_EXTS CLD_SYM_MISS_SKIP_RE\n' > "$d/cld.conf"
echo 'class Orphaned {}' > "$d/lib/orphaned.js"
stage "$d"
out=$(cd "$d" && $SH $SA lib/orphaned.js 2>&1); rc=$?
expect_no_shell_error "an unset key in cld.conf does not crash symbol-audit" "$out"
expect_hit "the unset keys fall back to their defaults (SYM-MISS still warns)" "SYM-MISS" "$out"
expect_rc  "an unset key in cld.conf: exit 0" 0 "$rc"
rm -rf "$d"

finish
