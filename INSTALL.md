# Adopting the toolkit in another repository

The toolkit is files, not a package. Adoption is copying four things in
and editing one.

## 1. Copy the toolkit in

From the root of the host repo:

```sh
cp -R /path/to/CLD-DirIndex/spec            spec/
cp -R /path/to/CLD-DirIndex/scripts         scripts/
cp -R /path/to/CLD-DirIndex/.claude/skills/index-find          .claude/skills/
cp -R /path/to/CLD-DirIndex/.claude/skills/index-audit-partial .claude/skills/
cp    /path/to/CLD-DirIndex/cld.conf          cld.conf
```

If the host repo already has a `scripts/` tree, copy only
`scripts/cld-config.sh`, `scripts/index-audit/` and
`scripts/git-hooks/`. The pre-commit dispatcher is drop-in by design: it
runs everything executable in `scripts/git-hooks/pre-commit.d/` in
lexical order, so an existing check tree survives untouched. Adjust
`spec/` paths in the rule block if you vendor the specs elsewhere.

Adopting [CLD-FileIndex](https://github.com/briancase1776/CLD-FileIndex)
as well? Its `scripts/git-hooks/pre-commit` is byte-identical to this
one by contract, so copy either -- then both `20-index-audit` and
`30-symbol-audit` sit in `pre-commit.d/` and run in order.

## 2. Edit `cld.conf`

The file you copied is the shipped default, with every setting active
and set to its default value -- editing means changing a value, not
hunting for which line to uncomment. It is the whole configuration
surface, and the only place a project-specific decision belongs.

Set `CLD_SKIP_RE` to name your vendored, generated, and binary trees,
and `CLD_INDEXABLE_EXTS` to the extensions your directory indexes are
expected to list.

`CLD_SKIP_RE` is the **single** place a "do not index this" decision is
recorded. That is what lets `NOENTRY` block without being a judgment
call: if a file is not skipped there, its absence from its directory's
index is a real violation.

Every value is optional -- `scripts/cld-config.sh` supplies a fallback
for each, so a repo with no `cld.conf` at all still works. The two
files are kept in sync by the test suite: adding a setting to one
without the other fails the run.


## 3. Add the rules to `CLAUDE.md`

Paste [`rules/CLAUDE.md.snippet`](rules/CLAUDE.md.snippet) into the host
repo's `CLAUDE.md`. This is the half nothing mechanical can enforce: the
checkers catch a stale index, but only the rule makes an agent *check*
an index before hunting, and update one in the same commit.

## 4. Install the gate

```sh
./scripts/git-hooks/install.sh
```

Once per clone. The installer backs up a pre-existing foreign
`pre-commit` hook to `pre-commit.pre-cld` before replacing it, so nothing
is silently lost.

To make it survive fresh clones without anyone remembering, merge
[`rules/settings.json.snippet`](rules/settings.json.snippet) into the
host repo's `.claude/settings.json`. It reinstalls the hooks on every
Claude Code session start.

## 5. Backfill the indexes

A repo adopting this mid-life has no indexes yet. The gate is
fix-what-you-touch by design -- it only inspects files in the staged
diff -- so it will not hold the whole backfill hostage. Two ways to
work through it:

```sh
scripts/index-audit/check.sh      # sweep the whole tree
scripts/index-audit/check.sh lib/ # or scope it to a directory
```

Run it with no arguments for the full picture, or with a directory to
scope the sweep. Then write indexes directory by directory; each
commit's gate keeps the ground you have already taken.

## Verifying

```sh
tests/run-tests.sh
```

The suite builds throwaway git repos, so it neither reads nor touches
the host repo. It asserts that each finding code fires when it should,
stays quiet when it should not, and that the installed hook blocks a
real commit.

## Uninstalling

Remove `.git/hooks/pre-commit` (restore `pre-commit.pre-cld` if the
installer backed one up), and delete the copied directories. Nothing
else in the repo depends on the toolkit -- the `.cld` files themselves
are plain text and stay readable and useful on their own.
