---
name: grammar-add
description: Adds a tree-sitter grammar to Thor, keeping build.odin and syntax/syntax.odin in sync and writing the language plugin. Use when adding syntax highlighting for a language that needs a compiled grammar.
---

# Add a tree-sitter grammar

Grammars are **compiled in**, so adding one touches three places that must stay
in step. A miss breaks the build for everyone, on every platform. Queries are
data and are handled separately (see *Highlights* below).

Ask for the grammar repository URL if it was not given. Decide the **grammar id**
first: it becomes an Odin identifier, so `c-sharp` becomes `c_sharp`. It is the
same string in all three places.

## Before you start

A grammar is not always the answer. For a format where a grammar is overkill,
a plugin can supply a pure-Lua `highlight` function returning `{start, end, role}`
spans instead — see `plugins/ini` or `plugins/dotenv`. That path touches only
`plugins/<id>/`, and none of the steps below.

## 1. `build.odin` — the `GRAMMARS` table

Add one row. The third field is the commit the parser is built from — take it
from `git ls-remote <url> HEAD`, never guess it. The fourth is the subdirectory
holding the grammar, empty when it is at the repository root:

```odin
{"zig",   "https://github.com/tree-sitter-grammars/tree-sitter-zig", "6479aa13f32f701c383083d8b28360ebd682fb7d", ""},
{"php",   "https://github.com/tree-sitter/tree-sitter-php",          "58d5643086ae60e93a3746cca648363ee97c8761", "php"},
{"ocaml", "https://github.com/tree-sitter/tree-sitter-ocaml",        "3b2e14e0697d405c9aa0beddfa09b71f45abc504", "grammars/ocaml"},
```

`deps` fetches exactly that commit. To move a grammar to a newer commit later,
change the hash and run `deps`: the stamp beside the parser no longer matches,
so that one parser is built again.

Keep the column alignment of the existing rows. Add a `//` comment only where
the row is surprising — a repository holding two grammars, or a name that is not
an Odin identifier — matching the comments already there.

## 2. `syntax/syntax.odin` — import and register

Two edits in one file. The import, beside the others:

```odin
import ts_zig "../vendor/odin-tree-sitter/parsers/zig"
```

and the registration in the same block as the rest:

```odin
h.languages["zig"] = Language_Entry{ts_zig.tree_sitter_zig(), ts_zig.HIGHLIGHTS}
```

The generated procedure is `tree_sitter_<id>`. Where a grammar layers on
another's query, concatenate — see the javascript/typescript/tsx rows for the
pattern.

No CI workflow needs an edit: each one calls `build.odin -- deps`, which reads
`GRAMMARS`. `-vet` in CI does not cover the generated parser package.

## 3. `plugins/<id>/plugin.lua`

Copy `templates/plugin.lua` from this skill and fill in the name, extensions,
grammar id and colors. Map the grammar's highlight-query capture names to theme
roles; capture names match by head too, so `keyword.function` falls back to
`keyword`. Read the grammar's own `queries/highlights.scm` to find which
captures it actually emits — mapping captures the grammar never produces is
dead configuration.

Extensionless names work: `thor_highlight_key` falls back from extension to
basename, which is how `Makefile` and `Dockerfile` are matched.

The plugin needs no `plugin.json` unless it wants a permission
(`exec`/`read`/`write`/`ui`/`keys`/`tick`). A highlighting plugin wants none, and
a permission-free plugin loads without prompting the user.

## 4. Fetch and verify

```bash
odin run build.odin -file -- deps
odin check syntax -no-entry-point
odin run build.odin -file -- test
```

`deps` clones the submodule and builds the parser; without it the new import
does not resolve. Then run `/verify` for the full sweep.

## Highlights

The built-in query is the grammar's own. A plugin replaces it via
`syntax.set_highlights` with `highlights = "highlights.scm"` beside the plugin,
or an inline query string. A query that fails to compile is reported with its
offset rather than silently uncoloring the language — so if the language draws
plain after this, read that error first.

## Checklist

Before reporting done, confirm all four:

- [ ] `GRAMMARS` row in `build.odin`, with the pinned commit
- [ ] import in `syntax/syntax.odin`
- [ ] `h.languages["<id>"]` registration in `syntax/syntax.odin`
- [ ] `plugins/<id>/plugin.lua`
