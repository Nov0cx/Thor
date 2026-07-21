local t = thor.theme

-- TOML pure-Lua lexer. Line based, but """ / ''' multi-line strings carry across
-- lines via `ml` (the open delimiter, or nil). [table] and [[array]] headers are
-- keywords, bare keys before '=' are attributes, and values get string / number
-- / boolean / date colouring.
local BOOLEANS = { ["true"] = true, ["false"] = true }

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local ml = nil -- open multi-line string delimiter (""" or '''), else nil

    -- Colours a value / free run starting at p.
    local function value(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)
            local s, e
            if c == "#" then
                push(base + p - 1, base + len, t.comments); return
            elseif line:sub(p, p + 2) == '"""' or line:sub(p, p + 2) == "'''" then
                ml = line:sub(p, p + 2)
                local close = line:find(ml, p + 3, true)
                if close then
                    push(base + p - 1, base + close + 2, t.strings)
                    ml = nil
                    p = close + 3
                else
                    push(base + p - 1, base + len, t.strings)
                    return
                end
            elseif c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1
            else
                -- date / datetime (e.g. 1979-05-27T07:32:00Z)
                s, e = line:find("^%d%d%d%d%-%d%d%-%d%d[T%d:%.%+%-Z]*", p)
                if not s then s, e = line:find("^[%+%-]?%d[%d_]*%.?[%d_]*[eE]?[%+%-]?%d*", p) end
                if s then
                    push(base + s - 1, base + e, t.numbers); p = e + 1
                else
                    s, e = line:find("^[%a][%w_]*", p)
                    if s then
                        if BOOLEANS[line:sub(s, e)] then push(base + s - 1, base + e, t.orange) end
                        p = e + 1
                    else
                        p = p + 1
                    end
                end
            end
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

        if ml then
            local close = line:find(ml, 1, true)
            if close then
                push(base, base + close + 2, t.strings)
                ml = nil
                value(line, base, close + 3)
            else
                push(base, base + #line, t.strings)
            end
            goto next_line
        end

        if line:match("^%s*#") then
            push(base, base + #line, t.comments)
            goto next_line
        end
        -- [table] or [[array of tables]]
        do
            local s, e = line:find("^%s*%[%[.-%]%]", 1)
            if not s then s, e = line:find("^%s*%[.-%]", 1) end
            if s then push(base + s - 1, base + e, t.keywords); goto next_line end
        end
        -- key = value
        do
            local ks, ke = line:find("^%s*[%w_%-%.\"']+", 1)
            if ks and line:find("^%s*=", ke + 1) then
                local key = line:sub(ks, ke):match("^%s*(.-)$")
                push(base + ke - #key, base + ke, t.attributes)
                local eq = line:find("=", ke + 1, true)
                push(base + eq - 1, base + eq, t.operators)
                value(line, base, eq + 1)
                goto next_line
            end
        end

        value(line, base, 1)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "TOML",
    extensions = { ".toml" },
    highlight  = lex,
}
