-- Nix syntax highlighting. Uses the compiled-in tree-sitter "nix" grammar and
-- maps its highlight-query capture names to theme color roles. Capture names
-- are matched by their head too, so "string.special.path" falls back to
-- "string".

local t = thor.theme

thor.register_language {
    name       = "Nix",
    extensions = { ".nix" },
    grammar    = "nix",
    colors = {
        keyword = t.keywords,

        ["function"] = t.functions,

        number = t.numbers,
        escape = t.strings,
        string  = t.strings,
        comment = t.comments,
        operator = t.operators,

        ["variable.builtin"]   = t.orange,
        ["variable.parameter"] = t.parameters,
        variable                = t.variables,
        property                = t.variables,

        punctuation = t.operators,
    },
}
