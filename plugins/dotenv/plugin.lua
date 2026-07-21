local t = thor.theme

-- dotenv (.env) pure-Lua lexer. Line based: # comments, an optional leading
-- `export`, `KEY=value` pairs (key as attribute), and value colouring for quoted
-- strings, ${VAR} / $VAR references, numbers and booleans.
local BOOLEANS = { ["true"] = true, ["false"] = true }

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local function value(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)
            local s, e
            if c == "#" then
                push(base + p - 1, base + len, t.comments); return
            elseif c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1
            elseif c == "$" then
                s, e = line:find("^%${[^}]*}", p)
                if not s then s, e = line:find("^%$[%a_][%w_]*", p) end
                if s then push(base + s - 1, base + e, t.variables); p = e + 1 else p = p + 1 end
            else
                s, e = line:find("^%-?%d+%.?%d*", p)
                if s and (line:sub(e + 1, e + 1) == "" or line:sub(e + 1, e + 1):match("%s")) then
                    push(base + s - 1, base + e, t.numbers); p = e + 1
                else
                    s, e = line:find("^[%a][%w_]*", p)
                    if s then
                        if BOOLEANS[line:sub(s, e):lower()] then push(base + s - 1, base + e, t.orange) end
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

        if line:match("^%s*#") then
            push(base, base + #line, t.comments)
            goto next_line
        end

        do
            local p = 1
            -- optional `export ` prefix
            local xs, xe = line:find("^%s*export%s+", 1)
            if xs then
                local ks, ke = line:find("export", 1)
                push(base + ks - 1, base + ke, t.keywords)
                p = xe + 1
            end
            local ks, ke = line:find("^%s*[%w_%.]+", p)
            if ks and line:find("^%s*=", ke + 1) then
                local key = line:sub(ks, ke):match("^%s*(.-)$")
                push(base + ke - #key, base + ke, t.attributes)
                local eq = line:find("=", ke + 1, true)
                push(base + eq - 1, base + eq, t.operators)
                value(line, base, eq + 1)
            end
        end

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "dotenv",
    extensions = { ".env" },
    highlight  = lex,
}
