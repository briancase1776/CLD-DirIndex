#!/bin/sh
# scripts/git-hooks/install.sh
# @brief Install the .cld dispatcher as the pre-commit and pre-merge-commit
# hooks git actually runs, chaining any foreign hook already there.
#
# Usage: ./scripts/git-hooks/install.sh   (once per clone; safe to re-run,
# and safe to wire into a Claude Code SessionStart hook so a fresh clone
# is gated from the first commit)
#
# Two hooks, one dispatcher: pre-commit, and pre-merge-commit, which git
# runs INSTEAD of pre-commit for a merge that needs no hand resolution --
# without it every clean merge would skip the gate.
#
# Where it installs: wherever `git rev-parse --git-path hooks` says,
# asked from this script's own directory. Without core.hooksPath that is
# the main repo's hooks directory, which every linked worktree shares, so
# one install from any worktree covers them all. With core.hooksPath it
# is that directory, and this prints a WARNING, because such a directory
# may be shared by other repos, or be part of a work tree -- and a
# RELATIVE core.hooksPath (husky's .husky/_ is one) is resolved against
# each work tree's own top, so every linked worktree has its own hooks
# directory and this must be run in each of them (the SessionStart hook
# does, once per session), or the hook committed.
#
# A foreign hook of either name is CHAINED, never just backed up: it is
# moved, unchanged and under its own name, to cld-chained/<name> in the
# same hooks directory, and the dispatcher runs it first on every commit
# (its failure still blocks) -- a shell script with $0 set to its
# original path, so a hook manager that finds itself through $0 (husky,
# a basename "$0" dispatcher) still works; anything else, a compiled
# hook included, where it lies, which keeps at least its name. A hook
# that is a symlink with a relative target is re-made in cld-chained/
# with one more "../", so it still resolves. Nothing is ever overwritten:
#   - our own dispatcher (current, or as shipped before it carried the
#     cld-dispatcher marker) is simply replaced by the current one;
#   - <name>.cld-chained, where an earlier install chained a hook under a
#     changed name, is moved to cld-chained/<name>;
#   - a foreign hook found while a chained one already exists (another
#     tool replaced the dispatcher after an earlier install) is an
#     ambiguity only a person can settle: this stops with exit 1 and
#     touches nothing, for either hook;
#   - pre-commit.pre-cld, the backup an older install.sh made (and then
#     stopped running), is left alone and pointed out.
#
# It also warns when the toolkit itself is not committed yet: the gate
# runs the copy in each commit, and blocks a commit that lacks it.
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
CHAINED=$HOOKS_DIR/cld-chained
top=$(cd "$DIR" && git rev-parse --show-toplevel 2>/dev/null) || top=
[ -z "$top" ] || top=$(CDPATH= cd "$top" && pwd -P) || :

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
    if [ -n "$top" ]; then
      case "$HOOKS_DIR/" in
        "$top"/*)
          echo "  That directory is inside this work tree: the installed hook and"
          echo "  any chained copy will show up there as changes." ;;
      esac
    fi
    case $hooks_path in
      /*|'~'*) : ;;
      *)
        echo "  core.hooksPath is RELATIVE, so git resolves it against each work"
        echo "  tree's own top: every linked worktree has its own $hooks_path, and"
        echo "  this install covers only this one. Run install.sh in each"
        echo "  worktree (the SessionStart hook in rules/settings.json.snippet does,"
        echo "  once per session), or commit the hook." ;;
    esac
  fi
fi

tracked=$(cd "$DIR" && git ls-files -- pre-commit.d 2>/dev/null) || tracked=
if [ -z "$tracked" ]; then
  echo "WARNING: the toolkit is not committed yet (scripts/git-hooks/pre-commit.d"
  echo "  is not tracked). The gate runs the copy of the toolkit in each commit,"
  echo "  so it blocks every commit made without one: commit scripts/ and"
  echo "  cld.conf first, on their own or with your next change."
fi

# is_ours <file> -- the dispatcher, this version or an older one. The
# old one is recognised by two lines it always carried; a mere mention of
# "pre-commit.d" is not enough, many hook managers use that name.
is_ours() {
  grep -q 'marker: cld-dispatcher' "$1" 2>/dev/null && return 0
  grep -q '^# @brief Pre-commit dispatcher: run every executable in$' "$1" 2>/dev/null &&
    grep -qF 'dispatch_dir="$repo/scripts/git-hooks/pre-commit.d"' "$1" 2>/dev/null
}

there() { [ -e "$1" ] || [ -L "$1" ]; }

# set_aside <hook> <dest> -- move a hook from the hooks directory into
# cld-chained/, unchanged. A symlink whose target is relative would
# dangle one directory down, so it is made again there with one more
# "../" in front (ls -l prints a link as "name -> target"; POSIX says so).
set_aside() {
  mkdir -p "$CHAINED" || die "cannot create $CHAINED"
  if [ -L "$1" ]; then
    sa_l=$(ls -ld -- "$1") || die "cannot read the symlink $1"
    sa_t=${sa_l#*" $1 -> "}
    [ "$sa_t" != "$sa_l" ] && [ -n "$sa_t" ] || die "cannot read the symlink $1"
    case $sa_t in
      /*) mv "$1" "$2" || die "cannot move $1 to $2" ;;
      *) { ln -s "../$sa_t" "$2" && rm -f "$1"; } || die "cannot re-link $1 as $2" ;;
    esac
  else
    mv "$1" "$2" || die "cannot move $1 to $2"
  fi
}

# First pass: refuse before anything moves.
for h in pre-commit pre-merge-commit; do
  target=$HOOKS_DIR/$h
  chained=$CHAINED/$h
  older=$HOOKS_DIR/$h.cld-chained
  if there "$older" && there "$chained"; then
    echo "install.sh: NOT INSTALLED -- two chained $h hooks, and only a person can say which should run:" >&2
    echo "  $older and" >&2
    echo "  $chained." >&2
    echo "  Neither has been touched. Keep the one that should run (merge them by" >&2
    echo "  hand if both should) as $chained, delete the other, and run this again." >&2
    exit 1
  fi
  if there "$target" && ! is_ours "$target" && { there "$chained" || there "$older"; }; then
    there "$chained" || chained=$older
    echo "install.sh: NOT INSTALLED -- two foreign $h hooks, and only a person can say which should run:" >&2
    echo "  $target is not the .cld dispatcher, and" >&2
    echo "  $chained already holds a hook chained by an earlier install." >&2
    echo "  Neither has been touched. Make $CHAINED/$h the one hook that should" >&2
    echo "  run before the .cld checks (merge the two by hand if both should)," >&2
    echo "  delete $target, and run this again." >&2
    exit 1
  fi
done

# Second pass: chain, then install.
for h in pre-commit pre-merge-commit; do
  target=$HOOKS_DIR/$h
  chained=$CHAINED/$h
  older=$HOOKS_DIR/$h.cld-chained
  if there "$older"; then
    set_aside "$older" "$chained"
    echo "Moved: the hook chained as $older"
    echo "  is now $chained, under its own name."
  fi
  if there "$target" && ! is_ours "$target"; then
    husky=0
    if grep -q husky "$target" 2>/dev/null || [ -f "$HOOKS_DIR/h" ] || [ -f "$HOOKS_DIR/husky.sh" ]; then
      husky=1
    fi
    set_aside "$target" "$chained"
    echo "Chained: the $h hook already installed is now"
    echo "  $chained"
    echo "  The dispatcher runs it first, on every commit, as $target"
    echo "  (a shell script sees that path as \$0; anything else keeps its name);"
    echo "  its failure still blocks."
    if [ "$husky" -eq 1 ]; then
      echo "NOTE: this looks like a husky hooks directory. husky rewrites it when it"
      echo "  installs (npm install), which removes the dispatcher again. For a gate"
      echo "  that stays, run scripts/git-hooks/pre-commit from .husky/$h instead."
    fi
  fi
  new=$HOOKS_DIR/.$h.cld-new.$$
  if ! { cp "$ours" "$new" && chmod 755 "$new" && mv -f "$new" "$target"; }; then
    rm -f "$new"
    die "cannot install $target"
  fi
  echo "Installed: $target"
done

legacy=$HOOKS_DIR/pre-commit.pre-cld
if there "$legacy"; then
  echo "NOTE: $legacy is a hook an older install.sh set aside;"
  echo "  it is still NOT run, and it has been left as it is."
  if there "$CHAINED/pre-commit"; then
    echo "  To run it, merge it into $CHAINED/pre-commit by hand."
  else
    echo "  To have the dispatcher run it: mkdir -p \"$CHAINED\" && mv \"$legacy\" \"$CHAINED/pre-commit\""
  fi
fi

echo ""
echo "The .cld checks have no sanctioned bypass -- fix the index."
