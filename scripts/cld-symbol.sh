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

# The language of a symbol index's target (js, sh, bash, py, or whatever a
# lang line names) is decided in this order, the first step that answers
# winning:
#   1. a prose line "lang <name>" in the index's HEADER block (between
#      line 1 and the first entry) -- the author's word beats any guess;
#   2. the target's #! line: bash, sh, python/python3, node, directly or
#      through "#!/usr/bin/env X";
#   3. the target's extension, through CLD_LANG_EXT_MAP (ext:lang pairs);
#   4. file -b, when a file(1) command exists (skipped silently when it
#      does not): it calls some JavaScript "C source" and a tiny file
#      "ASCII text", which is why it is the last resort.
# Steps 1-3 are the awk functions in CLD_SYM_LANG_AWK, so cld_lang_of and
# the lookups (which decide the language of many indexes in one pass)
# cannot drift apart; step 4 is cld_lang_desc. An awk must never be handed
# a target that is not a readable regular file: some awks (mawk) die
# reading a directory. Each caller tests that in the shell first.
#
#   cls_dot(p)      p made safe to open (./p unless it is absolute)
#   cls_norm(p)     cld_norm's spelling of p, in awk
#   cls_hdr(i)      the "lang" line of index file i's header block, or ""
#   cls_bang(l)     the language the line l names if it is a #! line, or ""
#   cls_ext(t)      the language CLD_LANG_EXT_MAP gives t's extension, or ""
#                   (the map comes in through ENVIRON["CLD_LANG_EXT_MAP"])
CLD_SYM_LANG_AWK='
function cls_dot(p) { return (p ~ /^\//) ? p : "./" p }
function cls_norm(p,   abs, n, a, i, k, o, out) {
  abs = (substr(p, 1, 1) == "/")
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") {
      if (k == 0) { if (!abs) o[++k] = ".."; continue }
      if (o[k] == "..") { o[++k] = ".."; continue }
      k--; continue
    }
    o[++k] = a[i]
  }
  out = ""
  for (i = 1; i <= k; i++) out = (i == 1) ? o[i] : out "/" o[i]
  out = (abs ? "/" : "") out
  return (out == "") ? "." : out
}
function cls_hdr(i,   l, n, c, w, g) {
  i = cls_dot(i); n = 0; g = ""
  while ((getline l < i) > 0) {
    n++
    if (n == 1) continue
    sub(/\r$/, "", l)
    c = split(l, w)
    if (c > 0 && w[1] ~ /^[A-Z]$/) break
    if (c == 2 && w[1] == "lang") { g = w[2]; break }
  }
  close(i)
  return g
}
function cls_bang(l,   n, w, i, b) {
  if (substr(l, 1, 2) != "#!") return ""
  l = substr(l, 3, 256)
  sub(/\r$/, "", l)
  n = split(l, w, /[ \t]+/)
  i = 1
  while (i <= n && w[i] == "") i++
  if (i > n) return ""
  b = w[i]; sub(/.*\//, "", b)
  if (b == "env") {
    # #!/usr/bin/env [-S] [VAR=x ...] interpreter
    i++
    while (i <= n && (w[i] == "" || w[i] ~ /^-/ || w[i] ~ /=/)) i++
    if (i > n) return ""
    b = w[i]; sub(/.*\//, "", b)
  }
  if (b == "bash") return "bash"
  if (b == "sh") return "sh"
  if (b == "python" || b == "python3") return "py"
  if (b == "node") return "js"
  return ""
}
function cls_ext(t,   b, e, n, p, i, k) {
  b = t; sub(/.*\//, "", b)
  if (index(b, ".") == 0) return ""
  e = b; sub(/.*\./, "", e)
  n = split(ENVIRON["CLD_LANG_EXT_MAP"], p, /[ \t\n]+/)
  for (i = 1; i <= n; i++) {
    if (p[i] == "") continue
    k = index(p[i], ":")
    if (k == 0) { if (p[i] == e) return p[i]; continue }
    if (substr(p[i], 1, k - 1) == e) return substr(p[i], k + 1)
  }
  return ""
}
'

# cld_lang_desc <description> -- step 4: sets CLD_SYM_LANG to the language
# a file(1) description names, or to "" when it names none.
cld_lang_desc() {
  case $1 in
    *"Bourne-Again shell script"*) CLD_SYM_LANG=bash ;;
    *"POSIX shell script"*) CLD_SYM_LANG=sh ;;
    *"Python script"*) CLD_SYM_LANG=py ;;
    *"JavaScript source"*|*"Node.js script"*) CLD_SYM_LANG=js ;;
    *) CLD_SYM_LANG= ;;
  esac
}

# cld_lang_ext <path> -- step 3 alone, without a subshell: sets
# CLD_SYM_LANG to the language CLD_LANG_EXT_MAP gives <path>'s extension,
# or to "".
cld_lang_ext() {
  CLD_SYM_LANG=
  case ${1##*/} in
    *.*)
      _cls_e=${1##*.}
      for _cls_p in $CLD_LANG_EXT_MAP; do
        if [ "${_cls_p%%:*}" = "$_cls_e" ]; then
          CLD_SYM_LANG=${_cls_p#*:}
          return 0
        fi
      done ;;
  esac
  return 0
}

# cld_lang_of <target> [<index>] -- print the language of a symbol
# index's target, or nothing when it cannot tell (the order above). Steps
# 1-3 are one awk; file(1) runs only when they say nothing.
cld_lang_of() {
  _cls_t=$1
  _cls_i=${2:-}
  [ -n "$_cls_i" ] && [ -f "$_cls_i" ] && [ -r "$_cls_i" ] || _cls_i=
  _cls_tr=$_cls_t
  [ -n "$_cls_tr" ] && [ -f "$_cls_tr" ] && [ -r "$_cls_tr" ] || _cls_tr=
  _cls_got=$(CLD_SYM_LI=$_cls_i CLD_SYM_LT=$_cls_tr CLD_SYM_LP=$_cls_t \
             CLD_LANG_EXT_MAP=$CLD_LANG_EXT_MAP awk "$CLD_SYM_LANG_AWK"'
      BEGIN {
        i = ENVIRON["CLD_SYM_LI"]; t = ENVIRON["CLD_SYM_LT"]; g = ""
        if (i != "") g = cls_hdr(i)
        if (g == "" && t != "") {
          l = ""
          if ((getline l < cls_dot(t)) > 0) g = cls_bang(l)
          close(cls_dot(t))
        }
        if (g == "") g = cls_ext(ENVIRON["CLD_SYM_LP"])
        printf "%s", g
        exit
      }' </dev/null)
  if [ -n "$_cls_got" ]; then
    printf '%s' "$_cls_got"
    return 0
  fi
  if [ -n "$_cls_tr" ] && command -v file >/dev/null 2>&1; then
    case "$_cls_tr" in /*) : ;; *) _cls_tr=./$_cls_tr ;; esac
    cld_lang_desc "$(file -b "$_cls_tr" 2>/dev/null)"
    printf '%s' "$CLD_SYM_LANG"
  fi
  return 0
}
