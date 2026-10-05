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
# with NOTFOUND <name> (find), FREE <name> / TAKEN <name> (dupecheck),
# NOINDEX <file> or NONE <file> (deps) and NONE <target> (rdeps) when
# there is nothing to list.
# Exit: 0 found / FREE / listed, 1 nothing found / TAKEN / no index,
# 2 usage or setup error.
#
# Matching is on field 2 only, and always a fixed-string comparison --
# never a regex built from NAME, so a.b cannot answer for axb:
#   find, dupecheck  an entry whose name IS NAME, or ends in ".NAME" (a
#                    qualified entry: Thing.load answers for load). I
#                    entries are dependencies, not definitions, and are
#                    not searched.
#   rdeps            an I entry whose token, as written, is TARGET; or,
#                    once leading ./ ../ / and $VAR components (and
#                    quotes) are dropped from both, the two are equal or
#                    one ends with "/" plus the other: I ../lib/util.sh
#                    answers for lib/util.sh, scripts/lib/util.sh and
#                    util.sh.
# Prose lines (first field not a single capital letter) are never
# entries. CR-LF indexes are read with the CR removed.
#
# Which .cld files are symbol indexes is decided in scripts/cld-symbol.sh,
# the same as symbol-audit: never an index.cld, nothing
# CLD_NOT_DIR_INDEX_RE, CLD_NOT_SYMBOL_INDEX_RE or CLD_SKIP_RE names.
# --lang keeps only the indexes whose target is in language L, decided by
# cld_lang_of (a "lang" header line, the #! line, CLD_LANG_EXT_MAP,
# file(1)) -- and only for the indexes that already matched, so a lookup
# costs one awk pass however big the repo is.
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

# scan <mode> -- one pass over every candidate index; prints matching
# entries as index US target US line US letter US name US description.
#   mode name   field 2 is $CLD_LK_NAME or ends in ".$CLD_LK_NAME"
#   mode rdeps  an I entry whose token matches $CLD_LK_TARGET
scan() {
  CLD_LK_NAME=$arg CLD_LK_TARGET=$arg awk -v mode="$1" -v US="$US" '
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
    BEGIN {
      want = ENVIRON["CLD_LK_NAME"]; dotwant = "." want
      traw = ENVIRON["CLD_LK_TARGET"]; tg = strip(traw)
    }
    {
      p = $0; q = (p ~ /^\//) ? p : "./" p
      ln = 0; tgt = ""
      while ((getline l < q) > 0) {
        ln++
        sub(/\r$/, "", l)
        if (ln == 1) {
          if (substr(l, 1, 5) != "FILE ") break
          tgt = substr(l, 6)
          continue
        }
        if (split(l, w) < 2 || w[1] !~ /^[A-Z]$/) continue
        k = w[2]
        if (mode == "name") {
          if (w[1] == "I") continue
          if (k != want && !ends(k, dotwant)) continue
        } else {
          if (w[1] != "I") continue
          if (k != traw) {
            tk = strip(k)
            if (tk == "" || tg == "") continue
            if (tk != tg && !ends(tk, "/" tg) && !ends(tg, "/" tk)) continue
          }
        }
        d = l
        sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", d)
        print p US tgt US ln US w[1] US k US d
      }
      close(q)
    }' "$W/idx" </dev/null > "$W/hits" ||
    cld_die "awk failed reading the symbol indexes"
}

# show_hits -- print $W/hits as "<T> <name>  in  <file>  --  <desc>",
# keeping only the indexes in $lang when one was asked for. Counts the
# lines printed in $shown.
show_hits() {
  shown=0
  last=
  last_lang=
  while IFS="$US" read -r p t n letter k d <&3; do
    cld_sym_norm "$t"; t=$CLD_SYM_N
    if [ -n "$lang" ]; then
      if [ "$p" != "$last" ]; then
        last=$p
        last_lang=$(cld_lang_of "$t" "$p")
      fi
      [ "$last_lang" = "$lang" ] || continue
    fi
    printf '%s %s  in  %s  --  %s\n' "$letter" "$k" "$t" "$d"
    shown=$((shown + 1))
  done 3< "$W/hits"
}

among=
[ -n "$lang" ] && among=" (among $lang indexes)"

case "$cmd" in
  find)
    indexes
    scan name
    show_hits
    if [ "$shown" -eq 0 ]; then
      echo "NOTFOUND $arg$among"
      exit 1
    fi
    exit 0 ;;

  dupecheck)
    indexes
    scan name
    show_hits > "$W/shown"
    if [ "$shown" -eq 0 ]; then
      echo "FREE $arg$among"
      exit 0
    fi
    echo "TAKEN $arg$among"
    cat "$W/shown"
    exit 1 ;;

  deps)
    p=$(cld_arg "$arg")
    case "$p" in
      *.cld) i=$p ;;
      *) i=$p.cld ;;
    esac
    if cld_sym_exempt "$i" || [ ! -f "$i" ]; then
      echo "NOINDEX $p: no symbol index (expected $i)"
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
      3) echo "NONE $p: $i lists no I entries"; exit 0 ;;
      *) cld_die "awk failed reading $i" ;;
    esac ;;

  rdeps)
    indexes
    scan rdeps
    shown=0
    while IFS="$US" read -r p t n letter k d <&3; do
      cld_sym_norm "$t"
      printf '%s  I %s  --  %s\n' "$CLD_SYM_N" "$k" "$d"
      shown=$((shown + 1))
    done 3< "$W/hits"
    if [ "$shown" -eq 0 ]; then
      echo "NONE $arg: no I entry names it"
      exit 1
    fi
    exit 0 ;;
esac
