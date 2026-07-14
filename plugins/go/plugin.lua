-- Go syntax highlighting. Uses the compiled-in tree-sitter "go" grammar and
-- maps its highlight-query capture names to theme color roles. Capture names
-- are matched by their head too, so "type.builtin" falls back to "type".

local t = thor.theme

thor.register_language {
    name       = "Go",
    extensions = { ".go" },
    grammar    = "go",
    colors = {
        keyword      = t.keywords,
        conditional  = t.keywords,
        ["repeat"]   = t.keywords,
        include      = t.keywords,
        label        = t.keywords,

        ["function"] = t.functions,
        method       = t.functions,
        constructor  = t.functions,

        type         = t.yellow,

        constant     = t.orange,
        boolean      = t.orange,
        character    = t.orange,

        number       = t.numbers,
        float        = t.numbers,

        string       = t.strings,
        escape       = t.strings,
        comment      = t.comments,
        operator     = t.operators,

        namespace    = t.cyan,
        module       = t.cyan,

        parameter    = t.parameters,
        variable     = t.variables,
        field        = t.variables,
        property     = t.variables,

        attribute    = t.attributes,
    },
}
