#!/bin/sh
# tests/cases/10-index-audit.sh
# @brief Directory-index checker cases: each finding code (ORPHAN,
# NOENTRY, BADHDR, WRONGPATH, WRONGTYPE, CRLF, NOINDEX, NODENTRY) fires
# when it should and stays quiet when it should not; sweeps that cannot
# finish say so; --gone stays narrow. Throwaway git fixtures throughout.
#
# Every case that expects silence also has a positive control: the same
# fixture, or the same needle, made to fire. A needle that can never
# match the output format, or a check that has silently died, then fails
# a test instead of passing one.
#
# Run alone (sh tests/cases/10-index-audit.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

IA=scripts/index-audit/check.sh

# ia <repo> [args...] -- run index-audit from the repo root; sets out, rc
ia() {
  _r=$1
  shift
  out=$(cd "$_r" && $SH "$IA" "$@" 2>&1)
  rc=$?
}

# expect_fail_rc <name> <got> -- any non-zero exit
expect_fail_rc() {
  if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" "wanted a non-zero exit, got 0"; fi
}

section "index-audit: ORPHAN and NOENTRY"

# --- ORPHAN: an index entry naming a file that is not there ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF real.js        A file that exists\nF ghost.js       A file that does not\n' > "$d/lib/index.cld"
echo '// real' > "$d/lib/real.js"
stage "$d"
ia "$d" lib/index.cld
expect_hit  "ORPHAN fires on a missing target" "ORPHAN" "$out"
expect_hit  "ORPHAN names the offending entry and line" "lib/index.cld:3  entry 'ghost.js' names a missing target" "$out"
expect_rc   "ORPHAN blocks (exit 1)" 1 "$rc"
expect_miss "ORPHAN does not flag the real entry" "'real.js' names" "$out"
rm -rf "$d"

# --- NOENTRY: an indexable file with no entry in its dir index ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js       Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
ia "$d" lib/stray.js lib/known.js
expect_hit  "NOENTRY names the unindexed file and its index" "NOENTRY  lib/stray.js:-  no entry in lib/index.cld" "$out"
expect_rc   "NOENTRY blocks (exit 1)" 1 "$rc"
expect_miss "NOENTRY leaves the indexed file alone" "NOENTRY  lib/known.js" "$out"
ia "$d" lib/known.js
expect_hit  "an indexed file alone is clean" "index-audit: clean" "$out"
rm -rf "$d"

# --- a name containing a single space still resolves ---
d=$(fixture)
mkdir -p "$d/pages"
printf 'INDEX pages/\nF Tree Palette.html   A name with a space in it\n' > "$d/pages/index.cld"
echo '<p>x</p>' > "$d/pages/Tree Palette.html"
stage "$d"
ia "$d" pages/index.cld
expect_miss "a spaced filename is not an orphan" "ORPHAN" "$out"
expect_rc   "spaced filename passes (exit 0)" 0 "$rc"
printf 'INDEX pages/\nF Tree Palette.html A single space before the description\n' > "$d/pages/index.cld"
ia "$d" pages/index.cld
expect_hit  "a spaced name with a single space before its description resolves" "index-audit: clean" "$out"
printf 'INDEX pages/\nF Tree Palette.html   Here\nF Gone Palette.html   Not here\n' > "$d/pages/index.cld"
ia "$d" pages/index.cld
expect_hit  "control: a spaced name that is not there is an ORPHAN" "entry 'Gone Palette.html' names a missing target" "$out"
expect_miss "control: ...and the real spaced name is not" "'Tree Palette.html' names" "$out"
expect_rc   "control: spaced orphan blocks (exit 1)" 1 "$rc"
rm -rf "$d"

