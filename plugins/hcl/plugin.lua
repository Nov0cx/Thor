-- HCL / Terraform syntax highlighting. Uses the compiled-in tree-sitter "hcl"
-- grammar. The upstream grammar ships no queries/highlights.scm of its own, so
-- this plugin supplies the whole query (adapted from nvim-treesitter's HCL
-- highlights, verified against this grammar's own node-types.json) and maps
-- its capture names to theme color roles. Capture names are matched by their
-- head too, so "variable.member" falls back to "variable".

local t = thor.theme

thor.register_language {
    name       = "HCL",
    extensions = { ".tf", ".tfvars", ".hcl" },
    grammar    = "hcl",
    highlights = "highlights.scm",
    colors = {
        keyword     = t.keywords,
        conditional = t.keywords,
        ["repeat"]  = t.keywords,

        ["function"] = t.functions,

        type = t.warning,

        constant = t.conflict,
        boolean  = t.conflict,

        number = t.numbers,
        string  = t.strings,
        comment = t.comments,
        operator = t.operators,

        ["variable.builtin"] = t.conflict,
        variable               = t.variables,

        punctuation = t.operators,
    },
}
