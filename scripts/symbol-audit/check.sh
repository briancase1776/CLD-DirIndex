#!/bin/sh
# scripts/symbol-audit/check.sh
# @brief Mechanical symbol-index checker: the per-file <file>.cld indexes
# (line 1 "FILE <path>") must not lie about their header, their target,
# or exist twice for one source.
#
# The symbol-side sibling of scripts/index-audit/check.sh. That one
# guards the DIRECTORY indexes (index.cld); this one guards the per-file
# SYMBOL indexes, which for a long time nothing read at all: index-audit
# excludes .cld from the indexable extensions by design, so a symbol
# index could lie about its header, its target, or exist twice for one
# source and no gate noticed. Four twin indexes in the source corpus
# (two naming conventions, one source file, minted 85 seconds apart)
# are the proof.
#
# Usage:
#   scripts/symbol-audit/check.sh f1 f2 ...   # check just these paths
#   scripts/symbol-audit/check.sh dir/        # sweep a directory
#   scripts/symbol-audit/check.sh             # whole project (git ls-files)
#
# The pre-commit hook passes the STAGED files as args -- surgical, "you
# touched X, is X still a truthful index?". Args that are neither a .cld
# nor a watched source extension are ignored, so passing a whole staged
# set is safe.
#
# Exit code: 1 if any BLOCK-level finding, else 0.
#
# Findings (mechanical, no LLM):
#   SYM-HDR  [BLOCK] a .cld whose line-1 token is not a known species.
#            FILE (symbol index) and INDEX (dir index) are built in;
#            add your own with CLD_EXTRA_SPECIES in cld.conf. An
#            unknown header makes the file invisible to every consumer
#            that selects on its species -- the find and dupecheck
#            skills both select on "^FILE ", so a symbol index with a
#            wrong header is indexed-but-unfindable.
#   SYM-DUP  [BLOCK] a checked FILE-species .cld whose target is also
#            claimed by ANOTHER tracked .cld -- two indexes for one
#            source rot independently (each write-through lands in
#            whichever twin the writer found first). Scoped to the
#            checked files: pre-existing twins block only when one of
#            them is touched (fix-what-you-touch), so the gate cannot
#            hold unrelated commits hostage.
#   SYM-DEAD [BLOCK] a checked FILE-species .cld whose target path
#            does not exist -- the index outlived (or never had) its
#            source. Keeps the corpus clean through renames and moves.
#   SYM-NAME [BLOCK] a checked FILE-species .cld not named
#            <target-basename>.cld -- the one-convention rule. Two
#            conventions is how the twins above were minted: neither
#            backfill pass could see the other's output because neither
#            looked under the other's name.
#   SYM-KEY  [BLOCK] an entry whose field 2 is not a usable lookup
#            key: a bare get/set/static/async (the real name slid to
#            field 3, so dupecheck answers FREE on a live symbol), an
#            unbalanced parenthesis, or a DUPLICATE field-2 within
#            the same index (the uniqueness the spec's qualification
#            rule exists to guarantee).
#   SYM-MISS [warn] a checked source file that declares a class or
#            function but has no <name>.cld beside it. Never blocks.
#
# DELIBERATELY NOT CHECKED: whether the TARGET's symbols carry doc
# comments. Documentation coverage is a fact about source, not about
# whether this index tells the truth -- an index checker that reads the
# index only to get a list of names to go inspect source with has
# stopped checking the index. The source repo's version did this
# (SYM-BRIEF) and it drowned every real finding 24:1, at a 100% false
# positive rate. `grep -L '@brief'` answers the coverage question
# better, and is not this tool's job.

set -u

CLD_REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || CLD_REPO=$(pwd)
. "$(dirname "$0")/../cld-config.sh"

repo="$CLD_REPO"
rc=0

BLOCK=$(mktemp)
trap 'rm -f "$BLOCK"' EXIT

ext_of() {
  b=${1##*/}
  case "$b" in
    *.*) printf '%s' "${b##*.}" ;;
    *)   printf '%s' "" ;;
  esac
}

# is_watched_source <path> -- true if its extension is in CLD_SYM_MISS_EXTS
is_watched_source() {
  e=$(ext_of "$1")
  for x in $CLD_SYM_MISS_EXTS; do
    [ "$e" = "$x" ] && return 0
  done
  return 1
}

# Build the lists of .cld (checks) and source files (SYM-MISS) from the
# args (or sweep).
files=""
src_files=""
if [ "$#" -eq 0 ]; then
  files=$(git -C "$repo" ls-files "*.cld")
  for x in $CLD_SYM_MISS_EXTS; do
    src_files="$src_files
$(git -C "$repo" ls-files "*.$x")"
  done
else
  for arg in "$@"; do
    if [ -d "$arg" ]; then
      files="$files