# --- a backslash in a name is a backslash (awk -v would read \t as a tab) ---
d=$(fixture)
mkdir -p "$d/lib"
printf '%s\n' 'INDEX lib/' 'F notes\today.js   A name with a backslash in it' > "$d/lib/index.cld"
echo '// n' > "$d/lib/notes\\today.js"
echo '// s' > "$d/lib/stray\\tab.js"
stage "$d"
ia "$d" "lib/notes\\today.js"
expect_miss "a backslash name with an entry is not NOENTRY" "NOENTRY" "$out"
expect_rc   "backslash name with an entry passes (exit 0)" 0 "$rc"
ia "$d" "lib/notes\\today.js" "lib/stray\\tab.js"
expect_hit  "control: a backslash name with no entry is NOENTRY" "NOENTRY  lib/stray\\tab.js:-" "$out"
expect_miss "control: ...and the indexed one is not" "NOENTRY  lib/notes" "$out"
rm -rf "$d"

# --- a last line with no newline is still an entry ---
d=$(fixture)
mkdir -p "$d/lib"
echo '// real' > "$d/lib/real.js"
printf 'INDEX lib/\nF real.js    Here\nF ghost.js   The last line, with no newline' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_hit "ORPHAN on a last line with no newline" "lib/index.cld:3  entry 'ghost.js' names" "$out"
expect_rc  "the unterminated orphan blocks (exit 1)" 1 "$rc"
printf 'INDEX lib/\nF real.js    Here, and no newline' > "$d/lib/index.cld"
ia "$d" lib/index.cld lib/real.js
expect_hit "control: an honest unterminated last line is clean" "index-audit: clean" "$out"
rm -rf "$d"

# --- a non-indexable extension never raises NOENTRY ---
d=$(fixture)
mkdir -p "$d/art"
printf 'INDEX art/\n' > "$d/art/index.cld"
printf 'PNG' > "$d/art/logo.png"
echo '// stray' > "$d/art/stray.js"
stage "$d"
ia "$d" art/logo.png
expect_miss "a binary asset does not raise NOENTRY" "NOENTRY" "$out"
expect_rc   "binary asset passes (exit 0)" 0 "$rc"
ia "$d" art/logo.png art/stray.js
expect_hit  "control: an indexable stray beside it does" "NOENTRY  art/stray.js" "$out"
expect_miss "control: ...and the binary still does not" "art/logo.png" "$out"
rm -rf "$d"

# --- cld.conf overrides the skip list ---
d=$(fixture)
mkdir -p "$d/third_party" "$d/lib"
printf 'CLD_SKIP_RE=%s\n' "'third_party/'" > "$d/cld.conf"
printf 'INDEX third_party/\n' > "$d/third_party/index.cld"
echo '// vendored' > "$d/third_party/vendored.js"
printf 'INDEX lib/\n' > "$d/lib/index.cld"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
ia "$d" third_party/vendored.js
expect_miss "cld.conf skip list suppresses NOENTRY" "NOENTRY" "$out"
expect_rc   "skipped tree passes (exit 0)" 0 "$rc"
ia "$d" third_party/vendored.js lib/stray.js
expect_hit  "control: an unskipped stray still raises NOENTRY" "NOENTRY  lib/stray.js" "$out"
expect_miss "control: ...and the skipped one still does not" "third_party/vendored.js" "$out"
rm -rf "$d"

# --- CLD_NOT_DIR_INDEX_RE: an index.cld in another format is no index ---
# Exempt from every check, membership included: a file beside it is not
# NOENTRY against a file that is not a directory index, and the directory
# is not NOINDEX (the name is taken), and its subdirectories are not
# NODENTRY against it.
d=$(fixture)
mkdir -p "$d/docs/sub" "$d/lib"
printf "CLD_NOT_DIR_INDEX_RE='docs/index\\\\.cld\$'\n" > "$d/cld.conf"
printf 'SESSIONS\nF notes.md   A session log line, not a directory entry\n' > "$d/docs/index.cld"
echo 'a' > "$d/docs/a.md"
echo 'c' > "$d/docs/sub/c.md"
printf 'INDEX docs/sub/\nF c.md   Here\n' > "$d/docs/sub/index.cld"
printf 'INDEX lib/\n' > "$d/lib/index.cld"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
ia "$d" docs/index.cld docs/a.md lib/stray.js
expect_miss "an exempt index.cld is not parsed (no ORPHAN)" "ORPHAN" "$out"
expect_miss "an exempt index.cld is not a membership list (no NOENTRY)" "NOENTRY  docs/a.md" "$out"
expect_hit  "control: a file beside a real index still raises NOENTRY" "NOENTRY  lib/stray.js" "$out"
ia "$d"
expect_miss "sweep: an exempt index.cld's directory is not NOINDEX" "NOINDEX  docs/" "$out"
expect_miss "sweep: no NODENTRY against an exempt index" "NODENTRY  docs/sub/" "$out"
expect_miss "sweep: no NOENTRY against an exempt index" "docs/a.md" "$out"
expect_hit  "control: the sweep still finds the real stray" "NOENTRY  lib/stray.js" "$out"
rm -rf "$d"

