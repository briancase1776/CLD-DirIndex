# Adopting the toolkit in another repository

The toolkit is files, not a package. Adoption is copying a few things in
and editing one.

## 1. Copy the toolkit in

From the root of the host repo:

```sh
T=/path/to/CLD-DirIndex
mkdir -p .claude/skills
cp -R "$T/spec"     spec
cp -R "$T/scripts"  scripts
cp    "$T/cld.conf" cld.conf
for s in index-find index-audit-partial \
         symbol-find-js symbol-find-py symbol-find-sh symbol-find-bash \
         symbol-dupecheck-js symbol-dupecheck-py symbol-dupecheck-sh symbol-dupecheck-bash \
         symbol-deps; do
  cp -R "$T/.claude/skills/$s" .claude/skills/
done
```

Copy only the skills for the languages you use; `index-find`,
`index-audit-partial` and `symbol-deps` are language-neutral.

The layout under `scripts/` is fixed: the gate looks for
`scripts/git-hooks/pre-commit.d/` and the checkers at
`scripts/index-audit/check.sh` and `scripts/symbol-audit/check.sh`,
from the repo root, and every script finds the shared files through
`../`. If the host repo already has a `scripts/` tree, copy in exactly
these and leave the rest alone:

```
scripts/cld-lib.sh        scripts/index-audit/
scripts/cld-config.sh     scripts/symbol-audit/
scripts/cld-symbol.sh     scripts/symbol-lookup/
                          scripts/git-hooks/
```

