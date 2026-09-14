# CLD-DirIndex

A small, self-contained toolkit for keeping a repository's `.cld`
**directory indexes** honest -- the format, a mechanical checker, a
pre-commit gate, and two lookup skills for Claude Code.

A directory index records what is inside a directory. Its sibling
[CLD-FileIndex](https://github.com/briancase1776/CLD-FileIndex) records
what is inside a *file*. They are separate repos because they have
different maturity: this side is language-agnostic by construction and
is finished, while the file side still needs a per-file-type design.

## What a `.cld` directory index is

A plain-text index that sits next to what it describes -- `index.cld`,
one per directory:

```
INDEX lib/
F cache.js           In-memory result cache over SQLite; mutex-guarded writes
F errors.js          Error and perf logging; see notes/errors.md
L current.json       Symlink to the active config in versions/
D utils/             Low-level shared helpers
```

The type letters are find(1)'s `-type` codes, uppercased: `F` file,
`D` directory, `L` symlink, `P` fifo, `S` socket, `B` block device,
`C` character device. The letter describes the **entry**, not what it
points at -- a symlink is `L` even when it resolves to a regular file.

In a git repo you will see `F`, `D` and `L` and nothing else: git
cannot store a fifo, socket, or device node at all. The rest exist so
the format can describe a real directory truthfully.

The point: an agent arriving cold can find the right file by what it
*does* -- without walking the tree. The index is the map. It only works
if the map is true, which is what the rest of this repo is for.

Full rules: [`spec/dir-index-format.txt`](spec/dir-index-format.txt).

## What's in the box

| Piece | What it does |
|---|---|
| `spec/` | The format spec -- the authority on how an index is written |
| `scripts/index-audit/check.sh` | Directory-index checker: ORPHAN, NOENTRY, BADHDR |
| `scripts/git-hooks/` | Pre-commit dispatcher, the gate, and the installer |
| `.claude/skills/` | `index-find`, `index-audit-partial` |
| `rules/` | The CLAUDE.md block and settings fragment to paste into a host repo |
| `cld.conf` | The shipped default config -- every project-specific value, in one place outside the checkers |
| `tests/run-tests.sh` | 38 assertions over throwaway git fixtures |

## The three layers

**Format** is the spec. **Rule** is the same-commit discipline in
`CLAUDE.md`: update the index in the commit that changes the thing it
describes, and check the index before hunting for a file. **Gate** is the
pre-commit hook, which catches the rule being forgotten.

All three are needed. The gate alone cannot make an agent *read* an
index before grepping; the rule alone rots the moment someone is in a
hurry.

## Findings

- `ORPHAN` **blocks** -- an entry names something that is not there
- `NOENTRY` **blocks** -- an indexable file has no entry in its dir index
- `BADHDR` *warns* -- line 1 is not `INDEX <path/>`
- `WRONGTYPE` *warns* -- the entry's letter disagrees with what the thing is

A dangling symlink is **not** an orphan. The link is present in the
directory and the entry describing it is telling the truth; where it
points is the target's problem.

Blocking findings are the ones that cannot false-positive or are scoped
so tightly they may as well not. Everything judgment-shaped warns.

## What this toolkit deliberately does not check

**Anything that is not the index.** An index checker answers one
question: is this index telling the truth about what it describes. A
check that reads the index only to get a list of names to go inspect
something *else* with has stopped checking the index.

That line was drawn the hard way. The version this was extracted from
carried a documentation-coverage warning on the symbol-index side: for
every entry it went into the source file and warned if the symbol had no
`@brief` comment. It produced 315 of 329 findings on the corpus it came
from, burying the 13 that were real, at a 100% false positive rate --
every warning named a file that did contain `@brief`. The spec had even
said so in its own rule: "a missing brief is a SOURCE defect, not an
index defect." It was removed. The full account lives in
[CLD-FileIndex](https://github.com/briancase1776/CLD-FileIndex), which
owns that checker now.

Keeping the remit that narrow is why this repo exists apart from the one
it came from -- and why the file-index half now lives apart from this
one.

## Quick start

```sh
git clone https://github.com/briancase1776/CLD-DirIndex
cd CLD-DirIndex
./scripts/git-hooks/install.sh   # gate this repo
tests/run-tests.sh               # 38 passed, 0 failed
```

To adopt it in another repository, see [INSTALL.md](INSTALL.md).

## Contract with CLD-FileIndex

Both repos ship `scripts/git-hooks/pre-commit`, and a host repo that
adopts both has only one `.git/hooks/pre-commit`. **Keep that
dispatcher byte-identical in both repos.** It runs everything in
`pre-commit.d/` in lexical order, so each side just drops its own `NN-`
gate in (`20-index-audit` here, `30-symbol-audit` there) and they
coexist. If the dispatchers ever diverge, whichever installer runs
second silently wins.

`scripts/cld-config.sh`, `scripts/git-hooks/install.sh` and the test
harness are also copies rather than a shared dependency. That is a
deliberate trade: this side is finished, so a frozen copy does not
drift.

## Portability

Both checkers are POSIX `/bin/sh` with no bashisms and no GNU-only
flags. Everything project-specific -- vendored trees, indexable
extensions -- lives in `cld.conf` at the host repo's root, never in the
checker.

`cld.conf` is shipped as a real, active config rather than a sample:
copy it into the host repo and edit values in place. This repo runs on
it, so the defaults you copy are the ones exercised by every check and
every test run here, and the suite fails if it drifts out of sync with
the fallback defaults in `scripts/cld-config.sh`. A repo with no
`cld.conf` at all still works on those fallbacks -- but a repo of any
size will want one.

The setting to get right first is `CLD_SKIP_RE`: it is the single place
a "do not index this" decision is recorded, which is what lets `NOENTRY`
block without being a judgment call.
