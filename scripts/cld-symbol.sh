# scripts/cld-symbol.sh
# @brief Shared symbol-side helpers for scripts/symbol-audit/check.sh and
# scripts/symbol-lookup/lookup.sh: which .cld files are symbol indexes at
# all, one spelling for a target path, and the language of a target.
#
# Sourced (never executed), AFTER cld-lib.sh and cld-config.sh:
#
#   . "$CLD_HERE/../cld-lib.sh"
#   cld_init
#   . "$CLD_HERE/../cld-config.sh"
#   . "$CLD_HERE/../cld-symbol.sh"
#
# The functions read the config keys when they are CALLED, so the order
# above only has to hold by the time one runs. Like cld-lib.sh this is
# POSIX sh with no local variables: every name assigned here starts with
# _cls_ or is a documented CLD_SYM_* result.

# Two characters the callers need and POSIX sh cannot spell literally.
CLD_SYM_CR=$(printf '\r')
# Field separator for the callers' work files: ASCII unit separator, a
# byte no real path or description carries (a tab can be in either).
CLD_SYM_US=$(printf '\037')

# cld_sym_norm <path> -- sets CLD_SYM_N to cld_norm's spelling of <path>,
# without a subshell when the path is already in that spelling (the
# common case: a FILE header written the way git prints paths).
cld_sym_norm() {
  case "$1" in
    ''|.|..|./*|../*|*/|*/.|*/..|*//*|*/./*|*/../*) CLD_SYM_N=$(cld_norm "$1") ;;
    *) CLD_SYM_N=$1 ;;
  esac
}

# _cls_drop <regex> <file> -- remove the lines matching the grep BRE from
# <file>, in place. An empty regex removes nothing (grep -v '' would
# remove everything). A regex grep rejects is a setup error, not "no
# match": exit 2 rather than let a bad cld.conf value switch a check off.
_cls_drop() {
  [ -n "$1" ] || return 0
  grep -v -e "$1" "$2" > "$2.cls"
  [ "$?" -le 1 ] || cld_die "grep rejected the pattern '$1' (check cld.conf)"
  mv "$2.cls" "$2" || cld_die "cannot rewrite $2"
}

# cld_sym_keep <file> -- filter a list of repo-relative .cld paths (one
# per line, in <file>, rewritten in place) down to the ones that may be
# SYMBOL indexes. One exemption policy for every symbol-side tool:
#   - a file named index.cld is a directory index, whatever its line 1
#     says -- a bad header there is index-audit's BADHDR, not ours (so an
#     extensionless source named "index" cannot have a symbol index: its
#     <name>.cld would be index.cld; a known clash);
#   - CLD_NOT_DIR_INDEX_RE marks other-format index.cld files, still not
#     ours;
#   - CLD_NOT_SYMBOL_INDEX_RE marks files that borrow the FILE header;
#   - CLD_SKIP_RE marks trees that carry no index at all.
cld_sym_keep() {
  grep -v -e '^index\.cld$' -e '/index\.cld$' "$1" > "$1.cls"
  [ "$?" -le 1 ] || cld_die "cannot filter $1"
  mv "$1.cls" "$1" || cld_die "cannot rewrite $1"
  _cls_drop "$CLD_NOT_DIR_INDEX_RE" "$1"
  _cls_drop "$CLD_NOT_SYMBOL_INDEX_RE" "$1"
  _cls_drop "$CLD_SKIP_RE" "$1"
}

# cld_sym_exempt <path> -- true (0) when cld_sym_keep would drop <path>.
cld_sym_exempt() {
  case "$1" in index.cld|*/index.cld) return 0 ;; esac
  for _cls_re in "$CLD_NOT_DIR_INDEX_RE" "$CLD_NOT_SYMBOL_INDEX_RE" "$CLD_SKIP_RE"; do
    [ -n "$_cls_re" ] || continue
    printf '%s\n' "$1" | grep -q -e "$_cls_re"
    case $? in
      0) return 0 ;;
      1) : ;;
      *) cld_die "grep rejected the pattern '$_cls_re' (check cld.conf)" ;;
    esac
  done
  return 1
}