section "index-audit: the header"

# --- BADHDR warns, and the body is still checked ---
d=$(fixture)
mkdir -p "$d/lib"
echo '// real' > "$d/lib/real.js"
printf 'NOTANINDEX lib/\nF real.js    Here\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_hit  "BADHDR fires on a bad line 1" "BADHDR   lib/index.cld:1" "$out"
expect_rc   "BADHDR does not block (exit 0)" 0 "$rc"
expect_miss "BADHDR over an honest body: no ORPHAN" "ORPHAN" "$out"
printf 'NOTANINDEX lib/\nF real.js    Here\nF ghost.js   An orphan under a bad header\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "a bad line 1 does not switch off ORPHAN for the body" "lib/index.cld:3  entry 'ghost.js' names" "$out"
expect_hit  "...and BADHDR is still reported" "BADHDR" "$out"
expect_rc   "the orphan under a bad header blocks (exit 1)" 1 "$rc"
printf 'F ghost.js   The header is missing, so this is line 1\nF real.js    Here\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "a headerless index: line 1 is checked as an entry" "lib/index.cld:1  entry 'ghost.js' names" "$out"
expect_hit  "a headerless index is BADHDR" "BADHDR" "$out"
: > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "an empty index.cld is BADHDR" "BADHDR" "$out"
expect_rc   "an empty index.cld warns only (exit 0)" 0 "$rc"
rm -rf "$d"

# --- WRONGPATH: line 1 names another directory ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// a' > "$d/lib/a.js"
echo '// b' > "$d/lib/sub/b.js"
printf 'INDEX other/\nF a.js   Here\nD sub/   Here\n' > "$d/lib/index.cld"
printf 'INDEX lib/\nF b.js   Copied from lib/ and never fixed\n' > "$d/lib/sub/index.cld"
printf 'INDEX ./\nD lib/   Here\n' > "$d/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_hit  "WRONGPATH fires on a header naming another dir" "WRONGPATH  lib/index.cld:1  line 1 says 'INDEX other/' but this index sits in lib/" "$out"
expect_rc   "WRONGPATH warns, does not block (exit 0)" 0 "$rc"
ia "$d" lib/sub/index.cld
expect_hit  "WRONGPATH fires on a copied index" "this index sits in lib/sub/" "$out"
for h in 'lib/' 'lib' './lib/' 'lib//' 'lib/   '; do
  printf 'INDEX %s\nF a.js   Here\nD sub/   Here\n' "$h" > "$d/lib/index.cld"
  ia "$d" lib/index.cld
  expect_miss "header 'INDEX $h' at lib/ is the same directory" "WRONGPATH" "$out"
done
ia "$d" index.cld
expect_miss "the root form 'INDEX ./' is valid" "WRONGPATH" "$out"
expect_hit  "control: the root index is otherwise checked (clean)" "index-audit: clean" "$out"
printf 'INDEX .\nD lib/   Here\n' > "$d/index.cld"
ia "$d" index.cld
expect_miss "'INDEX .' at the root is valid too" "WRONGPATH" "$out"
for h in '/' 'lib/' '../'; do
  printf 'INDEX %s\nD lib/   Here\n' "$h" > "$d/index.cld"
  ia "$d" index.cld
  expect_hit "control: 'INDEX $h' at the root is WRONGPATH" "WRONGPATH  index.cld:1  line 1 says 'INDEX $h' but this index sits in ./" "$out"
