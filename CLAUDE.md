# CLD-DirIndex

This repo is the `.cld` index toolkit: the two index formats and the
tooling that keeps them honest. The **directory index** (`index.cld`)
records what is inside a directory; the **symbol index**
(`<file>.cld`) records what is inside a file. The name is historical:
both halves live here. CLD-FileIndex, where the symbol half once lived
on its own, is superseded by this repo.

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

`<file>.cld`, beside its source. Line 1 `FILE <path>`, then one entry
per symbol worth knowing and one `I` entry per dependency, the module or
path exactly as the source writes it. One alphabet (`F C K D E G R I`)
with a meaning per language: js, py, sh, bash. Spec:
`spec/file-index-format.txt`.

## Working here

- This repo eats its own cooking: every directory carries an
  `index.cld`, and the pre-commit gate runs against this repo too.
  Install it with `./scripts/git-hooks/install.sh`. It installs into the
  hooks directory every linked worktree shares.
- Keep `index.cld` current in the same commit. The gate will catch you,
  but the rule is what makes you not need catching.
- Run `tests/run-tests.sh` before committing a change to a checker, the
  gate, the lookups or the shared scripts, and run it under dash and
  `bash --posix` too (`CLD_TEST_SH=dash`, `CLD_TEST_SH='bash --posix'`).
  The suite builds throwaway git fixtures and asserts each finding code
  fires, with a positive control wherever it asserts silence, and that a
  clean tree stays clean. A behaviour fix comes with a test that fails
  on the code before it.
- Portability is a feature, not a nicety: no bashisms, no GNU-only
  flags. Every script is POSIX `/bin/sh`. Anything project-specific
  belongs in `cld.conf`, never in a checker. A new `cld.conf` key goes
  in both `cld.conf` and `scripts/cld-config.sh`, with the same default.

## Same-commit rule

Adding, removing, or renaming a file means updating that directory's
`index.cld` in the same commit, and, for a source with a symbol index,
renaming or removing its `<file>.cld` with it. This is the whole
discipline the toolkit exists to support.
