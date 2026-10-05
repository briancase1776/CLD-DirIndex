---
name: index-audit-partial
description: Check that the directory indexes you are about to commit still tell the truth -- run the mechanical index-freshness check over the STAGED diff, the same check the pre-commit hook runs. Reach for it before committing when you added, renamed, or removed a file, or to understand why the index-audit gate just blocked a commit. With no argument, audits the current staged diff.
---
Purpose: the pre-commit gate blocks a commit whose indexes are out of
sync with what it commits. This skill runs the SAME dispatcher the hook
runs, in its read-only audit mode, so you see exactly what the hook would
see -- renames, deletions, names with spaces or non-ASCII characters --
and can fix the drift BEFORE you commit, or read a block after one.

Procedure:

1. From anywhere in the repo, run:
   `sh "$(git rev-parse --show-toplevel)/scripts/git-hooks/pre-commit" --audit`
   Do NOT build your own path list and do NOT call a checker directly:
   the dispatcher decides which paths each check is handed, and a
   hand-made list sees less than the hook does.

2. Read what it printed, in this order:
   - "nothing staged" (exit 0): say so and stop.
   - The routing: "present" paths are checked as they will be
     committed (from a temp tree built from the index, not from the
     working tree); "gone" paths are deleted or renamed away -- a rename
     shows as its old name gone and its new name present.
   - The findings of every check, then the verdict: "would let this
     commit through" (exit 0) or "would BLOCK" (exit 1).
   - Exit 2, or a line saying a check "could not check", is a broken
     setup (a missing or non-executable checker, a tree that could not
     be built) -- report it as that, never as a clean result.

3. Separate blocking findings from advisory ones:
   - ORPHAN [BLOCK]: an index.cld entry names something that is not in
     the commit -- including a path the commit deletes or renames away.
     Fix by dropping or correcting that entry: name index + line.
   - NOENTRY [BLOCK]: a committed indexable file has no entry in its
     directory's index.cld. Fix by adding the entry (with its
     brief-sourced gist). The skip list in cld.conf is the only place a
     "do not index" decision lives, so an unskipped file MUST be indexed.
   - SYM-* [BLOCK]: the symbol-index gate (SYM-HDR, SYM-DEAD, SYM-NAME,
     SYM-DUP, SYM-KEY) runs in the same pass; a <file>.cld left behind by
     a deletion or rename shows as SYM-DEAD.
   - Anything marked warn (BADHDR, WRONGTYPE, SYM-MISS, ...): advisory.

4. Report blocking versus advisory, and OFFER each fix (which line to
   drop, which entry to add). Do NOT apply them here.

Notes:
- A clean verdict means every check passed over exactly the staged
  content -- say so plainly. Unstaged edits do not count: stage them
  and run again if they are meant to be in the commit.
- --audit never runs a foreign hook that install.sh chained; only the
  .cld checks.
- To sweep the whole tree instead of the staged set, run
  scripts/index-audit/check.sh with no arguments. That is the health
  check, not the gate.

Scope guard: READ-ONLY. This skill runs the dispatcher in audit mode and
reports; it never edits an index and never stages anything. Applying a
fix is the deliberate write step with its own same-commit rule.
