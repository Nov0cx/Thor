-- Nim syntax highlighting. Uses the compiled-in tree-sitter "nim" grammar and
-- maps its highlight-query capture names to theme color roles. Capture names
-- are matched by their head too, so "keyword.function" falls back to
-- "keyword".

local t = thor.theme

thor.register_language {
    name       = "Nim",
    extensions = { ".nim", ".nims", ".nimble" },
    grammar    = "nim",
    colors = {
        keyword     = t.keywords,
        conditional = t.keywords,
        ["repeat"]  = t.keywords,
        include     = t.keywords,
        exception   = t.keywords,

        ["function"] = t.functions,
        method       = t.functions,

        type = t.yellow,

        constant  = t.orange,
        character = t.orange,

        number = t.numbers,
        float  = t.numbers,

        string   = t.strings,
        comment  = t.comments,
        operator = t.operators,

        field                  = t.variables,
        parameter              = t.parameters,
        ["variable.builtin"]   = t.orange,
        variable                = t.variables,

        punctuation = t.operators,
    },
}
