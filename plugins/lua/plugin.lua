local t = thor.theme

thor.register_language {
    name       = "Lua",
    extensions = { ".lua" },
    grammar    = "lua",
    colors = {
        keyword      = t.keywords, -- keyword, keyword.return/function/operator
        conditional  = t.keywords,
        ["repeat"]   = t.keywords,
        label        = t.keywords,

        ["function"] = t.functions, -- function, function.call, function.builtin
        method       = t.functions,

        constant     = t.orange, -- constant, constant.builtin, vararg
        boolean      = t.orange,
        preproc      = t.orange, -- hash_bang_line

        number       = t.numbers,
        string       = t.strings, -- string, string.escape
        comment      = t.comments,
        operator     = t.operators,

        variable     = t.variables, -- variable, variable.builtin (self)
        parameter    = t.variables,
        field        = t.variables,

        attribute    = t.attributes,
    },
}
