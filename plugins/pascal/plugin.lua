-- Pascal syntax highlighting (Delphi/FreePascal dialects). Uses the compiled-in
-- tree-sitter "pascal" grammar and maps its highlight-query capture names to
-- theme color roles. Capture names are matched by their head too, so
-- "type.parameter" falls back to "type".

local t = thor.theme

thor.register_language {
    name       = "Pascal",
    extensions = { ".pas", ".pp", ".inc", ".lpr", ".dpr" },
    grammar    = "pascal",
    colors = {
        keyword = t.keywords,

        ["function"] = t.functions,

        type = t.warning,

        constant = t.conflict,

        number = t.numbers,
        string  = t.strings,
        comment = t.comments,
        operator = t.operators,

        ["variable.parameter"] = t.parameters,
        variable                = t.variables,

        punctuation = t.operators,
        -- Catch-all: any identifier the query's heuristics did not classify.
        identifier  = t.variables,
    },
}
