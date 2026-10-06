# CLD-DirIndex

A small, self-contained toolkit for keeping a repository's `.cld` index
files honest: the two formats, two mechanical checkers, a pre-commit
gate, and lookup skills for Claude Code.

The name is historical. This repo holds **both** species of index, the
directory index and the per-file symbol index. For a while the symbol
side lived apart, in
[CLD-FileIndex](https://github.com/briancase1776/CLD-FileIndex); that
repo is superseded by this one and holds nothing this one lacks.

## What a `.cld` file is

A plain-text index that sits next to what it describes. Two species,
told apart by line 1:

**Directory index**: `index.cld`, one per directory, one entry per thing
in it.

```
INDEX lib/
F cache.js           In-memory result cache over SQLite; mutex-guarded writes
L current.json       Symlink to the active config in versions/
D utils/             Low-level shared helpers
```

The type letters are find(1)'s `-type` codes, uppercased: `F` file,
`D` directory, `L` symlink, `P` fifo, `S` socket, `B` block device,
`C` character device. The letter describes the **entry**, not what it
points at: a symlink is `L` even when it resolves to a regular file. In
a git repo you will only see `F`, `D` and `L`, because git cannot store
the others.

**Symbol index**: `<filename>.cld` beside its source file
(`lib/example.js.cld`), one entry per symbol worth knowing, and one per
dependency.

```
FILE lib/example.js
C ExamplePanel          Loads the example sub-section HTML fragments
F ExamplePanel.#load    Fetches each section HTML in order and appends it
D #oHooks               Callback bundle handed in by core at construction
K #kDefaults            Default settings used for init and reset
R (resize-listener)     Anonymous window resize listener installed at import
I ./section-loader.js   fetchSection, used by both #load methods
```

The point of both: an agent arriving cold can find the right file, or
the right symbol, by what it *does*, without walking the tree or
grepping every source file. The index is the map. It only works if the
map is true, which is what the rest of this repo is for.

The `I` letter matters most on a big project. "What does this file use"
and "what uses this file" are the questions a cold agent cannot answer
without grepping for every `import`, `require`, `source` and `.` line
in the tree. An `I` entry records the module or path exactly as the
source writes it, so `deps` and `rdeps` answer from the indexes.

Full rules: [`spec/dir-index-format.txt`](spec/dir-index-format.txt) and
[`spec/file-index-format.txt`](spec/file-index-format.txt).

## What's in the box

| Piece | What it does |
|---|---|
| `spec/` | The two format specs, the authority on how an index is written |
| `scripts/index-audit/check.sh` | Directory-index checker |
| `scripts/symbol-audit/check.sh` | Symbol-index checker |
| `scripts/symbol-lookup/lookup.sh` | Symbol lookups: `find`, `dupecheck`, `deps`, `rdeps` |
| `scripts/cld-lib.sh`, `cld-config.sh`, `cld-symbol.sh` | Shared library, config loader, symbol-side helpers |
| `scripts/git-hooks/` | The pre-commit dispatcher, its two drop-in checks, and the installer |
| `.claude/skills/` | `index-find`, `index-audit-partial`, `symbol-find-{js,py,sh,bash}`, `symbol-dupecheck-{js,py,sh,bash}`, `symbol-deps` |
| `rules/` | The CLAUDE.md block and settings fragment to paste into a host repo |
| `cld.conf` | The shipped default config: every project-specific value, in one place outside the checkers |
| `tests/run-tests.sh` | The suite: throwaway git fixtures, every finding with a positive control |

## The three layers

**Format** is the spec. **Rule** is the same-commit discipline in
`CLAUDE.md`: update the index in the commit that changes the thing it
describes, and check the index before hunting for a file. **Gate** is
the pre-commit hook, which catches the rule being forgotten.

All three are needed. The gate alone cannot make an agent *read* an
index before grepping; the rule alone rots the moment someone is in a
hurry.

## Findings

Directory indexes (`scripts/index-audit/check.sh`):

| Code | Severity | Meaning |
|---|---|---|
| `ORPHAN` | **blocks** | an entry names something that is not there, including a path the commit deletes or renames away |
| `NOENTRY` | **blocks** | an indexable, unskipped file has no entry in its directory's index |
| `BADHDR` | *warns* | line 1 is not `INDEX <path/>`; the body is still checked |
| `WRONGPATH` | *warns* | line 1 names a directory other than the one the index sits in (`INDEX ./` is the root) |
| `WRONGTYPE` | *warns* | the entry's letter disagrees with what the thing is |
| `CRLF` | *warns* | CR-LF line endings; the file is read with the CRs stripped |
| `NOINDEX` | *warns*, sweep only | a directory holding indexable files has no `index.cld` |
| `NODENTRY` | *warns*, sweep only | a subdirectory with tracked files has no entry in its parent's index |

Symbol indexes (`scripts/symbol-audit/check.sh`):

| Code | Severity | Meaning |
|---|---|---|
| `SYM-HDR` | **blocks** | unknown line-1 species (never raised for an `index.cld`) |
| `SYM-DEAD` | **blocks** | the target does not exist, or a commit removed the source and left its `.cld` behind |
| `SYM-NAME` | **blocks** | the index is not `<target>.cld` beside its target |
| `SYM-DUP` | **blocks** | two indexes claim one target |
| `SYM-KEY` | **blocks** | field 2 is not a usable lookup key (a bare js accessor keyword, an unbalanced parenthesis, a duplicate) |
| `SYM-CRLF` | *warns* | CR-LF line endings; the file is read with the CRs removed |
| `SYM-STALE` | *warns* | an entry's name, or an `I` entry's token, does not occur in the target |
| `SYM-MISS` | *warns* | a source file that declares symbols has no symbol index |

Blocking findings are the ones that cannot false-positive, or are scoped
so tightly they may as well not. Everything judgment-shaped warns.

Both checkers exit 0 when clean or when there are only warnings, 1 on a
blocking finding, and 2 when they could not check at all (no repo, a
failed file listing). A `cld.conf` pattern that grep rejects is exit 2
in symbol-audit; index-audit prints grep's error and skips nothing. The
gate blocks on anything but 0: a check that cannot run never reads as
a check that passed.

`NOINDEX` and `NODENTRY` appear only in a sweep (no argument, or a
directory argument), never at commit time, because the gate judges only
what a commit touches. A dangling symlink is **not** an orphan: the link
is in the directory and the entry describing it is telling the truth.

## Languages and lookups

The symbol side reads js, py, sh and bash. The letters are one alphabet
with a meaning per language (`F` callable, `C` class, `K` unchanging
value, `D` stored data, `E` event, `G` globally visible name, `R`
load-time effect, `I` dependency); the spec spells out what each covers
in each language.

The language of a target is decided by, in order: a `lang <name>` line
in the index's header block; the target's `#!` line; its extension,
through `CLD_LANG_EXT_MAP`; `file -b`, if file(1) is installed. The
language decides the js-only accessor rule, what `SYM-MISS` counts as a
declaration, and what the lookups' `--lang` keeps.

```sh
scripts/symbol-lookup/lookup.sh find load --lang js   # <T> <name>  in  <file>  --  <description>
scripts/symbol-lookup/lookup.sh dupecheck parseArgs   # FREE parseArgs, or TAKEN and each definition
scripts/symbol-lookup/lookup.sh deps bin/deploy       # I <token>  --  <description>
scripts/symbol-lookup/lookup.sh rdeps lib/common.sh   # <file>  I <token>  --  <description>
```

Field 2 is matched as a fixed string, never as a pattern built from the
name. `rdeps` matches a token as written, or as a path suffix once
leading `./`, `../`, `/` and `$VAR` parts are dropped, so
`I $HERE/../lib/common.sh` answers for `lib/common.sh`. Exit codes:
`find` 0 found, 1 `NOTFOUND`; `dupecheck` 0 `FREE`, 1 `TAKEN`; `deps` 0
listed or `NONE`, 1 `NOINDEX`; `rdeps` 0 listed, 1 `NONE`; 2 is a usage
or setup error. The skills are thin wrappers around these commands.

## The commit gate

`scripts/git-hooks/pre-commit` is a dispatcher. On every commit it:

1. runs a foreign pre-commit hook that `install.sh` found and chained,
   first, because it may re-stage files; its failure blocks;
2. reads the staged diff with renames off, so a rename arrives as a
   deletion plus an addition and nothing is dropped;
3. copies the index (exactly what is being committed) into a temp tree
   with `git checkout-index`, so unstaged edits and untracked files
   cannot change the answer;
4. runs every `NN-name` check in `scripts/git-hooks/pre-commit.d/` from
   that tree, handing it the present paths and, after `--gone`, the
   deleted ones.

Deletions are narrow. For a gone path the only questions asked are
"does its parent's `index.cld` still name it?" (`ORPHAN`) and "is its
`<path>.cld` still beside it?" (`SYM-DEAD`). A deletion never re-audits
a whole index, so an honest commit is not blocked by someone else's old
orphan in the same file. A commit that modifies an index owns everything
in it.

`scripts/git-hooks/pre-commit --audit` runs the same checks over the
same staged diff on demand, read-only: it prints how the diff was
routed and the verdict, and never runs a chained hook. The
`index-audit-partial` skill runs exactly that.

There is no sanctioned bypass. The rule is: fix the index.

## What this toolkit deliberately does not check

**Whether your source is documented.** An index checker answers one
question: is this index telling the truth about what it describes. A
check that reads the index only to get a list of names to go inspect
source with has stopped checking the index.

That line was drawn the hard way. The version this was extracted from
carried a `SYM-BRIEF` warning: for every entry in a symbol index it went
into the source file and warned if the symbol had no `@brief` comment.
On the corpus it came from it produced 315 of 329 findings, burying the
13 that were real, at a **100% false positive rate**: every warning
named a file that did contain `@brief`. The spec had said so in its own
rule ("a missing brief is a SOURCE defect, not an index defect"), and
the check ran anyway. It was removed. `grep -L '@brief'` answers the
coverage question better, when you actually want to ask it.

`SYM-STALE` is the other direction and stays inside the remit: it asks
whether a name the *index* claims is still in the source.

**Which letters a language may use.** That validation is deferred.

## Quick start

```sh
git clone https://github.com/briancase1776/CLD-DirIndex
cd CLD-DirIndex
./scripts/git-hooks/install.sh   # gate this clone
tests/run-tests.sh               # prints "N passed, 0 failed, 0 known"
scripts/index-audit/check.sh     # sweep: index-audit: clean
scripts/symbol-audit/check.sh    # sweep: symbol-audit: clean
```

To adopt it in another repository, see [INSTALL.md](INSTALL.md).

## Portability

Every script is POSIX `/bin/sh`, with no bashisms and no GNU-only
flags, and the suite runs under dash and `bash --posix`
(`CLD_TEST_SH=dash tests/run-tests.sh`). Everything project-specific
(vendored trees, indexable extensions, extra `.cld` species, languages)
lives in `cld.conf` at the host repo's root, never in a checker.

One exception is in the config, not the scripts: the skip patterns are
grep BREs alternated with `\|`, and `\|` in a BRE is a GNU and BusyBox
extension that POSIX does not define. The shipped defaults rely on it.
On a grep that reads `\|` literally, an alternated pattern matches
nothing, so nothing is skipped.

`cld.conf` is shipped as a real, active config rather than a sample:
copy it into the host repo and edit values in place. This repo runs on
it, and the suite fails if it drifts from the fallback defaults in
`scripts/cld-config.sh`. A repo with no `cld.conf`, or an older one
missing newer keys, still works on those fallbacks.

## Known limits

- A path holding a newline is not supported; the gate blocks a commit
  that stages one. A path holding the byte `\037` is not supported on
  the symbol side.
- A source file named exactly `index`, with no extension, cannot have
  a symbol index: its `<name>.cld` would be `index.cld`, which is always
  a directory index.
- A checker argument that names nothing (a typo) is checked as a file
  that is not there and reports clean.
- The gate copies the whole index to a temp tree on every commit, so
  its cost grows with the size of the repo: a few seconds for tens of
  thousands of files.
