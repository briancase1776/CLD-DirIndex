#!/bin/sh
# scripts/index-audit/check.sh
# @brief Mechanical directory-index freshness checker: an index.cld must
# still tell the truth about the directory it describes.
#
# Usage:
#   scripts/index-audit/check.sh f1 f2 ...   # check just these paths
#   scripts/index-audit/check.sh dir/        # sweep a directory
#   scripts/index-audit/check.sh             # sweep the whole project
#   scripts/index-audit/check.sh [f1 ...] --gone g1 g2 ...
#                                            # g1 g2 ... were deleted or
#                                            # renamed away
#
# The pre-commit gate passes the STAGED paths as args -- surgical, "you
# touched X, is X's index still true?" -- and the paths the commit
# deletes or renames away after --gone. Run it with no args (or with a
# directory) for a health sweep. A directory argument may be spelled
# lib, lib/, ./lib or an absolute path; "." is the whole repo. Every
# path is relative to where you stand; the repo checked is the one you
# stand in.
#
# Exit code: 1 if any BLOCK-level finding; 2 if the check could not run
# (a setup error: no repo, a failed file listing); else 0. Warnings print
# but never set the exit code. Anything but 0 blocks a commit.
#
# Findings (mechanical, no LLM):
#   ORPHAN    [BLOCK] an index.cld entry names something that is not there
#   NOENTRY   [BLOCK] an indexable file has no entry in its dir's index.cld
#   BADHDR    [warn]  an index.cld line 1 is not "INDEX <path/>"
#   WRONGPATH [warn]  line 1 names a directory other than the one the
#                     index sits in ("INDEX ./" is the root's own form)
#   WRONGTYPE [warn]  the entry's type letter disagrees with what the
#                     thing actually is (an F naming a directory, an F
#                     naming a symlink, and so on)
#   CRLF      [warn]  the index has CRLF line endings; it is parsed with
#                     the CRs stripped, so the other findings still hold
#   NOINDEX   [warn]  sweep only: a directory holding indexable files has
#                     no index.cld
#   NODENTRY  [warn]  sweep only: a subdirectory holding tracked files has
#                     no entry in its parent's index.cld
#
# ORPHAN and NOENTRY both block. CLD_SKIP_RE (cld.conf) is the SINGLE
# place a "do not index this" decision is recorded -- if a file is not
# skipped, there is no legitimate reason it is missing from its dir's
# index.cld, so both directions of the same-commit rule are real
# violations, not judgment calls. The rest only warn: an odd header, a
# misfiled header, a convention letter or a line ending is not a lie
# about the directory's contents. (ORPHAN stays additionally safe because
# it cannot false-positive at all; NOENTRY is scoped to indexable
# extensions so binaries and assets never trip it.)
#
# A bad line 1 is reported, and the body is STILL checked: a missing or
# mistyped header must not switch off ORPHAN for every entry under it.
# If line 1 is not a header it may itself be an entry, so it is parsed
# as one. An index.cld in another format altogether is what
# CLD_NOT_DIR_INDEX_RE is for; such a file is not a directory index at
# all, so its directory counts as having none (no ORPHAN, no NOENTRY).
#
# A dir with NO index.cld is silently allowed when FILES are checked
# (the gate): leaf dirs are often indexed by their PARENT, and the gate
# must judge only what the commit touched. A sweep -- no argument, or a
# directory argument -- is the deliberate pass that owns the call "this
# dir needs an index.cld" (NOINDEX) and "this subdirectory is missing
# from its parent's index" (NODENTRY), and says so as warnings.
#
# --gone keeps a deletion narrow. For each gone path, the ONLY entries
# reported are those in its parent's index.cld that still name it (and,
# when the deletion emptied a directory away, those that still name the
# vanished directory, one level up at a time). A deletion never re-audits
# a whole index, so an honest commit is never blocked for someone else's
# old orphan elsewhere in the same file.

set -u

