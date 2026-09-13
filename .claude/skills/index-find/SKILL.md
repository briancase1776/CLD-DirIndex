---
name: index-find
description: Find which file or directory handles something, through the directory indexes (index.cld) instead of grepping the whole tree. Reach for it on "where's the file that does X", "which dir handles Y", "where does Z live". Takes an exact filename or a paraphrase of what the file does; with no argument, prints usage.
---
Purpose: answer "where does X live" without walking the tree. The map is
the directory indexes -- one index.cld per directory, each line an F
(file) or D (subdir) entry with a one-line gist. This skill greps that
map so a cold session finds the right file by what it DOES, not by
guessing its name. It is the invocable form of the standing rule "when
looking for a file, check index.cld first".

The map is every index.cld EXCEPT those the host repo excludes in
`cld.conf` as `CLD_NOT_DIR_INDEX_RE` -- same filename, different format.
The base set is `git ls-files '*index.cld'`; filter that regex out of it
when the repo sets one.

Procedure:

1. NO ARGUMENT ($ARGUMENTS empty): print one line of usage and stop --
   `index-find <filename | what-the-file-does>`. This skill needs a
   target; there is no useful zero-arg default.

2. EXACT key -- $ARGUMENTS looks like a filename (has an extension, or
   matches a real file name):
   - Grep the dir indexes (the set above) for the name with `grep -n`.
   - Each hit's directory is the index.cld's own location; report it as
     `<dir>/<name>  --  <gist from the entry>`. List every hit if the
     name appears in more than one directory.
   - No hit means the file is not indexed (or does not exist) -- say so
     plainly; that is a normal answer, not a failure.

3. VAGUE paraphrase -- $ARGUMENTS describes what the file does:
   - Grep the entry descriptions across the dir indexes (the set above)
     for the keywords in $ARGUMENTS; try a couple of obvious synonyms,
     the gists are terse.
   - Present the single best match plus the 2-3 nearest candidates, each
     as `<dir>/<name>  --  <gist>`.
   - Confirm inline, in plain text. If exactly one candidate is
     unambiguous, say so and proceed.
   - On the pick, open that file and continue the work from there.

Notes:
- The index is the map, not the territory: a hit points you AT the file;
  read the file for the detail. A [NO BRIEF] entry is a weak gist -- open
  the file to be sure.
- If a grep of the indexes errors, or an index.cld is malformed enough
  that the lookup cannot run, that is a bug in the substrate -- report
  it, do not fake a result.

Scope guard: READ-ONLY. This skill greps and reports; it never edits an
index or a file. Adding or renaming a file and updating its index.cld is
a separate write step with its own same-commit rule.