$(git -C "$repo" ls-files "$arg" | grep '\.cld$')"
      for x in $CLD_SYM_MISS_EXTS; do
        src_files="$src_files
$(git -C "$repo" ls-files "$arg" | grep "\\.$x\$")"
      done
    else
      case "$arg" in
        *.cld) files="$files
$arg" ;;
        *) is_watched_source "$arg" && src_files="$src_files
$arg" ;;
      esac
    fi
  done
fi
src_files=$(printf '%s\n' "$src_files" | grep -v '^$')
# An empty skip regex would make `grep -v` match every line and drop the
# whole list, so only filter when there is something to filter on.
if [ -n "$CLD_SYM_MISS_SKIP_RE" ]; then
  src_files=$(printf '%s\n' "$src_files" | grep -v "$CLD_SYM_MISS_SKIP_RE")
fi

# Map of every tracked FILE-species index target, for SYM-DUP:
# "<target><TAB><index-path>" per line.
all_targets=$(git -C "$repo" ls-files "*.cld" | grep -v "$CLD_SKIP_RE" |
  while IFS= read -r c; do
    h=$(head -n 1 "$repo/$c" 2>/dev/null)
    case "$h" in
      "FILE "*) printf '%s\t%s\n' "${h#FILE }" "$c" ;;
    esac
  done)

echo "$files" | grep -v '^$' | grep -v "$CLD_SKIP_RE" | sort -u |
while IFS= read -r f; do
  [ -f "$repo/$f" ] || continue
  if [ -n "$CLD_NOT_SYMBOL_INDEX_RE" ]; then
    printf '%s' "$f" | grep -q "$CLD_NOT_SYMBOL_INDEX_RE" && continue
  fi
  head1=$(head -n 1 "$repo/$f" 2>/dev/null)
  tok=${head1%% *}

  known=0
  [ "$tok" = "FILE" ] && known=1
  [ "$tok" = "INDEX" ] && known=1
  for s in $CLD_EXTRA_SPECIES; do
    [ "$tok" = "$s" ] && known=1
  done

  if [ "$tok" = "FILE" ]; then
      target=${head1#FILE }
      if [ ! -f "$repo/$target" ]; then
        echo "SYM-DEAD $f: target does not exist: $target"
        printf 'x' >> "$BLOCK"
      fi
      want="$(basename "$target").cld"
      if [ "$(basename "$f")" != "$want" ]; then
        echo "SYM-NAME $f: expected $(dirname "$f")/$want" \
             "(named <target-basename>.cld, extension included)"
        printf 'x' >> "$BLOCK"
      fi
      others=$(printf '%s\n' "$all_targets" |
        awk -F'\t' -v t="$target" -v me="$f" '$1==t && $2!=me {print $2}')
      if [ -n "$others" ]; then
        echo "SYM-DUP  $f: target $target also claimed by:" $others
        printf 'x' >> "$BLOCK"
      fi
      awk -v f="$f" '
        $1 ~ /^[A-Z]$/ {
          if ($2 ~ /^(get|set|static|async)$/) {
            print "SYM-KEY  " f " line " NR ": field 2 is the keyword" \
                  " " $2 ", not the symbol name"
            bad = 1
          }
          par = $2; no = gsub(/\(/, "(", par); nc = gsub(/\)/, ")", par)
          if (no != nc) {
            print "SYM-KEY  " f " line " NR ": unbalanced parenthesis" \
                  " in name " $2
            bad = 1
          }
          if (seen[$2]++) {
            print "SYM-KEY  " f " line " NR ": duplicate key " $2 \
                  " -- qualify as Owner.name"
            bad = 1
          }
        }
        END { exit bad }
      ' "$repo/$f" || printf 'x' >> "$BLOCK"

  elif [ "$known" -eq 0 ]; then
      echo "SYM-HDR  $f: unknown line-1 token '$tok'" \
           "(expected FILE <path> for a symbol index)"
      printf 'x' >> "$BLOCK"
  fi
done

# SYM-MISS (warn only): a declaring source file with no symbol index.
echo "$src_files" | grep -v '^$' | grep -v "$CLD_SKIP_RE" | sort -u |
while IFS= read -r j; do
  [ -f "$repo/$j" ] || continue
  [ -f "$repo/$j.cld" ] && continue
  if grep -qE "$CLD_DECL_RE" "$repo/$j"; then
    echo "SYM-MISS (warn) $j: declares symbols but has no $j.cld"
  fi
done

# The while loops above run in a subshell (pipe), so findings signal
# through a marker file rather than a variable.
if [ -s "$BLOCK" ]; then
  echo "symbol-audit: BLOCKED -- a symbol index is lying about its" \
       "header, its target, its name, or its keys"
  rc=1
else
  echo "symbol-audit: clean"
fi

exit $rc
