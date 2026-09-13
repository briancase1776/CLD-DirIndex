#!/bin/sh
# @brief Install the .cld git hooks into .git/hooks/. Run once per fresh
# clone: ./scripts/git-hooks/install.sh
#
# Safe to re-run, and safe to wire into a Claude Code SessionStart hook
# so a fresh clone is gated from the first commit.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$DIR" rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

mkdir -p "$HOOKS_DIR"

for hook in pre-commit; do
  if [ -e "$HOOKS_DIR/$hook" ] && ! cmp -s "$DIR/$hook" "$HOOKS_DIR/$hook"; then
    if ! grep -q 'pre-commit.d' "$HOOKS_DIR/$hook" 2>/dev/null; then
      echo "WARNING: $HOOKS_DIR/$hook exists and is not ours -- backing it up"
      cp "$HOOKS_DIR/$hook" "$HOOKS_DIR/$hook.pre-cld"
    fi
  fi
  cp "$DIR/$hook" "$HOOKS_DIR/$hook"
  chmod +x "$HOOKS_DIR/$hook"
  echo "Installed: $HOOKS_DIR/$hook"
done

echo ""
echo "The .cld checks have no sanctioned bypass -- fix the index."
