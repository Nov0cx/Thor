local t = thor.theme

-- gitignore-family pure-Lua lexer: one pattern per line, `#` full-line
-- comments, leading `!` negation, and (for .gitattributes) trailing
-- `attr` / `attr=value` words after the pattern.
local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- Colours one whitespace-delimited pattern: glob metacharacters
    -- (* ? [ ] !) as operators, the rest as a string.
    local function pattern(line, base, s, e)
        local p = s
        while p <= e do
            local c = line:sub(p, p)
            if c:match("[%*%?%[%]!]") then
                push(base + p - 1, base + p, t.operators)
                p = p + 1
            else
                -- search only within [p, e] so the run cannot bleed past the
                -- token into trailing .gitattributes words
                local rs, re = line:sub(p, e):find("^[^%*%?%[%]!]+")
                local as, ae = p + rs - 1, p + re - 1
                push(base + as - 1, base + ae, t.strings)
                p = ae + 1
            end
        end
    end

    -- Colours a trailing .gitattributes word: `-attr`, `attr` or `attr=value`.
    local function attribute(line, base, s, e)
        local word = line:sub(s, e)
        local eq = word:find("=", 1, true)
        if eq then
            push(base + s - 1, base + s - 1 + eq - 1, t.attributes)
            push(base + s - 1 + eq - 1, base + s - 1 + eq, t.operators)
            push(base + s - 1 + eq, base + e, t.strings)
        elseif word:sub(1, 1) == "-" then
            push(base + s - 1, base + s, t.operators)
            push(base + s, base + e, t.attributes)
        else
            push(base + s - 1, base + e, t.attributes)
        end
    end

    local i = 1
    local n = #src
    while i <= n do
        local nl = src:find("\n", i, true)
        local stop = nl and (nl - 1) or n
        local line = src:sub(i, stop)
        local base = i - 1
        i = (nl or n) + 1

        if line:match("^%s*#") then
            push(base, base + #line, t.comments)
            goto next_line
        end
        if line:match("^%s*$") then
            goto next_line
        end

        do
            local p = 1
            local len = #line
            while p <= len and line:sub(p, p):match("%s") do
                p = p + 1
            end
            if p <= len and line:sub(p, p) == "!" then
                push(base + p - 1, base + p, t.operators)
                p = p + 1
            end
            local ps, pe = line:find("^[^%s]+", p)
            if ps then
                pattern(line, base, ps, pe)
                p = pe + 1
            end
            -- .gitattributes: whitespace-separated attribute words after the pattern
            while true do
                local ws, we = line:find("^%s+", p)
                if not ws then break end
                p = we + 1
                local as, ae = line:find("^[^%s]+", p)
                if not as then break end
                attribute(line, base, as, ae)
                p = ae + 1
            end
        end

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "gitignore",
    extensions = {
        ".gitignore", ".gitattributes", ".dockerignore", ".npmignore",
        ".eslintignore", ".prettierignore",
    },
    highlight  = lex,
    line_based = true,
}
