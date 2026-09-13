# CLD-DirIndex

This repo is one thing: the `.cld` index toolkit -- the two index
formats, the two mechanical checkers, the pre-commit gate, and the four
lookup skills. It was extracted from a larger project where the tooling
worked but shared context with an application domain that coloured every
decision about it. Narrow scope is the point. Resist adding anything
that is not about indexing a repository.

## The two species

- `index.cld` -- a DIRECTORY index. Line 1 `INDEX <path/>`, then one
  `F`/`D` entry per file or subdir. Spec: `spec/dir-index-format.txt`.
- `<filename>.cld` -- a per-file SYMBOL index. Line 1 `FILE <path>`,
  then one entry per symbol. Spec: `spec/file-index-format.txt`.

They share an extension and nothing else. Line 1 is the discriminator,
and every consumer selects on it.

## Working here

- This repo eats its own cooking: every directory carries an
  `index.cld`, and the pre-commit gate runs against this repo too.
  Install it with `./scripts/git-hooks/install.sh`.
- Keep `index.cld` current in the same commit. The gate will catch you,
  but the rule is what makes you not need catching.
- Run `tests/run-tests.sh` before committing a change to either checker.
  The suite builds throwaway git fixtures and asserts each finding code
  fires, and that a clean tree stays clean.
- Portability is a feature, not a nicety: no bashisms, no GNU-only
  flags. Both checkers are POSIX `/bin/sh`. Anything project-specific
  belongs in `cld.conf`, never in a checker.

## Same-commit rule

Adding, removing, or renaming a file means updating that directory's
`index.cld` in the same commit. Changing a symbol means updating that
file's `<filename>.cld` in the same commit. This is the whole discipline
the toolkit exists to support.
