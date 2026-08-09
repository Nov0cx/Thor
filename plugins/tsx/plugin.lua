-- TSX syntax highlighting. Uses the compiled-in tree-sitter "tsx" grammar
-- (javascript highlights + JSX + typescript rules) and maps its capture names
-- to theme color roles. Capture names are matched by their head too, so
-- "type.builtin" falls back to "type".

local t = thor.theme

thor.register_language {
    name       = "TSX",
    extensions = { ".tsx" },
    grammar    = "tsx",
    colors = {
        keyword      = t.keywords,
        conditional  = t.keywords,
        ["repeat"]   = t.keywords,
        include      = t.keywords,
        exception    = t.keywords,
        label        = t.keywords,

        ["function"] = t.functions,
        method       = t.functions,
        constructor  = t.functions,

        type         = t.warning,
        tag          = t.tags,

        constant     = t.conflict,
        boolean      = t.conflict,
        character    = t.conflict,

        number       = t.numbers,
        float        = t.numbers,

        string       = t.strings,
        escape       = t.strings,
        comment      = t.comments,
        operator     = t.operators,

        namespace    = t.accent_secondary,
        module       = t.accent_secondary,

        parameter    = t.parameters,
        variable     = t.variables,
        field        = t.variables,
        property     = t.variables,

        attribute    = t.attributes,
    },
}
