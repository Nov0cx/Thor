local t = thor.theme

-- YAML pure-Lua lexer. Line based: # comments, --- / ... document markers, `-`
-- list markers, `key:` mappings (key as attribute), &anchor / *alias references,
-- and value colouring for quoted strings, numbers and booleans / null.
local BOOLEANS = {}
for _, w in ipairs { "true", "false", "yes", "no", "on", "off", "null", "~" } do
    BOOLEANS[w] = true
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- Colours a scalar value / inline run from p.
    local function value(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)
            local s, e
            if c == "#" and (p == 1 or line:sub(p - 1, p - 1):match("%s")) then
                push(base + p - 1, base + len, t.comments); return
            elseif c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1
            elseif c == "&" or c == "*" then
                s, e = line:find("^[&*][%w_%-]+", p)
                if s then push(base + s - 1, base + e, t.attributes); p = e + 1 else p = p + 1 end
            elseif c == "|" or c == ">" then
                push(base + p - 1, base + p, t.operators); p = p + 1
            else
                s, e = line:find("^%-?%d+%.?%d*", p)
                if s and (line:sub(e + 1, e + 1) == "" or line:sub(e + 1, e + 1):match("%s")) then
                    push(base + s - 1, base + e, t.numbers); p = e + 1
                else
                    s, e = line:find("^[%a~][%w_]*", p)
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
        -- document markers --- and ...
        if line:match("^%-%-%-%s*$") or line:match("^%.%.%.%s*$") or line:match("^%-%-%- ") then
            push(base, base + 3, t.keywords)
            value(line, base, 4)
            goto next_line
        end

        do
            -- leading list markers "- " (possibly several), coloured as operators
            local p = 1
            while true do
                local ds, de = line:find("^(%s*)%-%s", p)
                if not ds then break end
                local dash = line:find("%-", p)
                push(base + dash - 1, base + dash, t.operators)
                p = dash + 1
            end
            -- key: (mapping) then value
            local ks, ke = line:find("^%s*[%w_%-%.\"']+%s*:", p)
            if ks then
                local colon = line:find(":", p, true)
                local key = line:sub(p, colon - 1):match("^%s*(.-)%s*$")
                local kstart = line:find(key, p, true)
                push(base + kstart - 1, base + kstart - 1 + #key, t.attributes)
                push(base + colon - 1, base + colon, t.operators)
                value(line, base, colon + 1)
            else
                value(line, base, p)
            end
        end

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "YAML",
    extensions = { ".yaml", ".yml" },
    highlight  = lex,
}
