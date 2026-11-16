local t = thor.theme

-- LaTeX pure-Lua lexer. One forward pass: comments, control words and symbols,
-- environment names, inline and display math, verbatim bodies and macro
-- parameters. `@` counts as a letter, so the internals of .sty and .cls files
-- read as one command.

-- Commands that structure or set up a document.
local KEYWORDS = {}
for _, w in ipairs {
    "documentclass", "usepackage", "RequirePackage", "ProvidesPackage", "ProvidesClass", "LoadClass",
    "begin", "end", "input", "include", "includeonly", "subfile",
    "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph",
    "newcommand", "renewcommand", "providecommand", "DeclareMathOperator", "newenvironment",
    "renewenvironment", "def", "edef", "gdef", "xdef", "let", "newif", "makeatletter", "makeatother",
    "NewDocumentCommand", "RenewDocumentCommand", "NewDocumentEnvironment", "DeclareOption",
    "ProcessOptions", "if", "else", "fi", "ifx", "ifdefined", "relax", "maketitle", "tableofcontents",
    "appendix", "bibliography", "bibliographystyle", "addbibresource", "printbibliography",
} do
    KEYWORDS[w] = true
end

-- Commands whose first braced argument is a key: a label, a reference, a citation, a path.
local KEY_ARGS = {}
for _, w in ipairs {
    "label", "ref", "eqref", "pageref", "autoref", "cref", "Cref", "nameref", "vref",
    "cite", "citep", "citet", "parencite", "textcite", "autocite", "footcite", "nocite",
    "input", "include", "subfile", "includegraphics", "usepackage", "RequirePackage",
    "documentclass", "bibliography", "addbibresource",
} do
    KEY_ARGS[w] = true
end

-- Environments whose body is math.
local MATH_ENVS = {}
for _, w in ipairs {
    "math", "displaymath", "equation", "align", "alignat", "flalign", "gather", "multline",
    "eqnarray", "split",
} do
    MATH_ENVS[w] = true
    MATH_ENVS[w .. "*"] = true
end

-- Environments whose body is not LaTeX, with the role of that body.
local VERBATIM_ENVS = {
    verbatim = "strings",
    ["verbatim*"] = "strings",
    Verbatim = "strings",
    lstlisting = "strings",
    minted = "strings",
    comment = "comments",
}

local BACKSLASH = string.char(92)

local function min(a, b)
    return a < b and a or b
end

-- The pattern that finds `\end{env}`.
local function end_pattern(env)
    return "%" .. BACKSLASH .. "end%s*{" .. (env:gsub("[%*%-]", "%%%0")) .. "}"
end

