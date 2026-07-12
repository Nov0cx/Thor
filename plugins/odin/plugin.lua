-- Odin syntax highlighting. Uses the compiled-in tree-sitter "odin" grammar and
-- maps its highlight-query capture names to theme color roles. Capture names
-- are matched by their head too, so "type.builtin" falls back to "type".

local t = thor.theme

thor.register_language {
    name       = "Odin",
    extensions = { ".odin" },
    grammar    = "odin",
    colors = {
        keyword      = t.keywords,
        conditional  = t.keywords,
        ["repeat"]   = t.keywords,
        include      = t.keywords,
        storageclass = t.keywords,
        exception    = t.keywords,
        label        = t.keywords,

        ["function"] = t.functions,
        method       = t.functions,
        constructor  = t.functions,

        type         = t.yellow,

        constant     = t.orange,
        boolean      = t.orange,
        character    = t.orange,
        preproc      = t.orange,
        define       = t.orange,
        macro        = t.orange,

        number       = t.numbers,
        float        = t.numbers,

        string       = t.strings,
        comment      = t.comments,
        operator     = t.operators,

        namespace    = t.cyan,
        module       = t.cyan,

        parameter    = t.variables,
        variable     = t.variables,
        field        = t.variables,
        property     = t.variables,

        attribute    = t.attributes,
    },
}
