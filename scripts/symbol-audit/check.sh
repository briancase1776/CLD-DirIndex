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
#   scripts/symbol-audit/check.sh [f1 ...] --gone p1 p2 ...
#
# The pre-commit hook passes the STAGED files as args -- surgical, "you
# touched X, is X still a truthful index?". Args that are neither a .cld
# nor a watched source are ignored, so passing a whole staged set is
# safe. Every arg after --gone is a path the commit deleted or renamed
# away: the only question asked about it is "is <path>.cld, beside it,
# still here?" (SYM-DEAD). Nothing else is re-audited because of a
# deletion, and --gone alone never turns into a sweep.
#
# Which .cld files are symbol indexes at all is decided in one place,
# scripts/cld-symbol.sh: never an index.cld (that is index-audit's, bad
# line 1 included), nothing CLD_NOT_DIR_INDEX_RE, CLD_NOT_SYMBOL_INDEX_RE
# or CLD_SKIP_RE names -- for the checked files and for the SYM-DUP map
# alike.
#
# Exit code: 1 if any BLOCK-level finding, 2 if the check could not run
# (a setup error: the gate blocks on that too) or an argument named
# nothing to check (a path that is not there, a directory with no tracked
# file under it) -- a check that looked at nothing never says "clean";
# else 0. Warnings print but never set the exit code.
#
# Findings (mechanical, no LLM):
#   SYM-HDR   [BLOCK] a .cld whose line-1 token is not a known species.
#             FILE (symbol index) and INDEX (dir index) are built in;
#             add your own with CLD_EXTRA_SPECIES in cld.conf. An
#             unknown header makes the file invisible to every consumer
#             that selects on its species -- the lookups select on
#             "^FILE ", so a symbol index with a wrong header is
#             indexed-but-unfindable.
#   SYM-DUP   [BLOCK] a checked FILE-species .cld whose target is also
#             claimed by ANOTHER tracked .cld -- two indexes for one
#             source rot independently. Targets are compared in one
#             spelling (./x, x//y and x/ are x, x/y and x). Scoped to the
#             checked files: pre-existing twins block only when one of
#             them is touched (fix-what-you-touch), so the gate cannot
#             hold unrelated commits hostage. A tracked .cld that is not
#             in the work tree (deleted there, or left out of a gate's
#             temp tree) is read from the git index, where it still is.
#   SYM-DEAD  [BLOCK] a checked FILE-species .cld whose target path does
#             not exist -- the index outlived (or never had) its source;
#             or, for a --gone path, a <path>.cld still beside it.
#   SYM-NAME  [BLOCK] a checked FILE-species .cld that is not
#             <target>.cld: named after its target, extension included,
#             and in the target's own directory -- the one-convention
#             rule. Two conventions is how the twins above were minted:
#             neither backfill pass could see the other's output because
#             neither looked under the other's name.
#   SYM-KEY   [BLOCK] an entry whose field 2 is not a usable lookup key:
#             in a js index, a bare get/set/static/async (the real name
#             slid to field 3, so dupecheck answers FREE on a live
#             symbol); an unbalanced parenthesis; or a DUPLICATE field 2
#             within the same index (the uniqueness the spec's
#             qualification rule exists to guarantee). I entries are
#             dependencies, not symbols: their keys are unique among
#             themselves and never clash with a symbol's.
#   SYM-CRLF  [warn]  the index has CR-LF line endings. Every line is
#             read with the CR removed, so the findings stay about the
#             content, not the line endings.
#   SYM-STALE [warn]  an entry whose name does not occur in the target
#             (fixed-string match): the last component of the name (the
#             part after the last "."), or, for an I entry, the module
#             or path token exactly as written. R placeholders like
#             (error-listener) name nothing and are skipped.
#   SYM-MISS  [warn]  a checked source file that declares a class or
#             function but has no <name>.cld beside it, for each
#             language in CLD_SYM_MISS_LANGS (js by default). Never
#             blocks.
#
# Language (js, sh, bash, py) is decided by cld_lang_of in
# scripts/cld-symbol.sh: a "lang <name>" header line, the #! line, the
# extension (CLD_LANG_EXT_MAP), then file(1).
#
# DELIBERATELY NOT CHECKED: whether the TARGET's symbols carry doc
# comments. Documentation coverage is a fact about source, not about
# whether this index tells the truth -- an index checker that reads the
# index only to get a list of names to go inspect source with has
# stopped checking the index. The source repo's version did this
# (SYM-BRIEF) and it drowned every real finding 24:1, at a 100% false
# positive rate. `grep -L '@brief'` answers the coverage question
# better, and is not this tool's job. (SYM-STALE is the other direction:
# it asks whether a name the INDEX claims is still in the source.)
#
# Nor which type letters a language may use: that is deferred.