local function lex(src)
    local spans = {}
    local n = #src

    -- s and e are 1-based, inclusive.
    local function push(s, e, role)
        if e >= s then
            spans[#spans + 1] = { s - 1, e, role }
        end
    end

    -- The end of the line that holds p, without its newline.
    local function line_end(p)
        local nl = src:find("\n", p, true)
        return nl and nl - 1 or n
    end

    -- A braced group at p, after spaces: its two brace positions, or nil.
    local function braced(p)
        local s = src:find("^%s*{", p)
        if not s then return nil end
        local open = src:find("{", s, true)
        local close = src:find("}", open + 1, true)
        if not close then return nil end
        return open, close
    end

    -- The position after an optional [..] argument at p.
    local function skip_optional(p)
        local s, e = src:find("^%s*%b[]", p)
        return s and e + 1 or p
    end

    local scan

    -- Math from p up to `close` (plain text), or up to `\end{env}` when env is
    -- given. Returns the position after the close.
    local function math_region(p, close, env)
        local stop_s, stop_e
        if env then
            stop_s, stop_e = src:find(end_pattern(env), p)
        else
            stop_s, stop_e = src:find(close, p, true)
        end
        scan(p, stop_s and stop_s - 1 or n, t.numbers)
        if not stop_s then return n + 1 end
        if env then
            push(stop_s, stop_s + 3, t.keywords)
            local o = src:find("{", stop_s, true)
            push(o + 1, stop_e - 1, t.tags)
        else
            push(stop_s, stop_e, t.operators)
        end
        return stop_e + 1
    end

    -- Colours src[p..last]. Text no span covers takes `default`, which is nil
    -- outside math.
    scan = function(p, last, default)
        local gap = p
        local function fill(upto)
            if default and upto > gap then push(gap, upto - 1, default) end
        end
        while p <= last do
            local c = src:sub(p, p)
            if c == "%" then
                fill(p)
                local e = min(line_end(p), last)
                push(p, e, t.comments)
                p = e + 1
                gap = p
            elseif c == BACKSLASH then
                fill(p)
                local s, e = src:find("^%" .. BACKSLASH .. "[%a@]+%*?", p)
                if s and e <= last then
                    local name = src:sub(s + 1, e):gsub("%*$", "")
                    if name == "begin" or name == "end" then
                        push(s, e, t.keywords)
                        p = e + 1
                        local o, cl = braced(p)
                        if o and cl <= last then
                            local env = src:sub(o + 1, cl - 1)
                            push(o + 1, cl - 1, t.tags)
                            p = cl + 1
                            if name == "begin" and not default then
                                if MATH_ENVS[env] then
                                    p = math_region(p, nil, env)
                                elseif VERBATIM_ENVS[env] then
                                    if env == "minted" or env == "lstlisting" then
                                        p = skip_optional(p)
                                    end
                                    local vs = src:find(end_pattern(env), p)
                                    local ve = vs and vs - 1 or n
                                    if env == "minted" then
                                        local _, bc = braced(p)
                                        if bc and bc < ve then p = bc + 1 end
                                    end
                                    push(p, ve, t[VERBATIM_ENVS[env]])
                                    p = ve + 1
                                end
                            end
                        end
                    else
                        if default then
                            push(s, e, t.functions)
                        else
                            push(s, e, KEYWORDS[name] and t.keywords or t.functions)
                        end
                        p = e + 1
                        if KEY_ARGS[name] and not default then
                            local o, cl = braced(skip_optional(p))
                            if o and cl <= last then
                                push(o + 1, cl - 1, t.attributes)
                                p = cl + 1
                            end
                        end
                    end
                elseif p + 1 <= last then
                    local nx = src:sub(p + 1, p + 1)
                    push(p, p + 1, t.operators)
                    if not default and nx == "(" then
                        p = math_region(p + 2, BACKSLASH .. ")")
                    elseif not default and nx == "[" then
                        p = math_region(p + 2, BACKSLASH .. "]")
                    else
                        p = p + 2
                    end
                else
                    p = p + 1
                end
                gap = p
            elseif c == "$" and not default then
                local display = src:sub(p + 1, p + 1) == "$"
                local d = display and 2 or 1
                push(p, p + d - 1, t.operators)
                p = math_region(p + d, display and "$$" or "$")
                gap = p
            elseif c == "#" and src:find("^#%d", p) then
                fill(p)
                push(p, p + 1, t.parameters)
                p = p + 2
                gap = p
            elseif c == "&" or c == "~" or c == "^" or c == "_" then
                fill(p)
                push(p, p, t.operators)
                p = p + 1
                gap = p
            else
                p = p + 1
            end
        end
        fill(last + 1)
    end

    scan(1, n, nil)
    return spans
end

-- BibTeX: `@type{key,` entries, `field =` names, braced and quoted values and
-- `%` comments.
local function lex_bib(src)
    local spans = {}
    local n = #src
    local function push(s, e, role)
        if e >= s then
            spans[#spans + 1] = { s - 1, e, role }
        end
    end

    local after_eq = false
    local p = 1
    while p <= n do
        local c = src:sub(p, p)
        if c == "%" then
            local e = (src:find("\n", p, true) or n + 1) - 1
            push(p, e, t.comments)
            p = e + 1
        elseif c == "@" then
            local s, e = src:find("^@%a+", p)
            if s then
                push(s, e, t.keywords)
                p = e + 1
                local ks, ke = src:find("^%s*[{(]%s*[^,%s{}()]+", p)
                if ks then
                    push(src:find("[^%s{(]", ks), ke, t.attributes)
                    p = ke + 1
                end
            else
                p = p + 1
            end
        elseif c == "=" then
            push(p, p, t.operators)
            after_eq = true
            p = p + 1
        elseif c == "{" and after_eq then
            local _, e = src:find("^%b{}", p)
            e = e or n
            push(p, e, t.strings)
            after_eq = false
            p = e + 1
        elseif c == '"' then
            local e = src:find('"', p + 1, true) or n
            push(p, e, t.strings)
            after_eq = false
            p = e + 1
        elseif c:match("%d") then
            local s, e = src:find("^%d+", p)
            if after_eq then push(s, e, t.numbers) end
            after_eq = false
            p = e + 1
        elseif c:match("[%a_]") then
            local s, e = src:find("^[%w_%-:]+", p)
            if not after_eq and src:find("^%s*=", e + 1) then
                push(s, e, t.variables)
            end
            after_eq = false
            p = e + 1
        else
            if not c:match("%s") then after_eq = false end
            p = p + 1
        end
    end
    return spans
end

thor.register_language {
    name       = "LaTeX",
    extensions = { ".tex", ".sty", ".cls", ".ltx", ".dtx", ".latex" },
    highlight  = lex,
}

thor.register_language {
    name       = "BibTeX",
    extensions = { ".bib" },
    highlight  = lex_bib,
}
