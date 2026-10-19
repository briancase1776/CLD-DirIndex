#!/bin/sh
# scripts/symbol-lookup/lookup.sh
# @brief Symbol lookups over the per-file symbol indexes (<file>.cld, line
# 1 "FILE <path>"), shared by the symbol-find-*, symbol-dupecheck-* and
# symbol-deps skills so they all read the map the same way.
#
# Usage:
#   lookup.sh find NAME [--lang L]       which file defines NAME
#   lookup.sh dupecheck NAME [--lang L]  is NAME already a defined symbol
#   lookup.sh deps FILE                  what FILE depends on (its I entries)
#   lookup.sh rdeps TARGET               which files depend on TARGET
#
# Output, one line per hit:
#   find, dupecheck   <T> <name>  in  <file>  --  <description>
#   deps              I <token>  --  <description>
#   rdeps             <file>  I <token>  --  <description>
# and when there is nothing to list:
#   find       NOTFOUND <name>
#   dupecheck  FREE <name>            (TAKEN <name> heads a list of hits)
#   deps       NOINDEX <file>         FILE has no symbol index, or an
#                                     exempt one (the line says which)
#              NONE <file>            its index lists no I entry
#   rdeps      NONE <target>          no I entry names it; the line says
#                                     how many indexes record any
#   deps, rdeps  UNKNOWN <path>       no symbol index in the repo records
#                                     a single I entry: dependencies are
#                                     not indexed here, so "none" would
#                                     be a guess
# Exit: 0 found / FREE / listed; 1 NOTFOUND / TAKEN / NOINDEX / NONE /
# UNKNOWN (nothing listed); 2 usage or setup error.
#
# Matching is on field 2 only, and always a fixed-string comparison --
# never a regex built from NAME, so a.b cannot answer for axb:
#   find, dupecheck  an entry whose name IS NAME, or ends in ".NAME" (a
#                    qualified entry: Thing.load answers for load). I
#                    entries are dependencies, not definitions, and are
#                    not searched.
#   rdeps            an I entry whose token, as written, is TARGET; else
#                    by how the importing file's language writes it:
#     js   a ./ or ../ token is resolved against the importing file's
#          directory and must then name TARGET, TARGET without its
#          extension (import "./util" for util.js), or the directory of
#          an index.js TARGET. A token that resolves outside the repo,
#          and a bare specifier ("react", "lodash/fp"), are compared as
#          paths, below.
#     py   a dotted module: pkg/util.py is pkg.util (pkg/__init__.py is
#          pkg). A token equals it, or is its last dotted parts (import
#          util); a relative token (.util, ..pkg.mod) is resolved
#          against the importing file's package first.
#     sh, bash, and any other language: compared as paths, lexically --
#          ". ./lib/x.sh" is relative to the directory the script runs
#          in, which no index records. Once leading ./ ../ / and $VAR
#          components (and quotes) are dropped from both, the two are
#          equal or one ends with "/" plus the other: I ../lib/util.sh
#          answers for lib/util.sh, scripts/lib/util.sh and util.sh. So a
#          short relative token can answer for a TARGET it does not mean.
#   The importing file's language is decided as --lang decides it.
# Prose lines (first field not a single capital letter) are never
# entries. CR-LF indexes are read with the CRs removed.
#
# Which .cld files are symbol indexes is decided in scripts/cld-symbol.sh,
# the same as symbol-audit: never an index.cld, nothing
# CLD_NOT_DIR_INDEX_RE, CLD_NOT_SYMBOL_INDEX_RE or CLD_SKIP_RE names.
# --lang keeps only the indexes whose target is in language L (a "lang"
# header line, the #! line, CLD_LANG_EXT_MAP, file(1); cld-symbol.sh).
# A lookup is one awk pass over every index, then -- only for the indexes
# that matched -- one more awk that reads their targets' #! lines, and one
# file(1) call per hundred targets that nothing else could place.
#
# Paths with spaces are fine; a path holding a newline is not supported.
# READ-ONLY: nothing here writes to the repo.

set -u

CLD_HERE=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 2
. "$CLD_HERE/../cld-lib.sh"
cld_init
. "$CLD_HERE/../cld-config.sh"
. "$CLD_HERE/../cld-symbol.sh"

US=$CLD_SYM_US
CR=$CLD_SYM_CR

usage() {
  cat >&2 <<'EOF'
usage: lookup.sh find NAME [--lang L]
       lookup.sh dupecheck NAME [--lang L]
       lookup.sh deps FILE
       lookup.sh rdeps TARGET
EOF
  exit 2
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
arg=
lang=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lang) [ "$#" -ge 2 ] || usage; lang=$2; shift 2 ;;
    --lang=*) lang=${1#--lang=}; shift ;;
    *) [ -z "$arg" ] || usage; arg=$1; shift ;;
  esac
