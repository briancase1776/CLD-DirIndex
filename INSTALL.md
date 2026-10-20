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

Commit the toolkit first (step 1's files, with `cld.conf`), on its own
or with your next change: the gate runs the copy of the toolkit in each
commit, so it blocks a commit that leaves the toolkit out while the work
tree has it, and the installer warns until it is tracked.

```sh
./scripts/git-hooks/install.sh
```

Once per clone, and safe to re-run. It installs the dispatcher as two
hooks, `pre-commit` and `pre-merge-commit` (a merge that needs no hand
resolution runs only `pre-merge-commit`, so without it every clean
merge would skip the gate), into the hooks directory git actually uses
(`git rev-parse --git-path hooks`). Without `core.hooksPath` that is the
main repo's hooks directory, which every linked worktree shares, so one
install covers them all. With `core.hooksPath` it is that directory, and
the installer prints a warning, because such a directory may be shared
by other repos or sit inside the work tree; a **relative**
`core.hooksPath` (husky's `.husky/_` is one) is resolved against each
work tree's own top, so every linked worktree has its own copy and needs
its own install.

A pre-existing foreign hook of either name is **chained**, not replaced:
it is moved, unchanged, to `cld-chained/<name>` in the same hooks
directory -- keeping its name -- and the dispatcher runs it first on
every commit (its failure still blocks). It runs the way git would run
it: a shell script (a `#!` line naming a POSIX-family shell, or a text
file with none) with `$0` set to its original path, anything else, a
compiled hook included, directly and under its own name. So a hook
manager that dispatches on `basename "$0"` (husky, overcommit) or finds
its files through `dirname "$0"` (husky) still works. A hook that is a
symlink with a relative target is re-made in `cld-chained/` with one
more `../`, so it still resolves. A hook chained by an earlier install
as `<name>.cld-chained` is moved to `cld-chained/<name>`. A re-run never
overwrites a chained hook or an older backup. If a second foreign hook appears over
an existing chained one, the installer stops with exit 1 and touches
neither, since only a person can say which should run. A
`pre-commit.pre-cld` left by an older installer is pointed out, not
adopted. husky rewrites its hooks directory when it installs, which
drops the dispatcher again; with husky, the durable setup is a line in
`.husky/pre-commit` (and `.husky/pre-merge-commit`) that runs
`scripts/git-hooks/pre-commit`.

**Already installed an older version? Re-run the installer.** The hook
git runs is a copy, and an old copy keeps the old behaviour (the oldest
ignored deletions and renames and read the working tree; none installed
`pre-merge-commit`). The toolkit's checks refuse to run under a copy
that does not pass them `CLD_GATE_CONTRACT=2`, and block every commit
with "re-run scripts/git-hooks/install.sh" until it is replaced;
`--audit` also says when the installed hook differs from the dispatcher
in the commit.

To make it survive fresh clones without anyone remembering, merge
[`rules/settings.json.snippet`](rules/settings.json.snippet) into the
host repo's `.claude/settings.json`. It reinstalls the hooks on every
Claude Code session start, so a session started in a worktree with a
relative `core.hooksPath` installs there too.

What the gate does on each commit, in short: run the chained hook; read
the staged diff with renames off, so a rename is a deletion plus an
addition; take the checks from the commit, refusing a commit that drops
one `HEAD` has (renumbering one is fine); build a temp tree from the
index with `git checkout-index` (with `GIT_LFS_SKIP_SMUDGE=1` and
`core.autocrlf=false`, so no LFS download and no line-ending conversion;
`.gitattributes` filters still apply) holding the toolkit and every
directory a staged or deleted path is in -- the staged files and the
`.cld` files with their content, the other files there as empty
placeholders -- plus the targets the staged symbol indexes name; and
run each check there on the present paths, with the deleted ones after
`--gone`. So the cost follows the size of the commit, not of the repo,
and a file the commit does not touch is never checked out (a smudge
filter that fails on it cannot block). The whole index is copied
instead when a check would follow a symlink out of that tree (a staged
symlink, a symlinked `.cld`, a symbol index whose target is or runs
through one), when an index entry names a path below its own directory
(`F sub/x.js`), and for a custom check in `pre-commit.d` that does not
carry the line `# cld-gate: partial-tree`; that costs seconds on a big
repo. A check without `# cld-gate: paths-from` is called with argument
lists, several for a very large commit, and each line it prints is
shown once.

It blocks, loudly, when it cannot judge: a check that is not
executable, a checker missing from the tree, a `pre-commit.d` with no
checks, a commit that removes `pre-commit.d` or a check `HEAD` has (or
renames one to a name that is not a check), a commit made with the
toolkit in the work tree but not in the commit, a staged name holding a
newline, a temp tree that cannot be built, an installed hook older than
the toolkit, and any check exit other than 0. These exit 2, a finding
exits 1, and the footer says which it was (or that the chained hook
failed). A tree that
has never had `pre-commit.d`, in a work tree without one (an old branch,
another repo sharing a `core.hooksPath`), runs no `.cld` checks and says
so.

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
`pre-commit` and `pre-merge-commit` there, and if `cld-chained/` holds a
hook of either name, move it back (`mv cld-chained/pre-commit
pre-commit`; a symlink with a relative target was re-made there with one
more `../`, so re-make it without). Then delete the copied directories.
Nothing else in the repo depends on the toolkit; the `.cld` files
themselves are plain text and stay readable and useful on their own.
