---
name: symbol-find-bash
description: Find which bash file defines a function, class, method, or constant through the symbol indexes (<file>.cld) instead of grepping source. Reach for it on "which file defines Foo", "where does Thing.load live", "what defines X" in bash code. Takes the exact symbol name, bare or qualified (Owner.name); with no argument, prints usage.
---
Run, from the repo root:

    sh scripts/symbol-lookup/lookup.sh find "$ARGUMENTS" --lang bash

- Each hit is one line, `<T> <name>  in  <file>  --  <description>`. Open
  the symbol in that file: the description points you at it, the source
  has the real signature and behaviour.
- `NOTFOUND <name>` means no bash symbol index lists it -- not indexed, or
  not a symbol. A normal answer, not a failure.
- With no argument the script prints its usage (exit 2): show it, stop.
- Any other error is a bug in the substrate or a broken index -- report
  it, do not fake a result.

The name matches field 2 exactly, or as the last part of a qualified
entry (Thing.load answers for load). The language comes from the index's
`lang <name>` header line, else the target's #! line, its extension, or
file(1). bash letters: F name() or function name, K readonly/declare -r, D global variable or array, G export, R top-level effect (set -euo pipefail, trap, ...), I source or .; C and E are unused.

Read-only: never edits an index or a source file.
