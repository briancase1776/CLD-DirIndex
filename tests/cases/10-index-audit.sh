#!/bin/sh
# tests/cases/10-index-audit.sh
# @brief Directory-index checker cases: each finding code (ORPHAN,
# NOENTRY, BADHDR, WRONGTYPE) fires when it should and stays quiet when
# it should not, over throwaway git fixtures.
#
# Run alone (sh tests/cases/10-index-audit.sh) or via tests/run-tests.sh.

. "$(dirname "$0")/../lib.sh"

section "index-audit"

# --- ORPHAN: an index entry naming a file that is not there ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF real.js        A file that exists\nF ghost.js       A file that does not\n' > "$d/lib/index.cld"
echo '// real' > "$d/lib/real.js"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit "ORPHAN fires on a missing target" "ORPHAN" "$out"
expect_hit "ORPHAN names the offending entry" "ghost.js" "$out"
expect_rc  "ORPHAN blocks (exit 1)" 1 "$rc"
expect_miss "ORPHAN does not flag the real entry" "real.js' names" "$out"
rm -rf "$d"

# --- NOENTRY: an indexable file with no entry in its dir index ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js       Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/stray.js lib/known.js 2>&1); rc=$?
expect_hit "NOENTRY fires on an unindexed file" "NOENTRY" "$out"
expect_hit "NOENTRY names the file" "stray.js" "$out"
expect_rc  "NOENTRY blocks (exit 1)" 1 "$rc"
expect_miss "NOENTRY leaves the indexed file alone" "known.js  -" "$out"
rm -rf "$d"

# --- a name containing a single space still resolves ---
d=$(fixture)
mkdir -p "$d/pages"
printf 'INDEX pages/\nF Tree Palette.html   A name with a space in it\n' > "$d/pages/index.cld"
echo '<p>x</p>' > "$d/pages/Tree Palette.html"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh pages/index.cld 2>&1); rc=$?
expect_miss "a spaced filename is not an orphan" "ORPHAN" "$out"
expect_rc  "spaced filename passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- BADHDR warns but does not block, and does not parse the body ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'NOTANINDEX lib/\nF ghost.js   would be an orphan if we parsed it\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit  "BADHDR fires on a bad line 1" "BADHDR" "$out"
expect_rc   "BADHDR does not block (exit 0)" 0 "$rc"
expect_miss "BADHDR suppresses body parsing" "ORPHAN" "$out"
rm -rf "$d"

# --- a non-indexable extension never raises NOENTRY ---
d=$(fixture)
mkdir -p "$d/art"
printf 'INDEX art/\n' > "$d/art/index.cld"
printf 'PNG' > "$d/art/logo.png"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh art/logo.png 2>&1); rc=$?
expect_miss "a binary asset does not raise NOENTRY" "NOENTRY" "$out"
expect_rc   "binary asset passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- cld.conf overrides the skip list ---
d=$(fixture)
mkdir -p "$d/third_party"
printf 'CLD_SKIP_RE=%s\n' "'third_party/'" > "$d/cld.conf"
printf 'INDEX third_party/\n' > "$d/third_party/index.cld"
echo '// vendored' > "$d/third_party/vendored.js"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh third_party/vendored.js 2>&1); rc=$?
expect_miss "cld.conf skip list suppresses NOENTRY" "NOENTRY" "$out"
expect_rc   "skipped tree passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- a dangling symlink is NOT an orphan (the -e bug) ---
# -e follows the link, so before the -L arm was added a broken symlink
# read as absent and its entry was reported ORPHAN -- even though the
# link is present in the directory and the entry is telling the truth.
d=$(fixture)
mkdir -p "$d/lib"
ln -s nowhere.txt "$d/lib/dangling.link"
printf 'INDEX lib/\nL dangling.link   Points at a target that is not there yet\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_miss "a dangling symlink is not an ORPHAN" "ORPHAN" "$out"
expect_rc   "dangling symlink does not block (exit 0)" 0 "$rc"
rm -rf "$d"

# --- L resolves, and F/D/L are told apart by the entry not the target ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF real.js      A regular file\nL alias.js     A symlink to real.js\nD sub/         A subdirectory\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit "F, L and D together are clean" "index-audit: clean" "$out"
expect_rc  "mixed type letters exit 0" 0 "$rc"
rm -rf "$d"

# --- WRONGTYPE: the letter disagrees with the thing ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF sub/         Actually a directory\nF alias.js     Actually a symlink\nF real.js     Correct\n' > "$d/lib/index.cld"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit  "WRONGTYPE fires on an F naming a directory" "WRONGTYPE" "$out"
expect_hit  "WRONGTYPE names the offending entry" "alias.js" "$out"
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
  out=$(cd "$d" && $SH scripts/index-audit/check.sh dev/index.cld 2>&1); rc=$?
  expect_hit "a P entry for a real fifo is clean" "index-audit: clean" "$out"
  expect_rc  "fifo entry exits 0" 0 "$rc"
  printf 'INDEX dev/\nF pipe        Wrongly called a regular file\n' > "$d/dev/index.cld"
  out=$(cd "$d" && $SH scripts/index-audit/check.sh dev/index.cld 2>&1)
  expect_hit "WRONGTYPE fires on an F naming a fifo" "WRONGTYPE" "$out"
else
  echo "  SKIP  fifo cases (mkfifo unavailable)"
fi
rm -rf "$d"

# --- a clean tree reports clean ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF a.js       First\nF b.js       Second\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"; echo '// b' > "$d/lib/b.js"
stage "$d"
out=$(cd "$d" && $SH scripts/index-audit/check.sh lib/ 2>&1); rc=$?
expect_hit "a clean dir says clean" "index-audit: clean" "$out"
expect_rc  "clean dir exits 0" 0 "$rc"
rm -rf "$d"

finish