done
printf 'INDEX \nF a.js   Here\nD sub/   Here\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "a header with no path is WRONGPATH" "line 1 names no directory; this index sits in lib/" "$out"
rm -rf "$d"

# --- CRLF line endings: reported once, and parsed with the CR stripped ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
echo '// s' > "$d/lib/spaced name.js"
echo '// b' > "$d/lib/sub/b.js"
printf 'INDEX lib/sub/\r\nF b.js\r\n' > "$d/lib/sub/index.cld"
printf 'INDEX lib/\r\nF real.js\r\nF spaced name.js   Described\r\nD sub/\r\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld lib/real.js "lib/spaced name.js"
expect_hit  "CRLF is reported, with the first line it is on" "CRLF     lib/index.cld:1  CRLF line endings" "$out"
expect_miss "CRLF: no nonsense ORPHAN" "ORPHAN" "$out"
expect_miss "CRLF: no nonsense NOENTRY" "NOENTRY" "$out"
expect_miss "CRLF: no nonsense WRONGPATH" "WRONGPATH" "$out"
expect_rc   "CRLF warns, does not block (exit 0)" 0 "$rc"
ia "$d" lib
expect_miss "CRLF: a sweep finds the D entry (no NODENTRY)" "NODENTRY" "$out"
expect_hit  "CRLF: a sweep reports both CRLF files" "lib/sub/index.cld:1  CRLF" "$out"
printf 'INDEX lib/\r\nF real.js\r\nF spaced name.js   Described\r\nD sub/\r\nF ghost.js\r\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "control: a real orphan in a CRLF file is named cleanly" "lib/index.cld:5  entry 'ghost.js' names a missing target" "$out"
expect_rc   "control: the CRLF orphan blocks (exit 1)" 1 "$rc"
printf 'INDEX lib/\nF real.js\nF spaced name.js   Described\nD sub/\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_miss "an LF file is not CRLF" "CRLF" "$out"
rm -rf "$d"

section "index-audit: type letters"

# --- a dangling symlink is NOT an orphan (the -e bug) ---
# -e follows the link, so before the -L arm was added a broken symlink
# read as absent and its entry was reported ORPHAN -- even though the
# link is present in the directory and the entry is telling the truth.
d=$(fixture)
mkdir -p "$d/lib"
ln -s nowhere.txt "$d/lib/dangling.link"
ln -s nowhere.js "$d/lib/broken.js"
printf 'INDEX lib/\nL dangling.link   Points at a target that is not there yet\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_miss "a dangling symlink is not an ORPHAN" "ORPHAN" "$out"
expect_rc   "dangling symlink does not block (exit 0)" 0 "$rc"
printf 'INDEX lib/\nL dangling.link   Here\nL gone.link   Not here at all\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit  "control: a link entry naming nothing is an ORPHAN" "entry 'gone.link' names a missing target" "$out"
expect_miss "control: ...and the dangling link still is not" "'dangling.link' names" "$out"
ia "$d" lib/broken.js
expect_hit  "a dangling symlink with an indexable name still needs an entry" "NOENTRY  lib/broken.js" "$out"
rm -rf "$d"

# --- L resolves, and F/D/L are told apart by the entry not the target ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF real.js      A regular file\nL alias.js     A symlink to real.js\nD sub/         A subdirectory\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_hit "F, L and D together are clean" "index-audit: clean" "$out"
expect_rc  "mixed type letters exit 0" 0 "$rc"
printf 'INDEX lib/\nF real.js      A regular file\nL alias.js     A symlink to real.js\nD sub/         A subdirectory\nD gone/        Not here\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld
expect_hit "control: a D entry naming nothing is an ORPHAN" "entry 'gone/' names a missing target" "$out"
rm -rf "$d"

