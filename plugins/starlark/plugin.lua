-- Starlark syntax highlighting (Bazel BUILD/WORKSPACE/.bzl files). Uses the
-- compiled-in tree-sitter "starlark" grammar and maps its highlight-query
-- capture names to theme color roles. Capture names are matched by their
-- head too, so "keyword.function" falls back to "keyword".

local t = thor.theme

thor.register_language {
    name = "Starlark",
    extensions = {
        "BUILD", "BUILD.bazel", "WORKSPACE", "WORKSPACE.bazel", ".bzl", ".star", "MODULE.bazel"
    },
    grammar = "starlark",
    colors = {
        keyword     = t.keywords,
        conditional = t.keywords,
        ["repeat"]  = t.keywords,
        include     = t.keywords,

        ["function"] = t.functions,
        method       = t.functions,
        constructor  = t.functions,

        type = t.warning,

        constant = t.conflict,
        boolean  = t.conflict,

        number = t.numbers,
        float  = t.numbers,

        string   = t.strings,
        comment  = t.comments,
        operator = t.operators,

        parameter            = t.parameters,
        ["variable.builtin"] = t.conflict,
        variable              = t.variables,
        field                  = t.variables,

        attribute   = t.attributes,
        punctuation = t.operators,
        error       = t.danger,
    },
}
