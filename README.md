# CLD-DirIndex

A small, self-contained toolkit for keeping a repository's `.cld` index
files honest -- the formats, two mechanical checkers, a pre-commit gate,
and four lookup skills for Claude Code.

Extracted from a larger project where the tooling worked well but shared
context with an application domain that coloured every decision about it.
Here the scope is one thing: indexing a repository.

## What a `.cld` file is

A plain-text index that sits next to what it describes. Two species,
told apart by line 1 and by nothing else:

**Directory index** -- `index.cld`, one per directory:

```
INDEX lib/
F cache.js           In-memory result cache over SQLite; mutex-guarded writes
F errors.js          Error and perf logging; see notes/errors.md
D utils/             Low-level shared helpers
```

**Symbol index** -- `<filename>.cld`, one per source file:

```
FILE lib/example.js
C ExamplePanel          Loads the example sub-section HTML fragments
F ExamplePanel.#load    Fetches each section HTML in order and appends it
D #oHooks               Callback bundle handed in by core at construction
K #kDefaults            Default settings used for init and reset
R (resize-listener)     Anonymous window resize listener installed at import
```

The point of both: an agent arriving cold can find the right file, or
the right symbol, by what it *does* -- without walking the tree or
grepping every source file. The index is the map. It only works if the
map is true, which is what the rest of this repo is for.

Full rules: [`spec/dir-index-format.txt`](spec/dir-index-format.txt) and
[`spec/file-index-format.txt`](spec/file-index-format.txt).

## What's in the box

| Piece | What it does |
|---|---|
| `spec/` | The two format specs -- the authority on how an index is written |
| `scripts/index-audit/check.sh` | Directory-index checker: ORPHAN, NOENTRY, BADHDR |
| `scripts/symbol-audit/check.sh` | Symbol-index checker: SYM-DEAD, SYM-NAME, SYM-DUP, SYM-HDR, SYM-KEY, SYM-BRIEF, SYM-MISS |
| `scripts/git-hooks/` | Pre-commit dispatcher, the two gates, and the installer |
| `.claude/skills/` | `index-find`, `filename-find`, `filename-dupecheck`, `index-audit-partial` |
| `rules/` | The CLAUDE.md block and settings fragment to paste into a host repo |
| `cld.conf.example` | Every project-specific value, in one place outside the checkers |
| `tests/run-tests.sh` | 47 assertions over throwaway git fixtures |

## The three layers

**Format** is the spec. **Rule** is the same-commit discipline in
`CLAUDE.md`: update the index in the commit that changes the thing it
describes, and check the index before hunting for a file. **Gate** is the
pre-commit hook, which catches the rule being forgotten.

All three are needed. The gate alone cannot make an agent *read* an
index before grepping; the rule alone rots the moment someone is in a
hurry.

## Findings

Directory indexes (`scripts/index-audit/check.sh`):

- `ORPHAN` **blocks** -- an entry names a file or dir that does not exist
- `NOENTRY` **blocks** -- an indexable file has no entry in its dir index
- `BADHDR` *warns* -- line 1 is not `INDEX <path/>`

Symbol indexes (`scripts/symbol-audit/check.sh`):

- `SYM-DEAD` **blocks** -- the target file does not exist
- `SYM-NAME` **blocks** -- not named `<target-basename>.cld`
- `SYM-DUP` **blocks** -- two indexes claim one target
- `SYM-HDR` **blocks** -- unknown line-1 species
- `SYM-KEY` **blocks** -- field 2 is not a usable lookup key
- `SYM-BRIEF` *warns* -- no brief marker near a symbol's declaration
- `SYM-MISS` *warns* -- a declaring source file with no symbol index

Blocking findings are the ones that cannot false-positive or are scoped
so tightly they may as well not. Everything judgment-shaped warns.

## Quick start

```sh
git clone https://github.com/briancase1776/CLD-DirIndex
cd CLD-DirIndex
./scripts/git-hooks/install.sh   # gate this repo
tests/run-tests.sh               # 47 passed, 0 failed
```

To adopt it in another repository, see [INSTALL.md](INSTALL.md).

## Portability

Both checkers are POSIX `/bin/sh` with no bashisms and no GNU-only
flags. Everything project-specific -- vendored trees, indexable
extensions, extra `.cld` species, the brief marker -- lives in
`cld.conf` at the host repo's root, never in a checker. Copy
`cld.conf.example` and edit.