# The repo checked is the one the CALLER stands in (found from the
# current directory by cld-lib.sh), never the one this script lives in.
# cld_init leaves us at the repo root, and every path below is
# root-relative; arguments are translated with cld_arg.
CLD_HERE=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 2
. "$CLD_HERE/../cld-lib.sh"
cld_init
. "$CLD_HERE/../cld-config.sh"

WORK=$(mktemp -d) || cld_die "mktemp failed"
OUT=$WORK/out        # every finding, one line each, possibly repeated
BLOCK=$WORK/block    # non-empty once any finding blocks
LIST=$WORK/list      # the tracked files a sweep covers
: > "$OUT"
: > "$BLOCK"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CR=$(printf '\r')
TAB=$(printf '\t')

note() {
  # note <RULE> <file> <line-or--> <message>
  printf '%-7s  %s:%s  %s\n' "$1" "$2" "$3" "$4" >> "$OUT"
}

block() {
  # block <RULE> <file> <line-or--> <message>  -- a finding that exits 1
  note "$@"
  printf 'x' >> "$BLOCK"
}

# split_path <path> -- sets SP_DIR (its directory, "." at the root),
# SP_BASE (its last component) and SP_IDX (that directory's index.cld,
# spelled the way a listing spells it: "index.cld" at the root, never
# "./index.cld", so the same finding reached two ways prints as the same
# line). No subshell: a sweep runs this for every file it sees. Callers
# copy the results out at once; the next call overwrites them.
split_path() {
  case "$1" in
    */*) SP_DIR=${1%/*}; SP_IDX=$SP_DIR/index.cld ;;
    *)   SP_DIR=.;       SP_IDX=index.cld ;;
  esac
  SP_BASE=${1##*/}
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
  ii_b=${1##*/}
  case "$ii_b" in
    *.*) ii_e=${ii_b##*.} ;;
    *)   return 1 ;;
  esac
  [ "$ii_e" = "cld" ] && return 1
  for ii_x in $CLD_INDEXABLE_EXTS; do
    [ "$ii_e" = "$ii_x" ] && return 0
  done
  return 1
}

# is_dir_index <path> -- is this a directory index we should read? It
# must be a file, and not one CLD_NOT_DIR_INDEX_RE says is another format
# that only shares the name. Every check asks this one question, so an
# exempted file is exempt from all of them.
is_dir_index() {
  [ -f "$1" ] || return 1
  if [ -n "$CLD_NOT_DIR_INDEX_RE" ]; then
    printf '%s' "$1" | grep -q "$CLD_NOT_DIR_INDEX_RE" && return 1
  fi
  return 0
}

# has_entry <index> <name> -- does any entry's NAME field equal name?
# The name starts right after "T " and ends at a space, a directory
# slash, or the line end; name may itself contain single spaces, so
# compare by prefix plus the boundary character (avoids the
# alignment-column ambiguity). A trailing CR is ignored. The name goes
# in through the environment, not awk -v, which would read a backslash
# in it as an escape sequence.
has_entry() {
  HE_NAME=$2 HE_TYPES=$TYPE_LETTERS awk '
    BEGIN { n = ENVIRON["HE_NAME"]; types = ENVIRON["HE_TYPES"] }
    { sub(/\r$/, "") }
    length($1) == 1 && index(types, $1) > 0 {
      rest = substr($0, 3)
      if (index(rest, n) == 1) {
        after = substr(rest, length(n) + 1, 1)
        if (after == "" || after == " " || after == "/") { found = 1; exit }
      }
    }
    END { exit !found }
  ' "$1"
}

# parse_entry <line> -- is this line an entry? Sets PE_LETTER (the type
# letter) and PE_CHUNK (the text up to the first 2+-space gap: the name,
# perhaps followed by a single-spaced description).
parse_entry() {
  PE_LETTER=${1%% *}
  case "$PE_LETTER" in
    [FDLPSBC]) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    "$PE_LETTER "*) : ;;
    *) return 1 ;;
  esac
  pe_rest=${1#? }
  PE_CHUNK=${pe_rest%%"  "*}
  return 0
}

