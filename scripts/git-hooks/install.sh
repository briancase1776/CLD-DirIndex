#!/bin/sh
# scripts/git-hooks/install.sh
# @brief Install the .cld pre-commit dispatcher into the hooks directory
# git actually runs, chaining any foreign pre-commit hook already there.
#
# Usage: ./scripts/git-hooks/install.sh   (once per clone; safe to re-run,
# and safe to wire into a Claude Code SessionStart hook so a fresh clone
# is gated from the first commit)
#
# Where it installs: wherever `git rev-parse --git-path hooks` says,
# asked from this script's own directory. That is the one place git
# looks: it is the shared hooks directory of the main repo when run from
# a linked worktree (all worktrees share their hooks), and it is
# core.hooksPath when that is set -- in which case this prints a
# WARNING, because such a directory may be shared by other repos, or
# be part of a work tree.
#
# A foreign pre-commit hook is CHAINED, never just backed up: it is moved,
# unchanged, to pre-commit.cld-chained in the same hooks directory, and
# the dispatcher runs it first on every commit (its failure still
# blocks). Nothing is ever overwritten:
#   - our own dispatcher (current, or as shipped before it carried the
#     cld-dispatcher marker) is simply replaced by the current one;
#   - a foreign hook found while pre-commit.cld-chained already exists
#     (another tool replaced the dispatcher after an earlier install) is
#     an ambiguity only a person can settle: this stops with exit 1 and
#     touches neither file;
#   - pre-commit.pre-cld, the backup an older install.sh made (and then
#     stopped running), is left alone and pointed out.
#
# POSIX sh only.

set -u

die() {
  printf 'install.sh: %s\n' "$1" >&2
  exit 1
}

DIR=$(CDPATH= cd "$(dirname "$0")" && pwd) || die "cannot find my own directory"
ours=$DIR/pre-commit
[ -f "$ours" ] || die "missing $ours"

# Every git question is asked from this script's directory: the repo
# being gated is the one that carries this copy of the toolkit.
hp=$(cd "$DIR" && git rev-parse --git-path hooks 2>/dev/null) && [ -n "$hp" ] ||
  die "$DIR is not inside a git work tree"
case $hp in /*) : ;; *) hp=$DIR/$hp ;; esac
mkdir -p "$hp" || die "cannot create the hooks directory $hp"
HOOKS_DIR=$(CDPATH= cd "$hp" && pwd -P) || die "cannot enter $hp"

hooks_path=$(cd "$DIR" && git config --get core.hooksPath 2>/dev/null) || hooks_path=
if [ -n "$hooks_path" ]; then
  common=$(cd "$DIR" && git rev-parse --git-common-dir 2>/dev/null) || common=
  case $common in ''|/*) : ;; *) common=$DIR/$common ;; esac
  default=$common/hooks
  if [ -d "$default" ]; then
    default=$(CDPATH= cd "$default" && pwd -P) || :
  fi
  if [ "$default" != "$HOOKS_DIR" ]; then
    echo "WARNING: core.hooksPath is set ($hooks_path), so git runs hooks from"
    echo "  $HOOKS_DIR"
    echo "  and not from $default. Installing there. If other repositories"
    echo "  share that directory they get this dispatcher too (in a tree with"
    echo "  no scripts/git-hooks/pre-commit.d it runs no .cld checks, and it"
    echo "  still runs a chained hook)."
    top=$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null) || top=
    if [ -n "$top" ]; then
      top=$(CDPATH= cd "$top" && pwd -P) || :
      case "$HOOKS_DIR/" in
        "$top"/*)
          echo "  That directory is inside this work tree: the installed hook and"
          echo "  any chained copy will show up there as changes." ;;
      esac
    fi
  fi
fi

target=$HOOKS_DIR/pre-commit
chain=$HOOKS_DIR/pre-commit.cld-chained
legacy=$HOOKS_DIR/pre-commit.pre-cld

# is_ours <file> -- the dispatcher, this version or an older one. The
# old one is recognised by two lines it always carried; a mere mention of
# "pre-commit.d" is not enough, many hook managers use that name.
is_ours() {
  grep -q 'marker: cld-dispatcher' "$1" 2>/dev/null && return 0
  grep -q '^# @brief Pre-commit dispatcher: run every executable in$' "$1" 2>/dev/null &&
    grep -qF 'dispatch_dir="$repo/scripts/git-hooks/pre-commit.d"' "$1" 2>/dev/null
}

if [ -e "$target" ] || [ -L "$target" ]; then
  if is_ours "$target"; then
    :
  elif [ -e "$chain" ] || [ -L "$chain" ]; then
    echo "install.sh: NOT INSTALLED -- two foreign hooks, and only a person can say which should run:" >&2
    echo "  $target is not the .cld dispatcher, and" >&2
    echo "  $chain already holds a hook chained by an earlier install." >&2
    echo "  Neither has been touched. Make $chain the one hook that should" >&2
    echo "  run before the .cld checks (merge the two by hand if both should)," >&2
    echo "  delete $target, and run this again." >&2
    exit 1
  else
    mv "$target" "$chain" || die "cannot move $target to $chain"
    echo "Chained: the pre-commit hook already installed is now"
    echo "  $chain"
    echo "  The dispatcher runs it first, on every commit; its failure still blocks."
  fi
fi

new=$HOOKS_DIR/.pre-commit.cld-new.$$
if ! { cp "$ours" "$new" && chmod 755 "$new" && mv -f "$new" "$target"; }; then
  rm -f "$new"
  die "cannot install $target"
fi
echo "Installed: $target"

if [ -e "$legacy" ] || [ -L "$legacy" ]; then
  echo "NOTE: $legacy is a hook an older install.sh set aside;"
  echo "  it is still NOT run, and it has been left as it is."
  if [ -e "$chain" ] || [ -L "$chain" ]; then
    echo "  To run it, merge it into $chain by hand."
  else
    echo "  To have the dispatcher run it: mv \"$legacy\" \"$chain\""
  fi
fi

echo ""
echo "The .cld checks have no sanctioned bypass -- fix the index."