# --- WRONGTYPE: the letter disagrees with the thing ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF sub/         Actually a directory\nF alias.js     Actually a symlink\nF real.js     Correct\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld
expect_hit  "WRONGTYPE fires on an F naming a directory" "WRONGTYPE" "$out"
expect_hit  "WRONGTYPE names the offending entry" "entry 'alias.js' is marked F" "$out"
expect_rc   "WRONGTYPE warns, does not block (exit 0)" 0 "$rc"
expect_miss "WRONGTYPE does not fire on the correct entry" "'real.js' is marked" "$out"
expect_hit  "WRONGTYPE names the type it actually is" "but is D (directory)" "$out"
expect_hit  "WRONGTYPE calls a symlink a symlink" "but is L (symlink)" "$out"
rm -rf "$d"

# --- the exotic letters parse and check ---
d=$(fixture)
mkdir -p "$d/dev"
mkfifo "$d/dev/pipe" 2>/dev/null
if [ -p "$d/dev/pipe" ]; then
  printf 'INDEX dev/\nP pipe        A named pipe\n' > "$d/dev/index.cld"
  ia "$d" dev/index.cld
  expect_hit "a P entry for a real fifo is clean" "index-audit: clean" "$out"
  expect_rc  "fifo entry exits 0" 0 "$rc"
  printf 'INDEX dev/\nF pipe        Wrongly called a regular file\n' > "$d/dev/index.cld"
  ia "$d" dev/index.cld
  expect_hit "control: WRONGTYPE fires on an F naming a fifo" "but is P (fifo)" "$out"
else
  echo "  SKIP  fifo cases (mkfifo unavailable)"
fi
rm -rf "$d"

section "index-audit: sweeps"

# --- a clean tree reports clean, however the directory is spelled ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF a.js       First\nF b.js       Second\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"; echo '// b' > "$d/lib/b.js"
stage "$d"
for spell in lib/ lib ./lib .; do
  ia "$d" "$spell"
  expect_hit "a clean dir says clean ('$spell')" "index-audit: clean" "$out"
  expect_rc  "clean dir exits 0 ('$spell')" 0 "$rc"
done
echo '// stray' > "$d/lib/stray.js"
stage "$d"
for spell in lib/ lib ./lib .; do
  ia "$d" "$spell"
  expect_hit "control: the same sweep finds a stray ('$spell')" "NOENTRY  lib/stray.js" "$out"
done
rm -rf "$d"

# --- a sweep that cannot list the files says so, and blocks ---
# The loop used to sit at the end of a pipe -- a subshell -- so a failed
# listing (or a crash part way) vanished and the run still said "clean".
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF a.js   Here\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"
stage "$d"
ia "$d"
expect_hit "control: the sweep is clean with a good git index" "index-audit: clean" "$out"
ia "$d" lib
expect_hit "control: the dir sweep is clean with a good git index" "index-audit: clean" "$out"
cp "$d/.git/index" "$d/.git/index.good"
printf 'garbage' > "$d/.git/index"
ia "$d"
expect_rc   "a failed listing: the sweep is a setup error (exit 2)" 2 "$rc"
expect_miss "a failed listing: the sweep does not say clean" "index-audit: clean" "$out"
expect_hit  "a failed listing: the sweep says why" "nothing was checked" "$out"
ia "$d" lib
expect_rc   "a failed listing: the dir sweep is a setup error (exit 2)" 2 "$rc"
expect_miss "a failed listing: the dir sweep does not say clean" "index-audit: clean" "$out"
ia "$d" lib/index.cld
expect_hit  "control: a file argument needs no listing, and runs" "index-audit: clean" "$out"
mv "$d/.git/index.good" "$d/.git/index"