The specs can live anywhere; adjust the `spec/` paths in the rule block
if you put them elsewhere. Every directory you copy carries its own
`index.cld` (`spec/`, `scripts/` and each directory under it, each
skill directory), so the toolkit is index-clean in the host repo from
the start. What it cannot bring is the host's own entries for it: add
`D spec/` and `D scripts/` to the host's root `index.cld` and a `D` line
per skill to `.claude/skills/index.cld` (or, if the host already had a
`scripts/`, the toolkit's lines from its `scripts/index.cld` to the
host's). A sweep (step 5) lists anything missed.

The dispatcher is drop-in by design. A check is any file in
`scripts/git-hooks/pre-commit.d/` whose name starts with a digit
(`NN-name`, numbered in tens so a new one slots in between), run in
name order. A check must be executable: one that has lost its x bit
**blocks** the commit rather than being skipped. Files not starting
with a digit (its `index.cld`) are not checks.

Coming from CLD-FileIndex, or from an install of both halves? This repo
supersedes it. Replace the copied `scripts/` with this one (it has both
checkers and one shared loader), delete `.claude/skills/filename-find`
and `.claude/skills/filename-dupecheck` (replaced by the `symbol-*`
skills), and re-run the installer (step 4).

## 2. Edit `cld.conf`

The file you copied is the shipped default, with every setting active
and set to its default value: editing means changing a value, not
hunting for which line to uncomment. It is the whole configuration
surface, and the only place a project-specific decision belongs. It is
sourced by `/bin/sh`; a `CLD_*` variable in the environment is ignored.

In order of how likely it is to matter (the defaults are in `cld.conf`
itself):

- `CLD_EXTRA_SPECIES` (empty): extra line-1 tokens symbol-audit accepts
  besides `FILE` and `INDEX`. Set it first if your repo mints its own
  `.cld` species, or every one of those files is `SYM-HDR`.
- `CLD_SKIP_RE`: trees that carry no index at all (a grep BRE; `.git/`
  is always added). Name your vendored, generated and binary trees.
- `CLD_INDEXABLE_EXTS` (`js md txt html css json sh`): the extensions a
  directory index must list (`NOENTRY`); `.cld` never.
- `CLD_NOT_DIR_INDEX_RE` (empty): `index.cld` files in some other
  format; exempt from every check and lookup.
- `CLD_NOT_SYMBOL_INDEX_RE` (empty): `.cld` files that borrow the `FILE`
  header but are not symbol indexes; exempt from every symbol check and
  lookup.
- `CLD_SYM_MISS_LANGS` (`js`): the languages `SYM-MISS` watches. Add
  `py`, `sh`, `bash` to turn them on; leaving `js` out turns the js rule
  off.
- `CLD_SYM_MISS_EXTS` (`js`) and `CLD_DECL_RE` (an ERE for `grep -E`):
  the js `SYM-MISS` rule, the files to look at and what counts as a
  declaration. py, sh and bash use built-in declaration patterns.
- `CLD_SYM_MISS_SKIP_RE`: trees `SYM-MISS` leaves alone (tests, vendored
  code).
- `CLD_LANG_EXT_MAP` (`js:js py:py sh:sh bash:bash`): extension to
  language, step 3 of the detection order (a `lang` line, the `#!`
  line, this map, file(1)). Add `mjs:js` and the like here.

`CLD_SKIP_RE` is the **single** place a "do not index this" decision is
recorded. That is what lets `NOENTRY` block without being a judgment
call: if a file is not skipped there, its absence from its directory's
index is a real violation.

The skip patterns alternate with `\|`, a GNU and BusyBox grep extension
that POSIX does not define for BREs (see the README). A value may build
on its default: `CLD_SKIP_RE="$CLD_SKIP_RE\|third_party/"`.

Every value is optional: `scripts/cld-config.sh` supplies the default
for any key `cld.conf` leaves out, so a repo with no `cld.conf`, or one
written before a key existed, still works. The two files are kept in
sync by the test suite: adding a key to one without the other fails the
run. A key set to the empty string stays empty.

## 3. Add the rules to `CLAUDE.md`

Paste [`rules/CLAUDE.md.snippet`](rules/CLAUDE.md.snippet) into the host
repo's `CLAUDE.md`. This is the half nothing mechanical can enforce: the
checkers catch a stale index, but only the rule makes an agent *check*
an index before hunting, and update one in the same commit.

## 4. Install the gate

```sh
./scripts/git-hooks/install.sh
```

Once per clone, and safe to re-run. It installs into the hooks directory
git actually uses (`git rev-parse --git-path hooks`), which is the one
shared directory of the main repo when run from a linked worktree, and
`core.hooksPath` when that is set; it prints a warning in that case,
because such a directory may be shared by other repos or sit inside the
work tree.

A pre-existing foreign `pre-commit` hook is **chained**, not replaced:
it is moved, unchanged, to `pre-commit.cld-chained` in the same hooks
directory, and the dispatcher runs it first on every commit (its failure
still blocks). A re-run never overwrites a chained hook or an older
backup. If a second foreign hook appears over an existing chained one,
the installer stops with exit 1 and touches neither, since only a
person can say which should run. A `pre-commit.pre-cld` left by an older
installer is pointed out, not adopted.

**Already installed an older version? Re-run the installer.** The hook
git runs is a copy, and an old copy keeps the old behaviour (it ignored
deletions and renames and read the working tree) until it is replaced.

To make it survive fresh clones without anyone remembering, merge
[`rules/settings.json.snippet`](rules/settings.json.snippet) into the
host repo's `.claude/settings.json`. It reinstalls the hooks on every
Claude Code session start. Because every linked worktree shares one
hooks directory, a session started in any worktree installs for all of
them.

What the gate does on each commit, in short: run the chained hook;
read the staged diff with renames off, so a rename is a deletion plus an
addition; copy the index into a temp tree with `git checkout-index`
(with `GIT_LFS_SKIP_SMUDGE=1` and `core.autocrlf=false`, so no LFS
download and no line-ending conversion; `.gitattributes` filters still
apply); and run each check there on the present paths, with the deleted
ones after `--gone`. The checks and checkers that run are the copies in
the commit itself. A very large commit is split into several calls so
no argument list overflows. Cost grows with the repo, since the whole
index is copied: about three seconds for thirty thousand files.

It blocks, loudly, when it cannot judge: a check that is not
executable, a checker missing from the tree, a `pre-commit.d` with no
checks, a commit that removes `pre-commit.d` while `HEAD` has it, a
staged name holding a newline, a temp tree that cannot be built, and any
check exit other than 0. A tree that has never had `pre-commit.d` (an
old branch, another repo sharing a `core.hooksPath`) runs no `.cld`
checks and says so.

To see a block coming, run the same checks over the staged diff without
committing:

```sh
scripts/git-hooks/pre-commit --audit   # or the index-audit-partial skill
```

## 5. Backfill the indexes

A repo adopting this mid-life has no indexes yet. The gate is
fix-what-you-touch by design (it inspects only what the staged diff
touches), so it will not hold the whole backfill hostage. Sweep to see
the ground:

```sh
scripts/index-audit/check.sh         # the whole tree
scripts/index-audit/check.sh lib/    # or one directory (lib, ./lib, lib/ alike)
scripts/symbol-audit/check.sh        # every symbol index
```

A sweep adds the warnings the gate never raises: `NOINDEX` for a
directory with indexable files and no `index.cld`, and `NODENTRY` for a
subdirectory missing from its parent's index. Then write indexes
directory by directory; each commit's gate keeps the ground you have
already taken.

For symbol indexes, turn on `SYM-MISS` for the languages you index
(`CLD_SYM_MISS_LANGS`) once you are ready for the warnings.

## Verifying

In the host repo, a sweep of both checkers is the check that matters:

```sh
scripts/index-audit/check.sh && scripts/symbol-audit/check.sh
```

The test suite is not copied into the host; run it in the toolkit's own
checkout:

```sh
tests/run-tests.sh
CLD_TEST_SH=dash tests/run-tests.sh
CLD_TEST_SH='bash --posix' tests/run-tests.sh
```

It builds throwaway git repos, so it neither reads nor touches any other
repo. It asserts that each finding fires when it should, stays quiet
when it should not (always with a positive control, so a check that
silently stops working fails a test), and that the installed hook blocks
and passes real commits. Point `CLD_TEST_TOOLKIT` at another checkout of
the toolkit to run this suite against that code.

## Uninstalling

Find the hooks directory with `git rev-parse --git-path hooks`. Remove
`pre-commit` there, and if `pre-commit.cld-chained` exists, move it back
to `pre-commit`. Then delete the copied directories. Nothing else in the
repo depends on the toolkit; the `.cld` files themselves are plain text
and stay readable and useful on their own.
