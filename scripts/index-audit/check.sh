#!/bin/sh
# scripts/index-audit/check.sh
# @brief Mechanical directory-index freshness checker: an index.cld must
# still tell the truth about the directory it describes.
#
# Usage:
#   scripts/index-audit/check.sh f1 f2 ...   # check just these paths
#   scripts/index-audit/check.sh dir/        # sweep a directory
#   scripts/index-audit/check.sh             # whole project (git ls-files)
#
# The pre-commit hook passes the STAGED files as args -- surgical, "you
# touched X, is X's index still true?". Run it with no args for a health
# sweep of the whole tree.
#
# Exit code: 1 if any BLOCK-level finding, else 0. Warnings print but
# never set the exit code.
#
# Findings (mechanical, no LLM):
#   ORPHAN    [BLOCK] an index.cld entry names something that is not there
#   NOENTRY   [BLOCK] an indexable file has no entry in its dir's index.cld
#   BADHDR    [warn]  an index.cld line 1 is not "INDEX <path/>"
#   WRONGTYPE [warn]  the entry's type letter disagrees with what the
#                     thing actually is (an F naming a directory, an F
#                     naming a symlink, and so on)
#
# A dir with NO index.cld is silently allowed here: leaf dirs are often
# indexed by their PARENT, and warning on every such file would train the
# gate into noise. "This dir needs an index.cld" belongs in a deliberate
# sweep, not the staged gate.
#
# ORPHAN and NOENTRY both block. CLD_SKIP_RE (cld.conf) is the SINGLE
# place a "do not index this" decision is recorded -- if a file is not
# skipped, there is no legitimate reason it is missing from its dir's
# index.cld, so both directions of the same-commit rule are real
# violations, not judgment calls. BADHDR only warns: an odd header is
# not a lie about the directory's contents. (ORPHAN stays additionally
# safe because it cannot false-positive at all; NOENTRY is scoped to
# indexable extensions so binaries and assets never trip it.)
#
# KNOWN GAP: a bare `git rm` of a file whose index line you forgot to
# drop is not caught by the HOOK -- the pre-commit dispatcher passes only
# files that still exist, so a deletion never reaches this check as an
# arg. If you also staged that index.cld edit, its orphan IS caught; a
# pure deletion is caught only by the no-arg tree sweep.

set -u

CLD_REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null) || CLD_REPO=$(pwd)
. "$(dirname "$0")/../cld-config.sh"

OUT=$(mktemp)
BLOCK=$(mktemp)
trap 'rm -f "$OUT" "$BLOCK"' EXIT

note() {
  # note <RULE> <file> <line-or--> <message>
  printf '%-7s  %s:%s  %s\n' "$1" "$2" "$3" "$4" >> "$OUT"
}

block() {
  # block <RULE> <file> <line-or--> <message>  -- a finding that exits 1
  note "$@"
  printf 'x' >> "$BLOCK"
}

dir_of() {
  case "$1" in
    */*) printf '%s' "${1%/*}" ;;
    *)   printf '%s' "." ;;
  esac
}

base_of() {
  printf '%s' "${1##*/}"
}

ext_of() {
  b=$(base_of "$1")
  case "$b" in
    *.*) printf '%s' "${b##*.}" ;;
    *)   printf '%s' "" ;;
  esac
}

skipped() {
  printf '%s' "$1" | grep -q "$CLD_SKIP_RE"
}

# Every type letter the format defines -- find(1)'s -type codes,
# uppercased. Used both to recognise an entry line and to check it.
TYPE_LETTERS='FDLPSBC'

# entry_exists <path> -- is there a directory entry here at all?
# -e alone is WRONG: it follows the link, so a dangling symlink reads as
# absent and the entry describing it is reported ORPHAN. The link IS
# present in the directory and the entry is telling the truth; where it
# points is the target's problem. Hence the -L arm.
entry_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# describe_type <path> -- the letter the thing actually deserves.
# Ordered L first: -f and -d both follow a link, so a symlink would
# otherwise answer F. Same classification stat(1) gives from S_IFMT --
# verified identical across all seven types, broken links included --
# but test is a shell builtin and POSIX, where stat is neither. (stat
# is not in POSIX at all, and its -f flag means a format string on BSD
# and "filesystem status" on GNU, so a stat-based check does not fail
# loudly on the wrong box, it silently asks a different question.)
describe_type() {
  if   [ -L "$1" ]; then printf 'L (symlink)'
  elif [ -f "$1" ]; then printf 'F (regular file)'
  elif [ -d "$1" ]; then printf 'D (directory)'
  elif [ -p "$1" ]; then printf 'P (fifo)'
  elif [ -S "$1" ]; then printf 'S (socket)'
  elif [ -b "$1" ]; then printf 'B (block device)'
  elif [ -c "$1" ]; then printf 'C (character device)'
  else printf 'an unknown type'
  fi
}

# type_matches <letter> <path> -- does the thing match the letter?
# The letter describes the ENTRY, not its target, so F and D must
# exclude symlinks: -f and -d both follow a link, and without the -L
# guard a symlink to a file would satisfy F.
type_matches() {
  case "$1" in
    F) [ -f "$2" ] && [ ! -L "$2" ] ;;
    D) [ -d "$2" ] && [ ! -L "$2" ] ;;
    L) [ -L "$2" ] ;;
    P) [ -p "$2" ] ;;
    S) [ -S "$2" ] ;;
    B) [ -b "$2" ] ;;
    C) [ -c "$2" ] ;;
    *) return 0 ;;
  esac
}