# a crash in the middle of the loop: a stand-in awk that terminates the
# shell that ran it. In a pipe subshell only the subshell died.
shim=$(mktemp -d "$CLD_TEST_ROOT/shim.XXXXXX")
printf '#!/bin/sh\nkill -TERM "$PPID"\n' > "$shim/awk"
chmod +x "$shim/awk"
out=$(cd "$d" && TMPDIR="$CLD_TEST_ROOT" PATH="$shim:$PATH" $SH "$IA" 2>&1); rc=$?
expect_miss    "a crash part way through the sweep does not say clean" "index-audit: clean" "$out"
expect_fail_rc "a crash part way through the sweep exits non-zero" "$rc"
out=$(cd "$d" && TMPDIR="$CLD_TEST_ROOT" PATH="$shim:$PATH" $SH "$IA" lib 2>&1); rc=$?
expect_miss    "a crash part way through a dir sweep does not say clean" "index-audit: clean" "$out"
expect_fail_rc "a crash part way through a dir sweep exits non-zero" "$rc"
ia "$d" lib
expect_hit     "control: without the stand-in the same dir sweep is clean" "index-audit: clean" "$out"
rm -rf "$d" "$shim"

# --- the count is of the findings printed, after de-duplication ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF ghost.js   Not here\n' > "$d/lib/index.cld"
stage "$d"
ia "$d" lib/index.cld lib/index.cld
expect_hit "the same index named twice: one finding" "index-audit: 1 finding(s)" "$out"
ia "$d" lib lib/index.cld
expect_hit "an index both swept and named: one finding" "index-audit: 1 finding(s)" "$out"
printf 'INDEX lib/\nF ghost.js   Not here\nF ghost2.js  Not here either\n' > "$d/lib/index.cld"
ia "$d" lib/index.cld lib/index.cld
expect_hit "control: two different findings count two" "index-audit: 2 finding(s)" "$out"
rm -rf "$d"

# --- NOINDEX: a directory with indexable files and no index.cld ---
d=$(fixture)
mkdir -p "$d/lib/leaf" "$d/lib/art" "$d/node_modules/dep"
printf 'INDEX lib/\nF a.js     Here\nD leaf/    Indexed by its parent only\nD art/     Pictures only\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"
echo '// x' > "$d/lib/leaf/x.js"
printf 'PNG' > "$d/lib/art/logo.png"
echo '// dep' > "$d/node_modules/dep/dep.js"
stage "$d"
ia "$d"
expect_hit  "sweep: NOINDEX for a dir holding indexable files" "NOINDEX  lib/leaf/:-  holds indexable files but has no index.cld" "$out"
expect_rc   "NOINDEX warns, does not block (exit 0)" 0 "$rc"
expect_miss "sweep: no NOINDEX for a dir holding only non-indexable files" "lib/art/" "$out"
expect_miss "sweep: no NOINDEX for a skipped tree" "node_modules" "$out"
expect_miss "sweep: no NOINDEX for a dir that has one" "NOINDEX  lib/:-" "$out"
ia "$d" lib
expect_hit  "dir sweep: NOINDEX below the swept dir" "NOINDEX  lib/leaf/" "$out"
ia "$d" lib/leaf
expect_hit  "dir sweep: NOINDEX for the swept dir itself" "NOINDEX  lib/leaf/" "$out"
ia "$d" lib/leaf/x.js lib/index.cld
expect_miss "file arguments (the gate): no NOINDEX" "NOINDEX" "$out"
expect_hit  "file arguments (the gate): clean" "index-audit: clean" "$out"
printf 'INDEX lib/leaf/\nF x.js   Here\n' > "$d/lib/leaf/index.cld"
stage "$d"
ia "$d"
expect_miss "once the dir has an index.cld, no NOINDEX" "NOINDEX" "$out"
expect_hit  "control: ...and the sweep is clean" "index-audit: clean" "$out"
rm -rf "$d"

