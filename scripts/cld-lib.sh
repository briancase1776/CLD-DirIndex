# scripts/cld-lib.sh
# @brief Shared shell library for the .cld checkers: where the repo is,
# how a path is spelled, and which files are tracked.
#
# Sourced (never executed) by every checker, BEFORE cld-config.sh:
#
#   CLD_HERE=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 2
#   . "$CLD_HERE/../cld-lib.sh"
#   cld_init || exit 2
#   . "$CLD_HERE/../cld-config.sh"
#
# The one rule this file exists to enforce: the repo being checked is the
# one the CALLER is standing in, found from the current directory through
# git -- never the one the script happens to live in. That is what lets a
# gate run a checker inside a temp tree materialised from the index
#
#   git checkout-index -a --prefix=TMP/
#   cd TMP && GIT_DIR=<real git dir> GIT_WORK_TREE=TMP check.sh ...
#
# and get answers about the STAGED content, and what lets one toolkit
# checkout check any repo it is run from.
#
# POSIX sh only. sh has no local variables, so every name a function here
# assigns starts with _cld_ to stay out of the caller's way. Functions
# that print a result are meant to be called as $(cld_xxx ...).
#
# Sets (cld_init):
#   CLD_REPO     absolute path of the repo root (the work tree top)
#   CLD_PREFIX   where the caller stood, relative to CLD_REPO ("" or "sub/")
#   CLD_IN_GIT   1 inside a git work tree, 0 in a plain directory
# and leaves the current directory at CLD_REPO, so every path the
# checkers handle afterwards is repo-root-relative.

# cld_die <message> -- a setup error, not a finding: say so and stop.
# Exit 2 so a caller can tell "could not check" from "checked, found
# something" (1). Either way the gate blocks.
cld_die() {
  printf 'cld: %s\n' "$1" >&2
  exit 2
}

# cld_init -- locate the repo from the current directory and cd to it.
cld_init() {
  if _cld_top=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$_cld_top" ]; then
    CLD_IN_GIT=1
    CLD_REPO=$_cld_top
    CLD_PREFIX=$(git rev-parse --show-prefix 2>/dev/null) || CLD_PREFIX=
    # The cd below would change what a RELATIVE GIT_DIR or GIT_WORK_TREE
    # means (git reads both relative to the starting directory), so pin
    # them first. GIT_INDEX_FILE needs nothing: git already reads a
    # relative one against the work tree top, which is where we are going.
    if [ -n "${GIT_DIR:-}" ]; then
      GIT_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null) ||
        cld_die "cannot resolve GIT_DIR ($GIT_DIR)"
      export GIT_DIR
    fi
    if [ -n "${GIT_WORK_TREE:-}" ]; then
      GIT_WORK_TREE=$CLD_REPO
      export GIT_WORK_TREE
    fi
  elif git rev-parse --git-dir >/dev/null 2>&1; then
    # Inside a repo but not inside its work tree (a bare repo, or the
    # .git directory itself). There is no tree to check; falling back to
    # "whatever is in this directory" would check the wrong thing.
    cld_die "inside a git repository but not inside its work tree"
  else
    # Not a git repo at all: check the plain directory we are in. The
    # file listing falls back to find(1).
    CLD_IN_GIT=0
    CLD_REPO=$(pwd)
    CLD_PREFIX=
  fi
  cd "$CLD_REPO" || cld_die "cannot cd to $CLD_REPO"
}

