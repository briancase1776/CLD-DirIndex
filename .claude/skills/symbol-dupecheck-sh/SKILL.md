---
name: symbol-dupecheck-sh
description: Check whether a POSIX sh symbol name (function, method, class, constant) is already defined before you name a new one, through the symbol indexes (<file>.cld). Reach for it on "is <name> already taken", "is this method name free", "does Foo already exist" at the moment of naming in POSIX sh code. Takes the exact symbol name; reports FREE or the files that already define it. With no argument, prints usage.
---
Run, from anywhere in the repo:

    sh "$(git rev-parse --show-toplevel)/scripts/symbol-lookup/lookup.sh" dupecheck "$ARGUMENTS" --lang sh

- `FREE <name>`: no sh symbol index defines it.
- `TAKEN <name>`, then one line per definition,
  `<T> <name>  in  <file>  --  <description>`. A distinctive name TAKEN
  is the real signal; a common one (init, get, parse) legitimately recurs
  across classes and is usually fine -- say which case this is.
- With no argument the script prints its usage (exit 2): show it, stop.
- Any other error is a bug in the substrate or a broken index -- report
  it, do not fake a result.

The name matches field 2 exactly, or as the last part of a qualified
entry (Thing.load answers for load); a mention inside a description never
counts. The indexes are the map, not the territory: a symbol that is in
source but not yet indexed reads as FREE. When the answer must be
certain, back it with a source grep for the definition.

Read-only: never edits an index or a source file.