# --- NODENTRY: a subdirectory missing from its parent's index ---
d=$(fixture)
mkdir -p "$d/lib/sub/deeper" "$d/lib/assets" "$d/lib/vendor" "$d/lib/wrong"
printf 'INDEX lib/\nF a.js      Here\nF wrong/    The wrong letter\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"
printf 'INDEX lib/sub/\nF b.js   Here\n' > "$d/lib/sub/index.cld"
echo '// b' > "$d/lib/sub/b.js"
printf 'INDEX lib/sub/deeper/\nF c.js   Here\n' > "$d/lib/sub/deeper/index.cld"
echo '// c' > "$d/lib/sub/deeper/c.js"
printf 'PNG' > "$d/lib/assets/logo.png"
echo '// v' > "$d/lib/vendor/v.js"
printf 'INDEX lib/wrong/\nF w.js   Here\n' > "$d/lib/wrong/index.cld"
echo '// w' > "$d/lib/wrong/w.js"
stage "$d"
ia "$d"
expect_hit  "sweep: NODENTRY for a subdirectory with no entry" "NODENTRY  lib/sub/:-  no entry in lib/index.cld" "$out"
expect_hit  "sweep: NODENTRY two levels down" "NODENTRY  lib/sub/deeper/:-  no entry in lib/sub/index.cld" "$out"
expect_hit  "sweep: NODENTRY for a dir of non-indexable files too" "NODENTRY  lib/assets/" "$out"
expect_miss "sweep: no NODENTRY for a skipped tree" "lib/vendor" "$out"
expect_miss "sweep: an entry with the wrong letter is not NODENTRY" "NODENTRY  lib/wrong/" "$out"
expect_hit  "control: ...it is WRONGTYPE" "entry 'wrong/' is marked F but is D" "$out"
expect_rc   "NODENTRY warns, does not block (exit 0)" 0 "$rc"
ia "$d" lib/sub
expect_hit  "dir sweep: NODENTRY below the swept dir" "NODENTRY  lib/sub/deeper/" "$out"
expect_miss "dir sweep: the swept dir's own parent is not judged" "NODENTRY  lib/sub/:-" "$out"
ia "$d" lib/index.cld lib/sub/b.js
expect_miss "file arguments (the gate): no NODENTRY" "NODENTRY" "$out"
printf 'INDEX ./\nD scripts/   Here\n' > "$d/index.cld"
stage "$d"
ia "$d"
expect_hit  "sweep: NODENTRY against the root index" "NODENTRY  lib/:-  no entry in index.cld" "$out"
printf 'INDEX ./\nD scripts/   Here\nD lib/   Here\n' > "$d/index.cld"
printf 'INDEX lib/\nF a.js      Here\nD wrong/    Right letter now\nD sub/      Here\nD assets/   Pictures\n' > "$d/lib/index.cld"
printf 'INDEX lib/sub/\nF b.js   Here\nD deeper/   Here\n' > "$d/lib/sub/index.cld"
stage "$d"
ia "$d"
expect_miss "every subdirectory listed: no NODENTRY" "NODENTRY" "$out"
expect_hit  "control: ...and the sweep is clean" "index-audit: clean" "$out"
rm -rf "$d"

section "index-audit: --gone (deleted and renamed-away paths)"

d=$(fixture)
mkdir -p "$d/lib" "$d/other" "$d/pages"
printf 'INDEX lib/\nF a.js     Deleted, entry left behind\nF b.js     Still here\nF old.js   Someone else'"'"'s old orphan\n' > "$d/lib/index.cld"
echo '// b' > "$d/lib/b.js"
printf 'INDEX other/\nF elsewhere.js   An orphan in another index\n' > "$d/other/index.cld"
printf 'INDEX pages/\nF Tree Palette.html   Here\n' > "$d/pages/index.cld"
echo '<p>x</p>' > "$d/pages/Tree Palette.html"
printf 'INDEX ./\nF top.js   Deleted from the root\nD lib/     Here\nD other/   Here\nD pages/   Here\n' > "$d/index.cld"
stage "$d"