set -u

# The repo checked is the one the CALLER stands in (found from the
# current directory by cld-lib.sh), never the one this script lives in.
# cld_init leaves us at the repo root, and every path below is
# root-relative; arguments are translated with cld_arg.
CLD_HERE=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 2
. "$CLD_HERE/../cld-lib.sh"
cld_init
. "$CLD_HERE/../cld-config.sh"
. "$CLD_HERE/../cld-symbol.sh"

W=$(mktemp -d) || cld_die "cannot make a temp directory"
trap 'rm -rf "$W"' EXIT
trap 'exit 2' HUP INT TERM

CR=$CLD_SYM_CR
US=$CLD_SYM_US
blocked=0
unchecked=0

# not_checked <message> -- an argument that named nothing to check. Said
# at once, and the run exits 2 instead of ever reporting clean.
not_checked() {
  echo "symbol-audit: $1 -- nothing was checked there"
  unchecked=1
}

# put <file> <line> -- append one line to a work file, or stop.
put() {
  printf '%s\n' "$2" >> "$1" || cld_die "cannot write $1 (out of temp space?)"
}

# grep_l <ERE> <list> <out> <what> -- append to <out> every file in <list>
# holding a match, as ./path or /path: one grep -l per hundred files,
# never one per file. A grep error is a setup error, named by <what>.
grep_l() {
  _gl_re=$1; _gl_in=$2; _gl_out=$3; _gl_what=$4
  set --
  while IFS= read -r _gl_f <&5; do
    case $_gl_f in /*) : ;; *) _gl_f=./$_gl_f ;; esac
    set -- "$@" "$_gl_f"
    if [ "$#" -ge 100 ]; then _grep_l_run "$@"; set --; fi
  done 5< "$_gl_in"
  [ "$#" -eq 0 ] || _grep_l_run "$@"
}
_grep_l_run() {
  grep -l -E -e "$_gl_re" "$@" >> "$_gl_out"
  [ "$?" -le 1 ] || cld_die "grep failed with $_gl_what"
}

# Every loop below reads its list from a file on fd 3 and runs in THIS
# shell, never at the end of a pipe: a crash inside the loop (set -u, a
# failed command that calls cld_die) has to stop the script with a
# non-zero exit, not leave a subshell behind and print "clean".

# pick <out> <grep args...> -- append grep's matches to <out>; "no
# match" is fine, a grep error is a setup error.
pick() {
  _o=$1; shift
  grep "$@" >> "$_o"
  [ "$?" -le 1 ] || cld_die "grep failed: $*"
}

# --- What SYM-MISS watches ---------------------------------------------
# js: the files whose extension is in CLD_SYM_MISS_EXTS, CLD_DECL_RE as
# the declaration test (unchanged defaults). py, sh, bash: files of that
# language, with the patterns below.
miss_js=0
miss_other=
for _l in $CLD_SYM_MISS_LANGS; do
  case "$_l" in
    js) miss_js=1 ;;
    py|sh|bash) miss_other="$miss_other $_l" ;;
  esac
done

# decl_re <lang> -- the ERE that counts as a declaration in <lang>
decl_re() {
  case "$1" in
    py)   printf '%s' '^(async )?def |^class ' ;;
    bash) printf '%s' '^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_:.-]*|^[[:space:]]*[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)' ;;
    sh)   printf '%s' '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' ;;
  esac
}

# --- Arguments ---------------------------------------------------------
: > "$W/listed"   # tracked files under a dir argument (or the sweep)
: > "$W/named"    # explicit file arguments
: > "$W/gone"     # --gone paths
if [ "$#" -eq 0 ]; then
  cld_ls_files > "$W/listed" || cld_die "cannot list tracked files"
  [ -s "$W/listed" ] || not_checked "no file here is tracked"
else
  gone_mode=0
  for arg in "$@"; do
    if [ "$gone_mode" -eq 0 ] && [ "$arg" = "--gone" ]; then
      gone_mode=1
      continue
    fi
    cld_arg_v "$arg"
    p=$CLD_ARG
    if [ "$gone_mode" -eq 1 ]; then
      put "$W/gone" "$p"
    elif [ -d "$p" ] && [ ! -L "$p" ]; then
      # A directory argument is a literal git pathspec (cld_ls_under), so
      # lib, lib/, ./lib and an absolute path name the same tree. A
      # symlink to a directory is an entry, not a tree to sweep (the same
      # rule as index-audit); git lists only the link itself either way.
      cld_ls_under "$p" > "$W/dir" ||
        cld_die "cannot list tracked files under $p"
      if [ -s "$W/dir" ]; then
        cat "$W/dir" >> "$W/listed" || cld_die "cannot write $W/listed"
      else
        not_checked "no file under $p/ is tracked (git add it first)"
      fi
    elif [ -e "$p" ] || [ -L "$p" ]; then
      put "$W/named" "$p"
    else
      not_checked "nothing at $arg (a deleted path goes after --gone)"
    fi
  done
fi

# The .cld files to check, and the sources SYM-MISS looks at.
: > "$W/cld"
: > "$W/src"
# (one file per grep: with two, grep prefixes each line with its name)
pick "$W/cld" -e '\.cld$' "$W/listed"
pick "$W/cld" -e '\.cld$' "$W/named"
grep -v -e '\.cld$' "$W/named" >> "$W/src"
[ "$?" -le 1 ] || cld_die "cannot split the arguments"
if [ "$miss_js" -eq 1 ]; then
  for x in $CLD_SYM_MISS_EXTS; do
    pick "$W/src" -e "\\.$x\$" "$W/listed"
  done
fi
if [ -n "$miss_other" ]; then
  # A sweep reads the #! line only of files that could be in one of
  # these languages: an extension mapped to a non-js language, or none.
  for _p in $CLD_LANG_EXT_MAP; do
    [ "${_p#*:}" = js ] || pick "$W/src" -e "\\.${_p%%:*}\$" "$W/listed"
  done
  pick "$W/src" -v -e '\.[^/]*$' "$W/listed"
fi
sort -u "$W/cld" > "$W/cld.s" && mv "$W/cld.s" "$W/cld" ||
  cld_die "cannot sort the file list"
cld_sym_keep "$W/cld"
sort -u "$W/src" > "$W/src.s" && mv "$W/src.s" "$W/src" ||
  cld_die "cannot sort the file list"
_cls_drop '^$' "$W/src"
_cls_drop "$CLD_SKIP_RE" "$W/src"
_cls_drop "$CLD_SYM_MISS_SKIP_RE" "$W/src"

# --- The checked indexes -----------------------------------------------
: > "$W/claims"   # "<target><US><index>" for every checked FILE index
while IFS= read -r f <&3; do
  [ -f "$f" ] || continue
  head1=
  { IFS= read -r head1 || :; } < "$f"
  head1=${head1%"$CR"}

  case "$head1" in
    "FILE "*|FILE) : ;;
    *)
      tok=${head1%% *}
      known=0
      [ "$tok" = "INDEX" ] && known=1
      for s in $CLD_EXTRA_SPECIES; do
        [ "$tok" = "$s" ] && known=1
      done
      if [ "$known" -eq 0 ]; then
        echo "SYM-HDR  $f: unknown line-1 token '$tok'" \
             "(expected FILE <path> for a symbol index)"
        blocked=1
      fi
      continue ;;
  esac

  raw=${head1#FILE}
  raw=${raw# }
  if [ -z "$raw" ]; then
    echo "SYM-DEAD $f: line 1 names no target (expected FILE <path>)"
    blocked=1
    continue
  fi
  cld_sym_norm "$raw"; target=$CLD_SYM_N
  if [ ! -f "$target" ]; then
    echo "SYM-DEAD $f: target does not exist: $target"
    blocked=1
  fi
  cld_sym_norm "$target.cld"; want=$CLD_SYM_N
  cld_sym_norm "$f"
  if [ "$CLD_SYM_N" != "$want" ]; then
    echo "SYM-NAME $f: expected $want" \
         "(named <target>.cld, extension included, beside its target)"
    blocked=1
  fi
  printf '%s%s%s\n' "$target" "$US" "$f" >> "$W/claims"

  readable=
  [ -f "$target" ] && [ -r "$target" ] && readable=$target
  # A bare get/set/static/async key is only a finding in a js index, and
  # the language costs a lookup (cld_lang_of), so awk just notes those
  # keys in $W/acc and the language is asked for only when there is one.
  : > "$W/acc"
  CLD_SA_F=$f CLD_SA_T=$readable CLD_SA_ACC="$W/acc" awk '
    function dot(p) { return (p ~ /^\//) ? p : "./" p }
    BEGIN { f = ENVIRON["CLD_SA_F"]; t = ENVIRON["CLD_SA_T"]; acc = ENVIRON["CLD_SA_ACC"]
            bad = 0; ncr = 0; n = 0 }
    { if (sub(/\r$/, "")) ncr++ }
    FNR == 1 { next }
    $1 ~ /^[A-Z]$/ {
      k = $2
      if ($1 != "I" && k ~ /^(get|set|static|async)$/) print FNR " " k > acc
      par = k; no = gsub(/\(/, "(", par); nc = gsub(/\)/, ")", par)
      if (no != nc) {
        print "SYM-KEY  " f " line " FNR ": unbalanced parenthesis in name " k
        bad = 1
      }
      if (seen[($1 == "I" ? "I " : "") k]++) {
        print "SYM-KEY  " f " line " FNR ": duplicate key " k " -- qualify as Owner.name"
        bad = 1
      }
      # What SYM-STALE looks for in the target.
      nd = k
      if ($1 != "I" && match(k, /\.[^.]+$/)) nd = substr(k, RSTART + 1)
      if (nd != "" && nd !~ /^\(.*\)$/) { n++; need[n] = nd; name[n] = k; at[n] = FNR }
    }
    END {
      if (ncr)
        print "SYM-CRLF (warn) " f ": " ncr " line(s) end in CR-LF; read with the CR" \
              " removed -- convert the file to LF line endings"
      if (n && t != "") {
        t2 = dot(t); left = n
        while (left > 0 && (r = (getline l < t2)) > 0)
          for (i = 1; i <= n; i++)
            if (!(i in hit) && index(l, need[i])) { hit[i] = 1; left-- }
        close(t2)
        if (r >= 0)
          for (i = 1; i <= n; i++)
            if (!(i in hit))
              print "SYM-STALE (warn) " f " line " at[i] ": " need[i] \
                    (need[i] == name[i] ? "" : " (of " name[i] ")") \
                    " does not occur in " t " -- renamed or removed?"
      }
      close(acc)
      exit bad
    }' "./$f" </dev/null
  case $? in
    0) : ;;
    1) blocked=1 ;;
    *) cld_die "awk failed reading $f" ;;
  esac
  if [ -s "$W/acc" ] && [ "$(cld_lang_of "$target" "$f")" = js ]; then
    while read -r n k <&4; do
      echo "SYM-KEY  $f line $n: field 2 is the keyword $k, not the symbol name"
    done 4< "$W/acc"
    blocked=1
  fi
done 3< "$W/cld"

# --- SYM-DUP: one pass over every tracked symbol index ------------------
if [ -s "$W/claims" ]; then
  if [ "$#" -eq 0 ]; then
    cp "$W/listed" "$W/all" || cld_die "cannot copy the file list"
  else
    cld_ls_files > "$W/all" || cld_die "cannot list tracked files"
  fi
  : > "$W/all.cld"
  pick "$W/all.cld" -e '\.cld$' "$W/all"
  cld_sym_keep "$W/all.cld"
  # "<raw target><US><index>" for every FILE-headed one ...
  : > "$W/unread"
  CLD_SA_UNREAD="$W/unread" awk -v US="$US" '
    { q = ($0 ~ /^\//) ? $0 : "./" $0; l = ""
      r = (getline l < q)
      if (r > 0) {
        sub(/\r$/, "", l)
        if (substr(l, 1, 5) == "FILE ") print substr(l, 6) US $0
      } else if (r < 0) print $0 > ENVIRON["CLD_SA_UNREAD"]
      close(q) }' "$W/all.cld" > "$W/map.raw" </dev/null ||
    cld_die "awk failed reading the symbol indexes"
  # ... and, for a tracked index that is not in the work tree (deleted
  # there, or left out of a gate's temp tree), line 1 as the git index
  # holds it: one git grep over the staged .cld blobs.
  if [ -s "$W/unread" ] && [ "$CLD_IN_GIT" -eq 1 ]; then
    git grep --cached -a -z -n -e '^FILE ' -- '*.cld' > "$W/grep.z"
    [ "$?" -le 1 ] || cld_die "git grep failed reading the staged symbol indexes"
    tr '\000' "$US" < "$W/grep.z" > "$W/grep.us" ||
      cld_die "cannot convert the git grep output"
    CLD_SA_UNREAD="$W/unread" awk -F "$US" -v US="$US" '
      BEGIN {
        u = ENVIRON["CLD_SA_UNREAD"]
        while ((getline x < u) > 0) want[x] = 1
        close(u)
      }
      $2 == "1" && ($1 in want) { l = $3; sub(/\r$/, "", l); print substr(l, 6) US $1 }
    ' "$W/grep.us" </dev/null >> "$W/map.raw" ||
      cld_die "awk failed reading the staged symbol indexes"
  fi
  # ... with the target in the one spelling.
  : > "$W/map"
  while IFS="$US" read -r t i <&3; do
    cld_sym_norm "$t"
    printf '%s%s%s\n' "$CLD_SYM_N" "$US" "$i" >> "$W/map"
  done 3< "$W/map.raw"
  CLD_SA_MAP="$W/map" awk -F "$US" '
    function add(t, i) {
      if (i in owner) return
      owner[i] = t; n[t]++; who[t, n[t]] = i
    }
    BEGIN {
      m = ENVIRON["CLD_SA_MAP"]
      while ((getline l < m) > 0) { split(l, a, FS); add(a[1], a[2]) }
      close(m)
    }
    { add($1, $2); chk[++k] = $2 }
    END {
      for (j = 1; j <= k; j++) {
        i = chk[j]; t = owner[i]; others = ""
        for (x = 1; x <= n[t]; x++) if (who[t, x] != i) others = others " " who[t, x]
        if (others != "") { print "SYM-DUP  " i ": target " t " also claimed by:" others; bad = 1 }
      }
      exit bad
    }' "$W/claims" </dev/null
  case $? in
    0) : ;;
    1) blocked=1 ;;
    *) cld_die "awk failed matching the symbol index targets" ;;
  esac
fi

# --- --gone: is <path>.cld still beside a path that went away? ----------
while IFS= read -r g <&3; do
  if [ -e "$g" ] || [ -L "$g" ]; then
    continue                     # it is back (or never left): not gone
  fi
  c=$g.cld
  [ -e "$c" ] || [ -L "$c" ] || continue
  cld_sym_exempt "$c" && continue
  # Checked in full above (it was a named arg too): already reported.
  grep -F -x -q -e "$c" "$W/cld" && continue
  if [ -f "$c" ] && [ -r "$c" ]; then
    head1=
    { IFS= read -r head1 || :; } < "$c"
    head1=${head1%"$CR"}
    case "$head1" in
      "FILE "*) : ;;
      *) continue ;;             # not a symbol index: not this question
    esac
    cld_sym_norm "${head1#FILE }"
    [ -f "$CLD_SYM_N" ] && continue   # it indexes something still here
    echo "SYM-DEAD $c: target does not exist: $CLD_SYM_N" \
         "($g was deleted or renamed away; remove or rename its index too)"
  else
    echo "SYM-DEAD $c: $g was deleted or renamed away, but its index is still here"
  fi
  blocked=1
done 3< "$W/gone"

# --- SYM-MISS (warn only): a declaring source with no symbol index ------
# The candidates are the watched sources that are regular files with no
# <name>.cld beside them. Each declaration test is one grep -l per
# hundred files, and the languages of the candidates the js rule does not
# hit are decided in one batch (cld_langs_of) -- never a process per file.
: > "$W/miss.c"
: > "$W/miss.hit"
while IFS= read -r j <&3; do
  [ -f "$j" ] || continue
  [ -e "$j.cld" ] && continue
  put "$W/miss.c" "$j"
done 3< "$W/src"
if [ -s "$W/miss.c" ]; then
  if [ "$miss_js" -eq 1 ]; then
    : > "$W/miss.js"
    while IFS= read -r j <&3; do
      case "${j##*/}" in
        *.*)
          e=${j##*.}
          for x in $CLD_SYM_MISS_EXTS; do
            if [ "$e" = "$x" ]; then put "$W/miss.js" "$j"; break; fi
          done ;;
      esac
    done 3< "$W/miss.c"
    grep_l "$CLD_DECL_RE" "$W/miss.js" "$W/miss.hit" "CLD_DECL_RE (check cld.conf)"
  fi
  if [ -n "$miss_other" ]; then
    # what the js rule did not hit, by language
    CLD_SA_HIT="$W/miss.hit" awk '
      BEGIN {
        h = ENVIRON["CLD_SA_HIT"]
        while ((getline x < h) > 0) { sub(/^\.\//, "", x); hit[x] = 1 }
        close(h)
      }
      !($0 in hit)' "$W/miss.c" </dev/null > "$W/miss.rest" ||
      cld_die "awk failed sorting the SYM-MISS candidates"
    cld_langs_of "$W/miss.rest" "$W/miss.lang"
    for l in $miss_other; do
      awk -F "$US" -v l="$l" '$2 == l { print $1 }' "$W/miss.lang" > "$W/miss.$l" ||
        cld_die "awk failed sorting the SYM-MISS candidates"
      grep_l "$(decl_re "$l")" "$W/miss.$l" "$W/miss.hit" "the $l declaration pattern"
    done
  fi
  # reported in the candidates' order
  CLD_SA_HIT="$W/miss.hit" awk '
    BEGIN {
      h = ENVIRON["CLD_SA_HIT"]
      while ((getline x < h) > 0) { sub(/^\.\//, "", x); hit[x] = 1 }
      close(h)
    }
    ($0 in hit) { print "SYM-MISS (warn) " $0 ": declares symbols but has no " $0 ".cld" }
  ' "$W/miss.c" </dev/null || cld_die "awk failed reporting SYM-MISS"
fi

if [ "$blocked" -ne 0 ]; then
  echo "symbol-audit: BLOCKED -- a symbol index is lying about its" \
       "header, its target, its name, or its keys"
fi
if [ "$unchecked" -ne 0 ]; then
  echo "symbol-audit: NOT CHECKED -- an argument named nothing to check (see above)"
  exit 2
fi
[ "$blocked" -eq 0 ] || exit 1
echo "symbol-audit: clean"
exit 0