done
[ -n "$arg" ] || usage
case "$cmd" in
  find|dupecheck) : ;;
  deps|rdeps) [ -z "$lang" ] || usage ;;
  *) usage ;;
esac

W=$(mktemp -d) || cld_die "cannot make a temp directory"
trap 'rm -rf "$W"' EXIT
trap 'exit 2' HUP INT TERM

# indexes -- the symbol-index candidates, one path per line, in $W/idx
indexes() {
  cld_ls_files > "$W/all" || cld_die "cannot list tracked files"
  grep -e '\.cld$' "$W/all" > "$W/idx"
  [ "$?" -le 1 ] || cld_die "cannot list the .cld files"
  cld_sym_keep "$W/idx"
}

# What rdeps compares a token with, besides TARGET as typed: TARGET as a
# repo path (tp); for a js TARGET, the path without its extension and,
# for an index.js, its directory; for a py TARGET, its module path
# (pkg/util for pkg/util.py, pkg for pkg/__init__.py), dotted in awk.
tp= tnoext= tdir= tmodp=

# scan <mode> -- one pass over every candidate index. Prints matching
# entries as
#   index US target US line US letter US key US description US hl US how
# where hl is the index's "lang" header line (or empty) and how, for
# rdeps, is Y (a match whatever the importing file's language) or C
# followed by three digits, whether it matches if the importing file is
# js, py, or anything else. Writes "<indexes read> <indexes with an I
# entry>" to $W/count.
#   mode name   field 2 is $CLD_LK_NAME or ends in ".$CLD_LK_NAME"
#   mode rdeps  an I entry whose token matches TARGET (see the header)
#   mode count  prints nothing; only the counts
scan() {
  CLD_LK_NAME=$arg CLD_LK_TARGET=$arg CLD_LK_TP=$tp CLD_LK_TNOEXT=$tnoext \
  CLD_LK_TDIR=$tdir CLD_LK_TMODP=$tmodp CLD_LK_COUNT="$W/count" \
  CLD_LANG_EXT_MAP=$CLD_LANG_EXT_MAP \
  awk -v mode="$1" -v US="$US" "$CLD_SYM_LANG_AWK"'
    function strip(p,   n, a, i, out, q) {
      q = "^[\"\047]+|[\"\047]+$"
      gsub(q, "", p)
      n = split(p, a, "/"); out = ""; i = 1
      while (i <= n && (a[i] == "" || a[i] == "." || a[i] == ".." || substr(a[i], 1, 1) == "$")) i++
      for (; i <= n; i++) if (a[i] != "" && a[i] != ".") out = (out == "" ? a[i] : out "/" a[i])
      return out
    }
    function ends(s, suf) {
      return length(s) > length(suf) && substr(s, length(s) - length(suf) + 1) == suf
    }
    function dirof(f) {
      if (index(f, "/") == 0) return "."
      sub(/\/[^\/]*$/, "", f)
      return (f == "") ? "/" : f
    }
    function outside(r) { return r == ".." || substr(r, 1, 3) == "../" }
    # rdep(k, it, hl) -- Y, "", or C<js><py><other>: does token k, written
    # in the index of the importing file it (whose lang line is hl), name
    # TARGET?
    function rdep(k, it, hl,   tk, mo, mj, mp, r, nd, rest, up, i, m) {
      if (k == traw) return "Y"
      tk = strip(k)
      mo = (tk != "" && tg != "" && (tk == tg || ends(tk, "/" tg) || ends(tg, "/" tk)))
      mj = mo
      if (k ~ /^\.\.?\//) {
        r = cls_norm(dirof(it) "/" k)
        if (!outside(r))
          mj = (r == tp || (tnoext != "" && r == tnoext) || (tdir != "" && r == tdir))
      }
      mp = mo
      if (tmod != "" && index(k, "/") == 0) {
        if (substr(k, 1, 1) == ".") {
          nd = match(k, /^\.+/) ? RLENGTH : 0
          rest = substr(k, nd + 1)
          up = dirof(it)
          for (i = 1; i < nd; i++) up = up "/.."
          r = cls_norm(up)
          if (outside(r)) mp = 0
          else {
            m = (r == ".") ? "" : r
            gsub(/\//, ".", m)
            if (rest != "") m = (m == "") ? rest : m "." rest
            mp = (m == tmod)
          }
        } else mp = (k == tmod || ends(tmod, "." k))
      }
      if (mj == mo && mp == mo) return mo ? "Y" : ""
      if (hl != "") return ((hl == "js") ? mj : (hl == "py") ? mp : mo) ? "Y" : ""
      return "C" mj mp mo
    }
    BEGIN {
      want = ENVIRON["CLD_LK_NAME"]; dotwant = "." want
      traw = ENVIRON["CLD_LK_TARGET"]; tg = strip(traw)
      tp = ENVIRON["CLD_LK_TP"]; tnoext = ENVIRON["CLD_LK_TNOEXT"]
      tdir = ENVIRON["CLD_LK_TDIR"]; tmod = ENVIRON["CLD_LK_TMODP"]
      gsub(/\//, ".", tmod)
      nidx = 0; ndep = 0
    }
    {
      p = $0; q = cls_dot(p)
      ln = 0; tgt = ""; it = ""; hl = ""; hdr = 1; hasI = 0
      while ((getline l < q) > 0) {
        ln++
        sub(/\r$/, "", l)
        if (ln == 1) {
          if (substr(l, 1, 5) != "FILE ") break
          tgt = substr(l, 6); it = cls_norm(tgt); nidx++
          continue
        }
        c = split(l, w)
        if (hdr) {
          # the header block: prose up to the first entry, where a
          # "lang <name>" line says the language
          if (c > 0 && w[1] ~ /^[A-Z]$/) hdr = 0
          else {
            if (c == 2 && w[1] == "lang" && hl == "") hl = w[2]
            continue
          }
        }
        if (c < 2 || w[1] !~ /^[A-Z]$/) continue
        if (w[1] == "I") hasI = 1
        if (mode == "count") continue
        k = w[2]; how = ""
        if (mode == "name") {
          if (w[1] == "I") continue
          if (k != want && !ends(k, dotwant)) continue
        } else {
          if (w[1] != "I") continue
          how = rdep(k, it, hl)
          if (how == "") continue
        }
        d = l
        sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", d)
        print p US tgt US ln US w[1] US k US d US hl US how
      }
      close(q)
      if (hasI) ndep++
    }
    END { print nidx " " ndep > ENVIRON["CLD_LK_COUNT"] }' "$W/idx" </dev/null > "$W/hits" ||
    cld_die "awk failed reading the symbol indexes"
  read -r nidx ndep < "$W/count" || cld_die "lost the index counts"
}

# langs <need-all> -- the language of each hit's index, for every hit
# when <need-all> is 1, else only for the rdeps hits marked C, into
# $W/lmap as "target US lang". A hit whose index has a "lang" header line
# (field 7, from the scan) needs nothing more; the rest go, once per
# target, through cld_langs_of (cld-symbol.sh): the #! line, the
# extension, file(1) -- one awk and one file(1) call per hundred targets,
# never a process per hit.
langs() {
  if [ "$1" -eq 1 ]; then
    pick_need='$7 == ""'
  else
    pick_need='$7 == "" && $8 ~ /^C/'
  fi
  awk -F "$US" "$CLD_SYM_LANG_AWK""$pick_need"' { print cls_norm($2) }' \
      "$W/hits" </dev/null > "$W/need.all" ||
    cld_die "awk failed reading the hits"
  : > "$W/lmap" || cld_die "cannot write in $W"
  [ -s "$W/need.all" ] || return 0
  LC_ALL=C sort -u "$W/need.all" > "$W/need" || cld_die "cannot sort the targets"
  cld_langs_of "$W/need" "$W/lmap"
}

# show <format> -- print the hits in $W/hits whose language fits:
#   format name   "<T> <name>  in  <file>  --  <desc>", only the indexes
#                 in $lang when one was asked for
#   format rdeps  "<file>  I <token>  --  <desc>", Y hits and the C hits
#                 the importing file's language makes a match
# Sets shown to the number of lines printed.
show() {
  CLD_LK_LMAP="$W/lmap" CLD_LK_SHOWN="$W/shown" \
  awk -F "$US" -v fmt="$1" -v want="$lang" "$CLD_SYM_LANG_AWK"'
    BEGIN {
      f = ENVIRON["CLD_LK_LMAP"]
      while ((getline x < f) > 0) { split(x, a, FS); lm[a[1]] = a[2] }
      close(f)
      n = 0
    }
    {
      t = cls_norm($2); g = $7
      if (g == "") g = (t in lm) ? lm[t] : ""
      if (fmt == "name") {
        if (want != "" && g != want) next
        printf "%s %s  in  %s  --  %s\n", $4, $5, t, $6
      } else {
        h = $8
        if (substr(h, 1, 1) == "C")
          h = substr(h, (g == "js") ? 2 : (g == "py") ? 3 : 4, 1) == "1" ? "Y" : ""
        if (h != "Y") next
        printf "%s  I %s  --  %s\n", t, $5, $6
      }
      n++
    }
    END { print n > ENVIRON["CLD_LK_SHOWN"] }' "$W/hits" </dev/null ||
    cld_die "awk failed printing the hits"
  read -r shown < "$W/shown" || cld_die "lost the hit count"
}

# coverage -- why rdeps or deps has nothing to list: either the repo does
# not index dependencies at all (UNKNOWN), or how much of it does.
coverage() {
  if [ "$nidx" -eq 0 ]; then
    printf 'there is no symbol index here at all'
  else
    printf '%s of %s symbol indexes record an I entry' "$ndep" "$nidx"
  fi
}

among=
[ -n "$lang" ] && among=" (among $lang indexes)"

case "$cmd" in
  find)
    indexes
    scan name
    if [ -n "$lang" ]; then langs 1; else langs 0; fi
    show name
    if [ "$shown" -eq 0 ]; then
      echo "NOTFOUND $arg$among"
      exit 1
    fi
    exit 0 ;;

  dupecheck)
    indexes
    scan name
    if [ -n "$lang" ]; then langs 1; else langs 0; fi
    show name > "$W/shown.out"
    if [ "$shown" -eq 0 ]; then
      echo "FREE $arg$among"
      exit 0
    fi
    echo "TAKEN $arg$among"
    cat "$W/shown.out"
    exit 1 ;;

  deps)
    p=$(cld_arg "$arg")
    case "$p" in
      *.cld) i=$p ;;
      *) i=$p.cld ;;
    esac
    if [ ! -f "$i" ]; then
      echo "NOINDEX $p: no symbol index (expected $i)"
      exit 1
    fi
    if cld_sym_exempt "$i"; then
      echo "NOINDEX $p: $i is exempt from the symbol side, so it is not read" \
           "(an index.cld, or named by CLD_SKIP_RE, CLD_NOT_SYMBOL_INDEX_RE or" \
           "CLD_NOT_DIR_INDEX_RE in cld.conf)"
      exit 1
    fi
    h=
    { IFS= read -r h || :; } < "$i"
    h=${h%"$CR"}
    case "$h" in
      "FILE "*) : ;;
      *) echo "NOINDEX $p: $i is not a symbol index (line 1 is not FILE <path>)"
         exit 1 ;;
    esac
    awk '
      { sub(/\r$/, "") }
      FNR > 1 && $1 == "I" && NF >= 2 {
        d = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", d)
        print "I " $2 "  --  " d; n++
      }
      END { exit (n ? 0 : 3) }' "./$i" </dev/null
    case $? in
      0) exit 0 ;;
      3) : ;;
      *) cld_die "awk failed reading $i" ;;
    esac
    indexes
    scan count
    if [ "$ndep" -eq 0 ]; then
      echo "UNKNOWN $p: $i lists no I entries, and no symbol index here" \
           "records one ($(coverage)) -- dependencies are not indexed in" \
           "this repo, so this cannot say what $p uses"
    else
      echo "NONE $p: $i lists no I entries ($(coverage))"
    fi
    exit 1 ;;

  rdeps)
    tp=$(cld_arg "$arg")
    case $tp in
      /*|..|../*) : ;;          # outside the repo: no derived forms
      *)
        cld_lang_ext "$tp"
        case $CLD_SYM_LANG in
          js)
            tnoext=${tp%.*}
            if [ "${tnoext##*/}" = index ]; then
              case $tnoext in */*) tdir=${tnoext%/*} ;; *) tdir=. ;; esac
            fi ;;
          py)
            tmodp=${tp%.*}
            if [ "${tmodp##*/}" = __init__ ]; then
              case $tmodp in */*) tmodp=${tmodp%/*} ;; *) tmodp= ;; esac
            fi ;;
        esac ;;
    esac
    indexes
    scan rdeps
    langs 0
    show rdeps
    if [ "$shown" -eq 0 ]; then
      if [ "$ndep" -eq 0 ]; then
        echo "UNKNOWN $arg: no symbol index here records an I entry" \
             "($(coverage)) -- dependencies are not indexed in this repo," \
             "so this cannot say what depends on $arg"
      else
        echo "NONE $arg: no I entry names it ($(coverage))"
      fi
      exit 1
    fi
    exit 0 ;;
esac