# resolve_entry <dir> <chunk> [name] -- which thing does the entry name?
# The entry name is a real file/dir path, so resolve it BY EXISTENCE
# rather than by guessing where the description starts. Names may hold
# single spaces ("Tree Palette.html"), the longest-name entry has only
# a single space before its description, and files are only raggedly
# aligned -- so no whitespace or column rule splits every case. Try the
# chunk's word-prefixes longest-first; the name is the longest prefix
# that names something that exists. Only if NO prefix exists is the
# entry an orphan. This cannot false-positive: the true name is always
# one of the prefixes tested, so a real file is always found.
# Sets RE_FOUND (the prefix that exists, or empty) and RE_NAMED (1 when
# an unresolved prefix tested equals name, with any trailing / dropped).
resolve_entry() {
  re_d=$1
  re_cand=$2
  RE_FOUND=
  RE_NAMED=0
  while [ -n "$re_cand" ]; do
    if entry_exists "$re_d/${re_cand%/}"; then RE_FOUND=$re_cand; return 0; fi
    [ "${re_cand%/}" = "${3-}" ] && RE_NAMED=1
    case "$re_cand" in
      *" "*) re_cand=${re_cand% *} ;;
      *)     re_cand= ;;
    esac
  done
  return 1
}

# check_header <index> <dir> <line-1> -- 0 if line 1 is a header (noting
# WRONGPATH when it names another directory), 1 if it is not (BADHDR).
# The path is compared after normalising both sides (cld_norm), so
# lib/, ./lib/ and lib are one directory and "INDEX ./" is the root.
check_header() {
  case "$3" in
    "INDEX "*) : ;;
    *) note BADHDR "$1" 1 "line 1 is not 'INDEX <path/>'"; return 1 ;;
  esac
  ch_p=${3#INDEX }
  while :; do
    case "$ch_p" in
      *" "|*"$TAB") ch_p=${ch_p%?} ;;
      *) break ;;
    esac
  done
  if [ "$2" = "." ]; then ch_want="./"; else ch_want="$2/"; fi
  if [ -z "$ch_p" ]; then
    note WRONGPATH "$1" 1 "line 1 names no directory; this index sits in $ch_want"
  elif [ "$(cld_norm "$ch_p")" != "$(cld_norm "$2")" ]; then
    note WRONGPATH "$1" 1 "line 1 says 'INDEX $ch_p' but this index sits in $ch_want"
  fi
  return 0
}

# Orphan, type and header check of one index.cld: every entry must
# resolve to a real thing in the index's own directory.
audit_index_file() {
  ai_idx=$1
  is_dir_index "$ai_idx" || return 0
  split_path "$ai_idx"
  ai_d=$SP_DIR
  ai_ln=0
  ai_cr=0
  # "|| [ -n ... ]": read fails on a last line with no newline, but has
  # still read it -- without this, that entry would never be checked.
  while IFS= read -r ai_line || [ -n "$ai_line" ]; do
    ai_ln=$((ai_ln + 1))
    case "$ai_line" in
      *"$CR")
        ai_line=${ai_line%"$CR"}
        [ "$ai_cr" -ne 0 ] || ai_cr=$ai_ln ;;
    esac
    if [ "$ai_ln" -eq 1 ]; then
      # A header is not an entry. A non-header line 1 is reported and
      # then parsed like any other line: it may be the first entry.
      check_header "$ai_idx" "$ai_d" "$ai_line" && continue
    fi
    parse_entry "$ai_line" || continue
    if resolve_entry "$ai_d" "$PE_CHUNK"; then
      # The entry resolves. Does its letter tell the truth about it?
      # A warning, not a block: the letter is a convention call (a
      # symlink is L, never the type of its target), and a repo adopting
      # the fuller alphabet should be told rather than stopped.
      type_matches "$PE_LETTER" "$ai_d/${RE_FOUND%/}" || \
        note WRONGTYPE "$ai_idx" "$ai_ln" \
             "entry '$RE_FOUND' is marked $PE_LETTER but is $(describe_type "$ai_d/${RE_FOUND%/}")"
    else
      block ORPHAN "$ai_idx" "$ai_ln" "entry '$PE_CHUNK' names a missing target"
    fi
  done < "$ai_idx"
  [ "$ai_ln" -gt 0 ] || note BADHDR "$ai_idx" 1 "line 1 is not 'INDEX <path/>' (the file is empty)"
  [ "$ai_cr" -eq 0 ] || \
    note CRLF "$ai_idx" "$ai_cr" "CRLF line endings; checked with the CRs stripped -- save it with LF endings"
}

