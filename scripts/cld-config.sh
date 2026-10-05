# scripts/cld-config.sh
# @brief Shared config loader for the .cld checkers -- defaults plus the
# host repo's optional cld.conf override.
#
# Sourced (never executed) by scripts/index-audit/check.sh and
# scripts/symbol-audit/check.sh, after scripts/cld-lib.sh has found the
# repo. It gives every tunable a default and sources $CLD_REPO/cld.conf
# if that file exists so a host repo can override any of them. This file
# is the reason the checkers are portable: in the repo they were
# extracted from, every one of these values was a hardcoded literal
# naming that project's vendored trees.
#
# Contract: the caller sets CLD_REPO (the repo root) before sourcing.
#
# How a value is decided, in order:
#   1. every key is UNSET, so a stray variable in the environment can
#      never change what a gate checks -- config lives in cld.conf only;
#   2. every key gets its default (so a cld.conf may build on one:
#      CLD_SKIP_RE="$CLD_SKIP_RE\|third_party/");
#   3. cld.conf is sourced, if there is one;
#   4. every key is defaulted AGAIN with ${X-default}, so a partial or
#      older cld.conf -- one written before a key existed, or one that
#      unsets a key -- can never leave a checker running under set -u
#      with a variable that is not set.
# A key cld.conf sets to the empty string stays empty: ${X-...}, not
# ${X:-...}, so "empty" is a value a host can choose.
#
# Every key here must also appear, set to the same default, in the
# shipped cld.conf; tests/cases/00-foundation.sh enforces that.

cld_config_defaults() {
# Paths that legitimately carry no index. A grep BRE, alternated with
# \| -- it is passed to plain `grep`, not `grep -E`.
CLD_SKIP_RE=${CLD_SKIP_RE-'\.git/\|node_modules/\|vendor/\|dist/\|build/'}

# Extensions a DIRECTORY index is expected to list. A file outside this
# set (an image, a pdf, a binary) never raises NOENTRY. *.cld is always
# excluded regardless of this list -- an index never indexes itself.
CLD_INDEXABLE_EXTS=${CLD_INDEXABLE_EXTS-"js md txt html css json sh"}

# index.cld files that are NOT directory indexes -- same filename,
# different format. Empty by default; set it to a BRE if your repo has
# one (the source repo's Claude/summaries/index.cld was a cross-session
# index that happened to share the name).
CLD_NOT_DIR_INDEX_RE=${CLD_NOT_DIR_INDEX_RE-''}

# .cld files that carry a FILE header but are NOT symbol indexes --
# another domain that borrowed the species token. Empty by default; set
# it to a BRE to exempt them from symbol-audit and from the symbol
# lookup skills (the source repo's notes/the-plan*.cld were exactly
# this).
CLD_NOT_SYMBOL_INDEX_RE=${CLD_NOT_SYMBOL_INDEX_RE-''}

# Line-1 tokens symbol-audit accepts as a known non-symbol .cld species.
# FILE and INDEX are built in; list any extra species your repo mints
# here, space separated, or SYM-HDR will block on them.
CLD_EXTRA_SPECIES=${CLD_EXTRA_SPECIES-""}

# SYM-MISS (warn): a source file that declares symbols but has no
# <file>.cld beside it. The extensions to consider, the ERE that counts
# as a declaration, and the trees to leave alone.
CLD_SYM_MISS_EXTS=${CLD_SYM_MISS_EXTS-"js"}
CLD_DECL_RE=${CLD_DECL_RE-'^[[:space:]]*class |^function '}
CLD_SYM_MISS_SKIP_RE=${CLD_SYM_MISS_SKIP_RE-'tests/\|vendor/\|node_modules/'}
}

unset CLD_SKIP_RE CLD_INDEXABLE_EXTS CLD_NOT_DIR_INDEX_RE \
      CLD_NOT_SYMBOL_INDEX_RE CLD_EXTRA_SPECIES \
      CLD_SYM_MISS_EXTS CLD_DECL_RE CLD_SYM_MISS_SKIP_RE
cld_config_defaults

# Host overrides. Last word wins.
if [ -n "${CLD_REPO:-}" ] && [ -f "$CLD_REPO/cld.conf" ]; then
  . "$CLD_REPO/cld.conf"
fi

cld_config_defaults

# A repo with no skip list at all would sweep .git; never allow that.
case "$CLD_SKIP_RE" in
  *'\.git/'*) : ;;
  '') CLD_SKIP_RE='\.git/' ;;
  *)  CLD_SKIP_RE='\.git/\|'"$CLD_SKIP_RE" ;;
esac
