-- Common Lisp syntax highlighting. Uses the compiled-in tree-sitter
-- "commonlisp" grammar, which ships only queries/tags.scm upstream (no
-- highlights.scm), so this plugin supplies its own query. Capture names are
-- matched by their head too, so "constant.builtin" falls back to "constant".

local t = thor.theme

thor.register_language {
    name       = "Common Lisp",
    extensions = { ".lisp", ".lsp", ".cl", ".asd" },
    grammar    = "commonlisp",
    highlights = "highlights.scm",
    colors = {
        number = t.numbers,
        string  = t.strings,
        comment = t.comments,
        operator = t.operators,

        constant  = t.orange,
        namespace = t.cyan,
    },
}