# cld_lang_of <target> [<index>] -- print the language of a symbol
# index's target (js, sh, bash, py, whatever a lang line names), or
# nothing when it cannot tell. The first step that answers wins:
#   1. a prose line "lang <name>" in the index's HEADER block (between
#      line 1 and the first entry) -- the author's word beats any guess;
#   2. the target's #! line: bash, sh, python/python3, node, directly or
#      through "#!/usr/bin/env X";
#   3. the target's extension, through CLD_LANG_EXT_MAP (ext:lang pairs);
#   4. file -b, when a file(1) command exists (skipped silently when it
#      does not): it calls some JavaScript "C source" and a tiny file
#      "ASCII text", which is why it is the last resort.
# Reads the index and the target's first line with one awk; file(1) runs
# only when steps 1-3 say nothing.
cld_lang_of() {
  _cls_t=$1
  _cls_i=${2:-}
  [ -n "$_cls_i" ] && [ -f "$_cls_i" ] && [ -r "$_cls_i" ] || _cls_i=
  _cls_tr=$_cls_t
  [ -n "$_cls_tr" ] && [ -f "$_cls_tr" ] && [ -r "$_cls_tr" ] || _cls_tr=
  _cls_got=
  if [ -n "$_cls_i$_cls_tr" ]; then
    _cls_got=$(CLD_SYM_LI=$_cls_i CLD_SYM_LT=$_cls_tr awk '
      function dot(p) { return (p ~ /^\//) ? p : "./" p }
      BEGIN {
        i = ENVIRON["CLD_SYM_LI"]; t = ENVIRON["CLD_SYM_LT"]
        if (i != "") {
          i = dot(i); n = 0
          while ((getline l < i) > 0) {
            n++
            if (n == 1) continue
            sub(/\r$/, "", l)
            c = split(l, w)
            if (c > 0 && w[1] ~ /^[A-Z]$/) break
            if (c == 2 && w[1] == "lang") { print "lang " w[2]; exit }
          }
          close(i)
        }
        if (t != "") {
          t = dot(t)
          if ((getline l < t) > 0 && substr(l, 1, 2) == "#!") {
            sub(/\r$/, "", l)
            print "bang " substr(l, 3, 256)
          }
        }
        exit
      }' </dev/null)
  fi
  case "$_cls_got" in
    "lang "*) printf '%s' "${_cls_got#lang }"; return 0 ;;
    "bang "*)
      _cls_b=${_cls_got#bang }
      _cls_b=${_cls_b#"${_cls_b%%[! 	]*}"}
      _cls_w=${_cls_b%%[ 	]*}
      _cls_b=${_cls_b#"$_cls_w"}
      _cls_w=${_cls_w##*/}
      if [ "$_cls_w" = env ]; then
        # #!/usr/bin/env [-S] [VAR=x ...] interpreter
        while :; do
          _cls_b=${_cls_b#"${_cls_b%%[! 	]*}"}
          _cls_w=${_cls_b%%[ 	]*}
          [ -n "$_cls_w" ] || break
          _cls_b=${_cls_b#"$_cls_w"}
          case "$_cls_w" in -*|*=*) continue ;; esac
          break
        done
        _cls_w=${_cls_w##*/}
      fi
      case "$_cls_w" in
        bash) printf 'bash'; return 0 ;;
        sh) printf 'sh'; return 0 ;;
        python|python3) printf 'py'; return 0 ;;
        node) printf 'js'; return 0 ;;
      esac ;;
  esac
  case "${_cls_t##*/}" in
    *.*)
      _cls_e=${_cls_t##*.}
      for _cls_p in $CLD_LANG_EXT_MAP; do
        if [ "${_cls_p%%:*}" = "$_cls_e" ]; then
          printf '%s' "${_cls_p#*:}"
          return 0
        fi
      done ;;
  esac
  if [ -n "$_cls_tr" ] && command -v file >/dev/null 2>&1; then
    case "$_cls_tr" in /*) : ;; *) _cls_tr=./$_cls_tr ;; esac
    case "$(file -b "$_cls_tr" 2>/dev/null)" in
      *"Bourne-Again shell script"*) printf 'bash' ;;
      *"POSIX shell script"*) printf 'sh' ;;
      *"Python script"*) printf 'py' ;;
      *"JavaScript source"*|*"Node.js script"*) printf 'js' ;;
    esac
  fi
  return 0
}
