---
name: filename-find
description: Find which file defines a function, class, method, or constant -- and where the symbol that does X lives -- through the symbol indexes (<file>.cld) instead of grepping source. Reach for it on "where's the method that does X", "which file defines Foo", "what handles Y". Takes an exact symbol name or a paraphrase of what it does; with no argument, prints usage.
---
Purpose: answer "which file defines Foo" or "what does the teardown"
without grepping source. The map is the per-file symbol indexes -- one
<file>.cld beside each source file, line 1 `FILE <path>`, then one line
per symbol (C class, F function/method, K constant, D data field, E
event, G global, R load-time effect) with a gist. This skill greps that
map so a cold session lands on the right symbol by name or by what it
does. It is the invocable form of the standing rule "when looking for a
method, class, or API, check <file>.cld before grepping source".

Procedure:

1. NO ARGUMENT ($ARGUMENTS empty): print one line of usage and stop --
   `filename-find <symbol | what-the-symbol-does>`. No useful zero-arg
   default.

2. EXACT key -- $ARGUMENTS is a symbol name (e.g. `vTeardown`,
   `MatchGraph`):
   - Grep the symbol indexes for the name. A symbol index is a .cld whose
     line 1 is `FILE <path>` -- that filter alone drops the dir indexes
     (INDEX header) and every other species. If the repo sets
     `CLD_NOT_SYMBOL_INDEX_RE` in cld.conf, those files borrow the FILE
     header for another domain; skip them too:
     `for f in $(git ls-files '*.cld'); do
        head -n1 "$f" | grep -q '^FILE ' && grep -Hn "<name>" "$f"
      done`.
   - For each hit, the owning source file is that index's line-1 `FILE`
     path. Report `<symbol>  in  <FILE path>  --  <gist>`, then open the
     symbol in the source file.
   - No hit means the symbol is not indexed (or does not exist) -- say
     so; a normal answer, not a failure.

3. VAGUE paraphrase -- $ARGUMENTS describes what the symbol does:
   - Grep the symbol gists across the symbol indexes for the keywords in
     $ARGUMENTS, plus a couple of obvious synonyms.
   - Present the best match plus the 2-3 nearest candidates, each as
     `<symbol>  in  <FILE path>  --  <gist>`.
   - Confirm inline, in plain text. If one candidate is unambiguous, say
     so and proceed.
   - On the pick, open that symbol in its source file and continue.

Notes:
- The gist points you AT the symbol; read the source for the real
  signature and behaviour. A thin entry means the index is thin -- open
  the file.
- If the grep errors or a symbol index is malformed enough to break the
  lookup, that is a bug in the substrate -- report it, do not fake a
  result.

Scope guard: READ-ONLY. This skill greps and reports; it never edits a
symbol index or a source file. Changing a symbol and updating its
<file>.cld is a separate write step with its own same-commit rule.