is_indexable() {
  e=$(ext_of "$1")
  [ "$e" = "cld" ] && return 1
  for x in $CLD_INDEXABLE_EXTS; do
    [ "$e" = "$x" ] && return 0
  done
  return 1
}

# Orphan + header check of one index.cld: every F/D entry must resolve to
# a real file/dir in the index's own directory.
audit_index_file() {
  idx="$1"
  [ -f "$idx" ] || return 0
  if [ -n "$CLD_NOT_DIR_INDEX_RE" ]; then
    printf '%s' "$idx" | grep -q "$CLD_NOT_DIR_INDEX_RE" && return 0
  fi
  d=$(dir_of "$idx")

  # Line 1 must announce the index. If not, this is not a standard
  # directory index -- flag once and do NOT parse the body as entries
  # (a prose or foreign-format body would explode into false findings).
  hdr=$(head -n 1 "$idx")
  case "$hdr" in
    "INDEX "*) : ;;
    *) note BADHDR "$idx" 1 "line 1 is not 'INDEX <path/>'"; return 0 ;;
  esac

  # The entry name is a real file/dir path, so resolve it BY EXISTENCE
  # rather than by guessing where the description starts. Names may hold
  # single spaces ("Tree Palette.html"), the longest-name entry has only
  # a single space before its description, and files are only raggedly
  # aligned -- so no whitespace or column rule splits every case. Take
  # the text up to the first 2+-space gap, then try word-prefixes
  # longest-first; the name is the longest prefix that names something
  # that exists. Only if NO prefix exists is the entry an orphan. This
  # cannot false-positive: the true name is always one of the prefixes
  # tested, so a real file is always found.
  ln=0
  while IFS= read -r line; do
    ln=$((ln + 1))
    [ "$ln" -eq 1 ] && continue
    letter=${line%% *}
    case "$letter" in
      [FDLPSBC]) : ;;
      *) continue ;;
    esac
    case "$line" in
      "$letter "*) : ;;
      *) continue ;;
    esac
    rest=${line#? }
    chunk=${rest%%"  "*}
    cand=$chunk
    ok=0
    while [ -n "$cand" ]; do
      if entry_exists "$d/${cand%/}"; then ok=1; break; fi
      case "$cand" in
        *" "*) cand=${cand% *} ;;
        *)     cand="" ;;
      esac
    done
    if [ "$ok" -eq 1 ]; then
      # The entry resolves. Does its letter tell the truth about it?
      # A warning, not a block: the letter is a convention call (a
      # symlink is L, never the type of its target), and a repo adopting
      # the fuller alphabet should be told rather than stopped.
      type_matches "$letter" "$d/${cand%/}" || \
        note WRONGTYPE "$idx" "$ln" \
             "entry '$cand' is marked $letter but is $(describe_type "$d/${cand%/}")"
    else
      block ORPHAN "$idx" "$ln" "entry '$chunk' names a missing target"
    fi
  done < "$idx"
}

# Membership check of one ordinary file: an indexable file should have an
# entry in its directory's index.cld.
audit_member() {
  f="$1"
  # -f follows a link, so a dangling symlink would be skipped entirely
  # and never raise NOENTRY. It is still an entry in the directory.
  { [ -f "$f" ] || [ -L "$f" ]; } || return 0
  is_indexable "$f" || return 0
  base=$(base_of "$f")
  d=$(dir_of "$f")
  idx="$d/index.cld"

  # No index.cld here -- a leaf dir indexed by its parent. Silent in the
  # gate; a deliberate sweep owns that call.
  [ -f "$idx" ] || return 0

  # Match an F/D entry whose NAME field equals base. The name starts
  # right after "T " and ends at a space, a directory slash, or the line
  # end; base may itself contain single spaces, so compare by prefix plus
  # the boundary character (avoids the alignment-column ambiguity).
  if ! awk -v n="$base" -v types="$TYPE_LETTERS" '
        length($1) == 1 && index(types, $1) > 0 {
          rest = substr($0, 3)
          if (index(rest, n) == 1) {
            after = substr(rest, length(n) + 1, 1)
            if (after == "" || after == " " || after == "/") { found = 1 }
          }
        }
        END { exit !found }
      ' "$idx"; then
    block NOENTRY "$f" "-" "no entry in $idx"
  fi
}

process_file() {
  f="$1"
  skipped "$f" && return 0
  case "$(base_of "$f")" in
    index.cld) audit_index_file "$f" ;;
    *)         audit_member "$f" ;;
  esac
}

list_all_files() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git ls-files
  else
    find . -type f | sed 's,^\./,,'
  fi
}

process_path() {
  p="$1"
  if [ -d "$p" ]; then
    list_all_files | grep "^$p/\|^$p\$" | while IFS= read -r f; do
      process_file "$f"
    done
  else
    process_file "$p"
  fi
}

if [ "$#" -eq 0 ]; then
  list_all_files | while IFS= read -r f; do
    process_file "$f"
  done
else
  for t in "$@"; do
    process_path "$t"
  done
fi

count=$(wc -l < "$OUT" | tr -d ' ')
if [ "$count" -gt 0 ]; then
  sort -u "$OUT"
  echo ""
  echo "index-audit: $count finding(s)"
fi

if [ -s "$BLOCK" ]; then
  echo "index-audit: BLOCKED -- an index.cld is out of sync with its directory"
  exit 1
fi

[ "$count" -eq 0 ] && echo "index-audit: clean"
exit 0