# orphans_naming <index> <name> -- the --gone check: ORPHAN for the
# entries in this index that name <name> and no longer resolve, and for
# nothing else in the file. Same message as audit_index_file, so an
# orphan found both ways prints once.
orphans_naming() {
  on_idx=$1
  split_path "$on_idx"
  on_d=$SP_DIR
  on_ln=0
  while IFS= read -r on_line || [ -n "$on_line" ]; do
    on_ln=$((on_ln + 1))
    on_line=${on_line%"$CR"}
    if [ "$on_ln" -eq 1 ]; then
      case "$on_line" in "INDEX "*) continue ;; esac
    fi
    parse_entry "$on_line" || continue
    resolve_entry "$on_d" "$PE_CHUNK" "$2" && continue
    [ "$RE_NAMED" -eq 1 ] || continue
    block ORPHAN "$on_idx" "$on_ln" "entry '$PE_CHUNK' names a missing target"
  done < "$on_idx"
}

# gone_path <path> -- a path the caller says was deleted or renamed away.
# If it is really gone, its parent's index must not still name it; and
# if its directory went with it, the grandparent's index must not still
# name that directory, and so on up to the first directory still there.
gone_path() {
  go_g=$(cld_arg "$1")
  case "$go_g" in
    /*|..|../*|.) return 0 ;;   # outside the repo, or the repo itself
  esac
  skipped "$go_g" && return 0
  while [ "$go_g" != "." ]; do
    entry_exists "$go_g" && return 0
    split_path "$go_g"
    go_g=$SP_DIR
    go_base=$SP_BASE
    if is_dir_index "$SP_IDX"; then
      orphans_naming "$SP_IDX" "$go_base"
    fi
  done
}

# Membership check of one ordinary file: an indexable file should have an
# entry in its directory's index.cld.
audit_member() {
  am_f=$1
  # -f follows a link, so a dangling symlink would be skipped entirely
  # and never raise NOENTRY. It is still an entry in the directory.
  { [ -f "$am_f" ] || [ -L "$am_f" ]; } || return 0
  is_indexable "$am_f" || return 0
  split_path "$am_f"
  am_idx=$SP_IDX
  am_base=$SP_BASE

  # No directory index here -- a leaf dir indexed by its parent, or an
  # index.cld exempted as another format. Silent here; a sweep owns
  # the NOINDEX call.
  is_dir_index "$am_idx" || return 0

  has_entry "$am_idx" "$am_base" || \
    block NOENTRY "$am_f" "-" "no entry in $am_idx"
}

process_file() {
  skipped "$1" && return 0
  case "${1##*/}" in
    index.cld) audit_index_file "$1" ;;
    *)         audit_member "$1" ;;
  esac
}

