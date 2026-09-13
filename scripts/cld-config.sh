# scripts/cld-config.sh
# @brief Shared config loader for the .cld checkers -- defaults plus the
# host repo's optional cld.conf override.
#
# Sourced (never executed) by scripts/index-audit/check.sh. It sets every tunable to a default,
# then sources $CLD_REPO/cld.conf if that file exists so a host repo can
# override any of them. This file is the reason the checkers are
# portable: in the repo they were extracted from, every one of these
# values was a hardcoded literal naming that project's vendored trees.
#
# Contract: the caller sets CLD_REPO (the repo root) before sourcing.

# Paths that legitimately carry no index. A grep BRE, alternated with
# \| -- it is passed to plain `grep`, not `grep -E`.
CLD_SKIP_RE='\.git/\|node_modules/\|vendor/\|dist/\|build/'

# Extensions a DIRECTORY index is expected to list. A file outside this
# set (an image, a pdf, a binary) never raises NOENTRY. *.cld is always
# excluded regardless of this list -- an index never indexes itself.
CLD_INDEXABLE_EXTS="js md txt html css json sh"

# index.cld files that are NOT directory indexes -- same filename,
# different format. Empty by default; set it to a BRE if your repo has
# one (the source repo's Claude/summaries/index.cld was a cross-session
# index that happened to share the name).
CLD_NOT_DIR_INDEX_RE=''

# Host overrides. Last word wins.
[ -n "${CLD_REPO:-}" ] && [ -f "$CLD_REPO/cld.conf" ] && . "$CLD_REPO/cld.conf"

# A repo with no skip list at all would sweep .git; never allow that.
case "$CLD_SKIP_RE" in
  *'\.git/'*) : ;;
  '') CLD_SKIP_RE='\.git/' ;;
  *)  CLD_SKIP_RE='\.git/\|'"$CLD_SKIP_RE" ;;
esac
