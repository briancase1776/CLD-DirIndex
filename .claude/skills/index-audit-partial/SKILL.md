---
name: index-audit-partial
description: Check that the directory indexes you are about to commit still tell the truth -- run the mechanical index-freshness check over the STAGED diff, the same check the pre-commit hook runs. Reach for it before committing when you added, renamed, or removed a file, or to understand why the index-audit gate just blocked a commit. With no argument, audits the current staged diff.
---
Purpose: the pre-commit gate
(scripts/git-hooks/pre-commit.d/20-index-audit) blocks a commit whose
staged index.cld is out of sync with its directory -- an entry naming a
file that no longer exists (rename/delete side), or an indexable file
with no entry (add side). It is the same-commit index rule, made
mechanical. This skill runs that SAME engine
(scripts/index-audit/check.sh) on demand over the staged diff, so you can
see and fix index drift BEFORE you try to commit, and read a block when
it happens. The engine and the hook are two presets over one script.

Procedure:

1. Collect the staged diff:
   `git diff --cached --name-only --diff-filter=ACM`.
   If it is EMPTY, report "nothing staged" and stop. Do NOT fall through
   to the engine with no arguments -- with no args it audits the whole
   tree, which is the full sweep, not this partial gate.

2. Run the engine on exactly those paths:
   `git diff --cached --name-only --diff-filter=ACM \
     | xargs -r scripts/index-audit/check.sh`.

3. Read the findings and separate blocking from advisory:
   - ORPHAN [BLOCK]: a staged index.cld lists a file/dir that does not
     exist. Fix by dropping or correcting that entry -- name index + line.
   - NOENTRY [BLOCK]: a staged indexable file has no entry in its dir's
     index.cld -- you added a file without indexing it. Fix by adding the
     entry (with its brief-sourced gist). Both directions of the
     same-commit rule block: the skip list in cld.conf is the only place
     a "do not index" decision lives, so an unskipped file MUST be
     indexed.
   - BADHDR [warn]: an index.cld line 1 is not "INDEX <path/>".

4. Report which findings are blocking versus advisory, and OFFER each
   fix (which line to drop, which entry to add). Do NOT apply them here.

Notes:
- A clean result means every index.cld you touched still resolves -- say
  so plainly.
- To sweep the whole tree instead of the staged set, run the engine with
  no arguments. That is the health check, not the gate.
- If the engine itself errors (not a finding -- a broken invocation, a
  missing script), that is a bug, not an audit result -- report it, do
  not report a false clean.

Scope guard: READ-ONLY. This skill runs the checker and reports; it never
edits an index. Applying a fix -- dropping an orphan line, adding a
missing entry -- is the deliberate write step with its own same-commit
rule. That read-only stance is exactly what lets the same engine serve as
a safe blocking pre-commit gate.
