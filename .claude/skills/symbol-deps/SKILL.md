---
name: symbol-deps
description: List what a file depends on, or which files depend on a module or path, through the I (dependency) entries of the symbol indexes (<file>.cld) instead of grepping for import, require, source and . lines. Reach for it on "what does X use", "what does X import or source", "who uses lib/util.sh", "what breaks if I change Y". Takes deps FILE or rdeps TARGET (a bare path means deps); with no argument, prints usage.
---
$ARGUMENTS is `deps FILE` or `rdeps TARGET`; a bare path with neither
word means `deps <path>`. Run, from anywhere in the repo, with the path
in SINGLE quotes exactly as below, so the shell never expands a `$`, `*`
or `\` in it (FILE is relative to where you stand, like any path; a path
holding a single quote is written 'it'\''s.sh'):

    sh "$(git rev-parse --show-toplevel)/scripts/symbol-lookup/lookup.sh" deps 'FILE'
    sh "$(git rev-parse --show-toplevel)/scripts/symbol-lookup/lookup.sh" rdeps 'TARGET'

- deps: one line per dependency of FILE, `I <token>  --  <what is used>`,
  read from FILE's own index (FILE.cld). `NOINDEX` means FILE has no
  symbol index (or an exempt one; the line says which); `NONE` means its
  index lists no I entries.
- rdeps: one line per dependent, `<file>  I <token>  --  <what is used>`.
  Ask with the file's path: rdeps pkg/util.py, rdeps web/util.js. A
  token matches when it is TARGET as written, or names it the way the
  importing file's language writes it:
  - js: `./` and `../` tokens are resolved against the importing file's
    directory, and may leave out the extension (`./util` is util.js) or
    name an index.js's directory; bare specifiers (`react`) and tokens
    that leave the repo are compared as paths, below.
  - py: the dotted module (`pkg.util` is pkg/util.py, `pkg` is
    pkg/__init__.py), or its last parts (`util`); a relative token
    (`.util`, `..pkg.mod`) is resolved against the importing package.
  - sh, bash: compared as paths, lexically, once leading ./ ../ / and
    $VAR parts (and quotes) are dropped: `I $HERE/../lib/util.sh`
    answers for lib/util.sh and for util.sh, on a / boundary only. A
    sh `.` path is relative to wherever the script runs, which no index
    records, so a short token here can answer for a TARGET it does not
    mean -- open the file to be sure.
  `NONE` means no I entry names TARGET; the line says how many indexes
  record any I entry at all, so a thin dependency map shows.
- `UNKNOWN` (deps or rdeps): no symbol index in the repo records a single
  I entry. Dependencies are not indexed here, so "nothing depends on it"
  would be a guess -- say that, and fall back to grepping the source for
  its imports.
- Exit 0 when something is listed, 1 for NOINDEX, NONE and UNKNOWN.
- With no argument the script prints its usage (exit 2): show it, stop.
- Any other error is a bug in the substrate or a broken index -- report
  it, do not fake a result.

The token is the module or path exactly as the source writes it, in every
language (js import/require, py import, sh and bash . and source). The
indexes are the map, not the territory: a dependency the index does not
list is invisible here.

Read-only: never edits an index or a source file.