# sweep_structure <root> -- the sweep-only warnings over the files in
# $LIST: NOINDEX for a directory at or below root that holds indexable
# files and has no index.cld; NODENTRY for a subdirectory holding any
# tracked, unskipped file that its parent's index.cld (the parent being
# at or below root) does not list.
sweep_structure() {
  ss_kept=$WORK/kept
  ss_dirs=$WORK/dirs
  grep -v "$CLD_SKIP_RE" "$LIST" > "$ss_kept"
  # 1 is "every path was skipped". Anything else means the pattern did
  # not work; skip nothing, as skipped() does when its grep fails.
  [ "$?" -le 1 ] || cp "$LIST" "$ss_kept"
  # One line per directory: "X<dir>" holds indexable files, "S<dir>" is
  # a subdirectory of an in-scope parent.
  SS_ROOT=$1 SS_EXTS=$CLD_INDEXABLE_EXTS awk '
    BEGIN {
      root = ENVIRON["SS_ROOT"]
      n = split(ENVIRON["SS_EXTS"], e, " ")
      for (i = 1; i <= n; i++) if (e[i] != "cld") ix[e[i]] = 1
    }
    function inscope(d) { return root == "." || d == root || index(d, root "/") == 1 }
    {
      k = split($0, c, "/")
      dir = "."
      for (i = 1; i < k; i++) {
        s = (dir == ".") ? c[i] : dir "/" c[i]
        if (!(s in seen_s) && inscope(dir)) { seen_s[s] = 1; print "S" s }
        dir = s
      }
      ext = c[k]
      if (index(ext, ".") > 0) { sub(/.*\./, "", ext) } else { ext = "" }
      if ((ext in ix) && !(dir in seen_x) && inscope(dir)) { seen_x[dir] = 1; print "X" dir }
    }
  ' "$ss_kept" > "$ss_dirs" || cld_die "could not work out the directory structure"
  while IFS= read -r ss_l <&3; do
    ss_d=${ss_l#?}
    case "$ss_l" in
      X*)
        [ -f "$ss_d/index.cld" ] || \
          note NOINDEX "$ss_d/" - "holds indexable files but has no index.cld" ;;
      S*)
        [ -d "$ss_d" ] || continue
        split_path "$ss_d"
        ss_pidx=$SP_IDX
        ss_base=$SP_BASE
        is_dir_index "$ss_pidx" || continue
        has_entry "$ss_pidx" "$ss_base" || \
          note NODENTRY "$ss_d/" - "no entry in $ss_pidx" ;;
    esac
  done 3< "$ss_dirs"
}

# sweep <dir> -- every tracked file at or below dir ("." is the whole
# repo), then the structure warnings. The listing goes to a file and the
# loop reads it in THIS shell: a loop at the end of a pipe runs in a
# subshell, where a failed listing or a crash part way would vanish and
# the run would still end "clean".
sweep() {
  cld_ls_under "$1" > "$LIST" || \
    cld_die "could not list the tracked files under $1 -- nothing was checked"
  while IFS= read -r sw_f <&3; do
    process_file "$sw_f"
  done 3< "$LIST"
  sweep_structure "$1"
}

# A directory argument is a git pathspec taken literally (cld_ls_under),
# so lib, lib/, ./lib and an absolute path all name the same tree and
# "." is the whole repo -- no regex is ever built from an argument.
process_path() {
  pp_p=$(cld_arg "$1")
  if [ -d "$pp_p" ] && [ ! -L "$pp_p" ]; then
    sweep "$pp_p"
  else
    process_file "$pp_p"
  fi
}

if [ "$#" -eq 0 ]; then
  sweep .
else
  gone=0
  for t in "$@"; do
    if [ "$gone" -eq 0 ] && [ "$t" = "--gone" ]; then
      gone=1
    elif [ "$gone" -eq 1 ]; then
      gone_path "$t"
    else
      process_path "$t"
    fi
  done
fi

# Count AFTER de-duplicating: the same finding reached twice (a file
# named twice, an index both staged and named by a deletion) is one
# finding, and the count must say what is printed.
count=0
if [ -s "$OUT" ]; then
  LC_ALL=C sort -u "$OUT" > "$WORK/sorted"
  count=$(wc -l < "$WORK/sorted" | tr -d ' ')
  cat "$WORK/sorted"
  echo ""
  echo "index-audit: $count finding(s)"
fi

if [ -s "$BLOCK" ]; then
  echo "index-audit: BLOCKED -- an index.cld is out of sync with its directory"
  exit 1
fi

[ "$count" -eq 0 ] && echo "index-audit: clean"
exit 0