ia "$d" --gone lib/a.js
expect_hit  "--gone: the deleted file's entry is an ORPHAN" "lib/index.cld:2  entry 'a.js' names a missing target" "$out"
expect_rc   "--gone: the left-behind entry blocks (exit 1)" 1 "$rc"
expect_miss "--gone does not re-audit the rest of the index" "old.js" "$out"
expect_miss "--gone never turns into a sweep" "elsewhere.js" "$out"
ia "$d" lib/index.cld
expect_hit  "control: a full audit of that index does find the old orphan" "entry 'old.js' names" "$out"
ia "$d" --gone lib/c.js
expect_hit  "--gone: an honest deletion (no entry names it) is clean" "index-audit: clean" "$out"
expect_rc   "--gone: honest deletion exits 0" 0 "$rc"
ia "$d" --gone lib/b.js
expect_hit  "--gone: a path still there is not gone" "index-audit: clean" "$out"
ia "$d" --gone pages/Tree
expect_hit  "--gone: a word of a spaced name is not that name" "index-audit: clean" "$out"
rm "$d/pages/Tree Palette.html"
ia "$d" --gone "pages/Tree Palette.html"
expect_hit  "control: the spaced name itself, once gone, is an ORPHAN" "entry 'Tree Palette.html' names" "$out"
ia "$d" --gone ./lib//a.js
expect_hit  "--gone: the path is normalised" "entry 'a.js' names" "$out"

echo '// new' > "$d/lib/new.js"
ia "$d" lib/new.js --gone lib/a.js
expect_hit  "paths and --gone together: NOENTRY for the new name" "NOENTRY  lib/new.js" "$out"
expect_hit  "paths and --gone together: ORPHAN for the old one" "entry 'a.js' names" "$out"
ia "$d" lib/index.cld --gone lib/a.js
expect_hit  "an orphan found both ways counts once" "index-audit: 2 finding(s)" "$out"
ia "$d" index.cld --gone top.js
expect_hit  "--gone at the root: the root index is spelled index.cld" "index.cld:2  entry 'top.js' names" "$out"
expect_hit  "--gone at the root: ...and counts once with a full audit" "index-audit: 1 finding(s)" "$out"

# a directory renamed away: the parent's D entry for it
printf 'INDEX lib/\nF b.js     Still here\nD sub/     Renamed away\n' > "$d/lib/index.cld"
ia "$d" --gone lib/sub/x.js lib/sub/index.cld
expect_hit  "--gone: a vanished directory's D entry is an ORPHAN" "lib/index.cld:3  entry 'sub/' names a missing target" "$out"
expect_hit  "--gone: ...counted once for its two files" "index-audit: 1 finding(s)" "$out"
mkdir -p "$d/lib/sub"
echo '// y' > "$d/lib/sub/y.js"
ia "$d" --gone lib/sub/x.js
expect_miss "control: the directory still there is not reported" "'sub/'" "$out"
rm -rf "$d"

# --- --gone in a temp tree from the index (the gate's contract) ---
R=$(fixture)
R=$(cd "$R" && pwd -P)
mkdir -p "$R/lib"
printf 'INDEX lib/\nF a.js   Here\nF b.js   About to be deleted\n' > "$R/lib/index.cld"
echo '// a' > "$R/lib/a.js"
echo '// b' > "$R/lib/b.js"
stage "$R"
git -C "$R" commit -qm base >/dev/null 2>&1
git -C "$R" rm -q --cached lib/b.js
ia "$R" --gone lib/b.js
expect_hit "control: in the working tree b.js is still there" "index-audit: clean" "$out"
t=$(mktemp -d "$CLD_TEST_ROOT/staged.XXXXXX")
t=$(cd "$t" && pwd -P)
git -C "$R" checkout-index -a --prefix="$t/"
out=$(cd "$t" && GIT_DIR="$R/.git" GIT_WORK_TREE="$t" $SH "$IA" --gone lib/b.js 2>&1); rc=$?
expect_hit "staged tree: --gone sees the staged deletion" "lib/index.cld:3  entry 'b.js' names" "$out"
expect_rc  "staged tree: --gone blocks (exit 1)" 1 "$rc"
rm -rf "$R" "$t"

finish
