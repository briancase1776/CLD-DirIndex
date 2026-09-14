#!/bin/sh
# @brief Test suite for the directory-index checker: builds throwaway git
# fixtures and asserts that each finding code fires when it should and
# stays quiet when it should not.
#
# Usage: tests/run-tests.sh     (exit 0 = all pass, 1 = any failure)
#
# Each case makes a fresh temp repo, copies the toolkit in, writes a
# fixture tree, runs the checker, and matches the output. A checker that
# silently stops finding things is the failure mode that matters most --
# a gate that never blocks looks exactly like a clean repo.

set -u

TOOLKIT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# fixture -- print a fresh temp repo root with the toolkit installed.
fixture() {
  d=$(mktemp -d)
  mkdir -p "$d/scripts"
  cp -R "$TOOLKIT/scripts/index-audit" "$TOOLKIT/scripts/git-hooks" "$d/scripts/"
  cp "$TOOLKIT/scripts/cld-config.sh" "$d/scripts/"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  printf '%s' "$d"
}

# ok <name> <condition-description> -- record a pass
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

echo "index-audit"
echo "-----------"

# --- ORPHAN: an index entry naming a file that is not there ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'INDEX lib/\nF real.js        A file that exists\nF ghost.js       A file that does not\n' > "$d/lib/index.cld"
echo '// real' > "$d/lib/real.js"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
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
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/stray.js lib/known.js 2>&1); rc=$?
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
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh pages/index.cld 2>&1); rc=$?
expect_miss "a spaced filename is not an orphan" "ORPHAN" "$out"
expect_rc  "spaced filename passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- BADHDR warns but does not block, and does not parse the body ---
d=$(fixture)
mkdir -p "$d/lib"
printf 'NOTANINDEX lib/\nF ghost.js   would be an orphan if we parsed it\n' > "$d/lib/index.cld"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit  "BADHDR fires on a bad line 1" "BADHDR" "$out"
expect_rc   "BADHDR does not block (exit 0)" 0 "$rc"
expect_miss "BADHDR suppresses body parsing" "ORPHAN" "$out"
rm -rf "$d"

# --- a non-indexable extension never raises NOENTRY ---
d=$(fixture)
mkdir -p "$d/art"
printf 'INDEX art/\n' > "$d/art/index.cld"
printf 'PNG' > "$d/art/logo.png"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh art/logo.png 2>&1); rc=$?
expect_miss "a binary asset does not raise NOENTRY" "NOENTRY" "$out"
expect_rc   "binary asset passes (exit 0)" 0 "$rc"
rm -rf "$d"

# --- cld.conf overrides the skip list ---
d=$(fixture)
mkdir -p "$d/third_party"
printf 'CLD_SKIP_RE=%s\n' "'third_party/'" > "$d/cld.conf"
printf 'INDEX third_party/\n' > "$d/third_party/index.cld"
echo '// vendored' > "$d/third_party/vendored.js"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh third_party/vendored.js 2>&1); rc=$?
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
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_miss "a dangling symlink is not an ORPHAN" "ORPHAN" "$out"
expect_rc   "dangling symlink does not block (exit 0)" 0 "$rc"
rm -rf "$d"

# --- L resolves, and F/D/L are told apart by the entry not the target ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF real.js      A regular file\nL alias.js     A symlink to real.js\nD sub/         A subdirectory\n' > "$d/lib/index.cld"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
expect_hit "F, L and D together are clean" "index-audit: clean" "$out"
expect_rc  "mixed type letters exit 0" 0 "$rc"
rm -rf "$d"

# --- WRONGTYPE: the letter disagrees with the thing ---
d=$(fixture)
mkdir -p "$d/lib/sub"
echo '// real' > "$d/lib/real.js"
ln -s real.js "$d/lib/alias.js"
printf 'INDEX lib/\nF sub/         Actually a directory\nF alias.js     Actually a symlink\nF real.js     Correct\n' > "$d/lib/index.cld"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/index.cld 2>&1); rc=$?
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
  out=$(cd "$d" && sh scripts/index-audit/check.sh dev/index.cld 2>&1); rc=$?
  expect_hit "a P entry for a real fifo is clean" "index-audit: clean" "$out"
  expect_rc  "fifo entry exits 0" 0 "$rc"
  printf 'INDEX dev/\nF pipe        Wrongly called a regular file\n' > "$d/dev/index.cld"
  out=$(cd "$d" && sh scripts/index-audit/check.sh dev/index.cld 2>&1)
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
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/ 2>&1); rc=$?
expect_hit "a clean dir says clean" "index-audit: clean" "$out"
expect_rc  "clean dir exits 0" 0 "$rc"
rm -rf "$d"

echo ""
echo "shipped cld.conf"
echo "----------------"

# The repo ships a real cld.conf, not a sample: it is what a host repo
# copies, and this repo runs on it. These guard the two ways that goes
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

# ...and a fixture carrying the shipped conf verbatim still runs clean.
d=$(fixture)
cp "$TOOLKIT/cld.conf" "$d/cld.conf"
mkdir -p "$d/lib"
printf 'INDEX lib/\nF a.js       First\n' > "$d/lib/index.cld"
echo '// a' > "$d/lib/a.js"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && sh scripts/index-audit/check.sh lib/ 2>&1); rc=$?
expect_hit "a repo using the shipped conf verbatim is clean" "index-audit: clean" "$out"
expect_rc  "shipped conf exits 0 on a clean tree" 0 "$rc"
rm -rf "$d"

echo ""
echo "pre-commit gate"
echo "---------------"

# --- the installed hook actually blocks a real commit ---
d=$(fixture)
sh "$d/scripts/git-hooks/install.sh" >/dev/null 2>&1
mkdir -p "$d/lib"
printf 'INDEX lib/\nF known.js    Indexed\n' > "$d/lib/index.cld"
echo '// known' > "$d/lib/known.js"
echo '// stray' > "$d/lib/stray.js"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && git commit -m "unindexed file" 2>&1); rc=$?
expect_hit "the hook blocks a commit with an unindexed file" "NOENTRY" "$out"
expect_rc  "blocked commit exits non-zero" 1 "$rc"

# ...and lets it through once the index is honest
printf 'INDEX lib/\nF known.js    Indexed\nF stray.js    Now indexed too\n' > "$d/lib/index.cld"
git -C "$d" add -A >/dev/null 2>&1
out=$(cd "$d" && git commit -m "indexed" 2>&1); rc=$?
expect_rc "an honest index commits cleanly" 0 "$rc"
rm -rf "$d"

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