# cld_norm <path> -- the one spelling of a path. Lexical only (nothing is
# looked up on disk): drops empty and "." components, so a leading ./,
# a doubled //, an inner /./ and a trailing / all go; folds "dir/.."
# away; keeps a leading / on an absolute path. An empty result is ".".
#   ./lib/ -> lib    a//b -> a/b    a/./b -> a/b    a/../b -> b    ./ -> .
cld_norm() {
  _cld_p=$1
  _cld_abs=
  case "$_cld_p" in /*) _cld_abs=/ ;; esac
  _cld_out=
  while [ -n "$_cld_p" ]; do
    case "$_cld_p" in
      */*) _cld_c=${_cld_p%%/*}; _cld_p=${_cld_p#*/} ;;
      *)   _cld_c=$_cld_p;       _cld_p= ;;
    esac
    case "$_cld_c" in
      ''|.) : ;;
      ..)
        case "$_cld_out" in
          '')       [ -n "$_cld_abs" ] || _cld_out=.. ;;
          ..|*/..)  _cld_out=$_cld_out/.. ;;
          */*)      _cld_out=${_cld_out%/*} ;;
          *)        _cld_out= ;;
        esac ;;
      *) _cld_out=${_cld_out:+$_cld_out/}$_cld_c ;;
    esac
  done
  _cld_out=$_cld_abs$_cld_out
  [ -n "$_cld_out" ] || _cld_out=.
  printf '%s' "$_cld_out"
}

# cld_arg <path> -- a path as the caller typed it (relative to where they
# stood, or absolute) turned into the repo-root-relative spelling every
# checker works in. An absolute path outside the repo stays absolute.
cld_arg() {
  _cld_a=$(cld_norm "$1")
  case "$_cld_a" in
    /*)
      case "$_cld_a/" in
        "$CLD_REPO"/*) : ;;
        *)
          # Perhaps the repo by another name (CLD_REPO is git's physical
          # path; the caller may have come through a symlink): retry
          # with the physical spelling -- of the directory itself, or of
          # the parent directory when the path names something else.
          if [ -d "$_cld_a" ]; then
            if _cld_d=$(CDPATH= cd "$_cld_a" 2>/dev/null && pwd -P); then
              _cld_a=$_cld_d
            fi
          else
            _cld_d=${_cld_a%/*}
            [ -n "$_cld_d" ] || _cld_d=/
            if _cld_d=$(CDPATH= cd "$_cld_d" 2>/dev/null && pwd -P); then
              _cld_a=${_cld_d%/}/${_cld_a##*/}
            fi
          fi ;;
      esac
      case "$_cld_a/" in
        "$CLD_REPO"/*) _cld_a=.${_cld_a#"$CLD_REPO"} ;;
      esac ;;
    *) _cld_a=$CLD_PREFIX$_cld_a ;;
  esac
  cld_norm "$_cld_a"
}

# cld_ls_files [pathspec...] -- tracked files, one repo-root-relative path
# per line, exactly as named: -z, so git never C-quotes a path (non-ASCII,
# a double quote, a backslash), and core.quotePath=false for good measure.
# Pathspecs are git's: "lib" means everything under lib/, "*.cld" is a
# glob. Exit status is git's, so a failed listing can be told from an
# empty one -- use it as list=$(cld_ls_files ...) || cld_die ... when
# that matters. A path containing a newline cannot be represented and is
# not supported.
cld_ls_files() {
  if [ "${CLD_IN_GIT:-0}" -eq 1 ]; then
    _cld_t=$(mktemp) || return 2
    if git -c core.quotePath=false ls-files -z -- "$@" > "$_cld_t"; then
      tr '\000' '\n' < "$_cld_t"
      _cld_r=$?
    else
      _cld_r=2
    fi
    rm -f "$_cld_t"
    return $_cld_r
  fi
  # Plain directory: every file and symlink below here, filtered the way
  # git would read the pathspec (a directory prefix, or a glob in which
  # * also matches /).
  # The filter is a ( subshell ) on purpose: ksh and zsh run the last
  # stage of a pipeline in the current shell, and nothing here may leak.
  find . \( -type f -o -type l \) -print | sed 's,^\./,,' | (
    while IFS= read -r _cld_f; do
      case "$_cld_f" in .git/*) continue ;; esac
      if [ "$#" -eq 0 ]; then printf '%s\n' "$_cld_f"; continue; fi
      for _cld_s in "$@"; do
        case "$_cld_s" in
          ':(literal)'*) _cld_s=${_cld_s#':(literal)'}
            case "$_cld_s" in
              .) printf '%s\n' "$_cld_f"; break ;;
            esac
            case "$_cld_f" in
              "$_cld_s"|"$_cld_s"/*) printf '%s\n' "$_cld_f"; break ;;
            esac ;;
          *)
            # unquoted on purpose: here the pathspec IS the pattern
            case "$_cld_f" in
              $_cld_s|$_cld_s/*) printf '%s\n' "$_cld_f"; break ;;
            esac ;;
        esac
      done
    done
  )
}

# cld_ls_under <path> -- tracked files at or below one path, the path
# taken LITERALLY (a name holding * or [ is a name, not a pattern) after
# cld_arg-style normalisation by the caller. "." is the whole repo.
cld_ls_under() {
  cld_ls_files ":(literal)$(cld_norm "$1")"
}
