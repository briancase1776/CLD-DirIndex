---
name: filename-dupecheck
description: Check whether a symbol name (function, method, class, constant) is already defined before you name a new one, through the symbol indexes (<file>.cld). Reach for it on "is <name> already taken", "is this method name free", "does Foo already exist" at the moment of naming. Takes the exact symbol name; reports FREE or the files that already define it. With no argument, prints usage.
---
Purpose: stop a confusing name collision at the moment of naming.
Reusing a distinctive symbol name for an unrelated thing -- or
unknowingly shadowing one that already exists -- is cheap to prevent and
expensive to unwind. The map is the symbol indexes (one FILE-headed
<file>.cld per source file, listing every defined symbol), so a lookup
answers "is this name already a defined symbol, and where" without
reading source.

Procedure:

1. NO ARGUMENT ($ARGUMENTS empty): print one line of usage and stop --
   `filename-dupecheck <SymbolName>`.

2. $ARGUMENTS is a symbol name (e.g. `getColorByCategoryId`, `#aColors`):
   - Grep the symbol indexes for a matching symbol ENTRY -- the name in
     the T-name field, not a mention inside a description. A symbol index
     is a FILE-headed .cld; skip any file matching the repo's
     `CLD_NOT_SYMBOL_INDEX_RE` (another domain that borrowed the header):
     `for f in $(git ls-files '*.cld'); do
        head -n1 "$f" | grep -q '^FILE ' \
          && awk -v n="<name>" '$1 ~ /^[A-Z]$/ && ($2==n || $2 ~ ("\\." n "$")) {print FILENAME": "$0}' "$f"
      done`.
     The $1 guard skips PROSE lines (legal in a .cld, and shaped to never
     start with a capital type letter), and the second $2 clause matches
     QUALIFIED entries (PhysicsSection.#load answers for #load) --
     without it every qualified entry is a silent miss.
   - No hit -> report FREE: no symbol by that name is indexed.
   - Any hit -> report TAKEN and show each FILE / symbol so the existing
     owner is visible. A distinctive-name TAKEN is the real signal; a
     common name (`init`, `Get`, `Parse`) legitimately recurs across
     classes and is usually fine -- say which case this is.

Caveat: the symbol indexes are the map, not the territory. A symbol that
exists in source but is not yet indexed (index drift) reads as FREE here.
When the answer must be certain, back it with a source grep for the
definition. An index so malformed the lookup cannot run is a bug --
report it, do not fake a result.

Scope guard: READ-ONLY. This skill greps and reports; it never edits a
symbol index or source. Adding the symbol and updating its <file>.cld is
a separate write step with its own same-commit rule.
