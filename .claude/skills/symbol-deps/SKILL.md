---
name: symbol-deps
description: List what a file depends on, or which files depend on a module or path, through the I (dependency) entries of the symbol indexes (<file>.cld) instead of grepping for import, require, source and . lines. Reach for it on "what does X use", "what does X import or source", "who uses lib/util.sh", "what breaks if I change Y". Takes deps FILE or rdeps TARGET (a bare path means deps); with no argument, prints usage.
---
$ARGUMENTS is `deps FILE` or `rdeps TARGET`; a bare path with neither
word means `deps <path>`. Run, from the repo root, with the path
quoted:

    sh scripts/symbol-lookup/lookup.sh deps "FILE"
    sh scripts/symbol-lookup/lookup.sh rdeps "TARGET"

- deps: one line per dependency of FILE, `I <token>  --  <what is used>`,
  read from FILE's own index (FILE.cld). `NONE` means the index lists no
  I entries; `NOINDEX` means FILE has no symbol index.
- rdeps: one line per dependent, `<file>  I <token>  --  <what is used>`.
  A token matches TARGET as written, or as a path suffix once leading
  ./ ../ and $VAR parts are dropped: `I ../lib/util.sh` answers for
  lib/util.sh and for util.sh. `NONE` means no I entry names it.
- With no argument the script prints its usage (exit 2): show it, stop.
- Any other error is a bug in the substrate or a broken index -- report
  it, do not fake a result.

The token is the module or path exactly as the source writes it, in every
language (js import/require, py import, sh and bash . and source). The
indexes are the map, not the territory: a dependency the index does not
list is invisible here.

Read-only: never edits an index or a source file.
