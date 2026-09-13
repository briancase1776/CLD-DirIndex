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
cp -R /path/to/CLD-DirIndex/.claude/skills/filename-find       .claude/skills/
cp -R /path/to/CLD-DirIndex/.claude/skills/filename-dupecheck  .claude/skills/
cp    /path/to/CLD-DirIndex/cld.conf.example cld.conf
```

If the host repo already has a `scripts/` tree, copy only
`scripts/cld-config.sh`, `scripts/index-audit/`, `scripts/symbol-audit/`
and `scripts/git-hooks/`. The pre-commit dispatcher is drop-in by
design: it runs everything executable in `scripts/git-hooks/pre-commit.d/`
in lexical order, so an existing check tree survives untouched. Adjust
`spec/` paths in the rule block if you vendor the specs elsewhere.

## 2. Edit `cld.conf`

This is the whole configuration surface, and the only place a
project-specific decision belongs. At minimum set `CLD_SKIP_RE` to name
your vendored, generated, and binary trees, and `CLD_INDEXABLE_EXTS` to
the extensions your directory indexes are expected to list.

`CLD_SKIP_RE` is the **single** place a "do not index this" decision is
recorded. That is what lets `NOENTRY` block without being a judgment
call: if a file is not skipped there, its absence from its directory's
index is a real violation.

Every value is optional -- `scripts/cld-config.sh` supplies a default
for each. A repo with no `cld.conf` at all still works.

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
scripts/symbol-audit/check.sh     # same, for symbol indexes
```

Run either with no arguments for the full picture, or with a directory
to scope the sweep. Then write indexes directory by directory; each
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
