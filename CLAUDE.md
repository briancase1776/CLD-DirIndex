# CLD-DirIndex

This repo is one thing: the `.cld` **directory index** -- what is inside
a directory -- and the tooling that keeps those indexes honest. Its
sibling [CLD-FileIndex](https://github.com/briancase1776/CLD-FileIndex)
covers what is inside a *file*. Resist adding anything that is not
about indexing a directory.

## What it indexes

`index.cld`, one per directory. Line 1 `INDEX <path/>`, then one entry
per thing in that directory:

```
INDEX lib/
F cache.js           In-memory result cache over SQLite; mutex-guarded writes
L current.json       Symlink to the active config in versions/
D utils/             Low-level shared helpers
```

Type letters are find(1)'s `-type` codes uppercased -- `F D L P S B C`
-- and describe the entry, not what it points at. Spec:
`spec/dir-index-format.txt`.

This side is language-agnostic by construction -- a directory is a
directory whatever is in it -- which is why it is finished and the file
side is not.

## Working here

- This repo eats its own cooking: every directory carries an
  `index.cld`, and the pre-commit gate runs against this repo too.
  Install it with `./scripts/git-hooks/install.sh`.
- Keep `index.cld` current in the same commit. The gate will catch you,
  but the rule is what makes you not need catching.
- Run `tests/run-tests.sh` before committing a change to the checker.
  The suite builds throwaway git fixtures and asserts each finding code
  fires, and that a clean tree stays clean.
- `scripts/git-hooks/pre-commit` MUST stay byte-identical to the copy in
  CLD-FileIndex. See the contract section of the README.
- Portability is a feature, not a nicety: no bashisms, no GNU-only
  flags. The checker is POSIX `/bin/sh`. Anything project-specific
  belongs in `cld.conf`, never in the checker.

## Same-commit rule

Adding, removing, or renaming a file means updating that directory's
`index.cld` in the same commit. This is the whole discipline the
toolkit exists to support.
