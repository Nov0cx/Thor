local t = thor.theme

-- INI / config pure-Lua lexer. Line based: full-line ; or # comments, [sections]
-- as keywords, and `key = value` / `key : value` pairs where the key is an
-- attribute, the separator an operator, and the value gets string/number/boolean
-- colouring.
local BOOLEANS = {}
for _, w in ipairs { "true", "false", "yes", "no", "on", "off", "none", "null" } do
    BOOLEANS[w] = true
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- Colours a value run (everything after the key separator).
    local function value(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)
            local s, e
            if c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1
            elseif c == "#" or c == ";" then
                push(base + p - 1, base + len, t.comments); return
            else
                s, e = line:find("^%-?%d+%.?%d*", p)
                if s and (line:sub(e + 1, e + 1) == "" or line:sub(e + 1, e + 1):match("[%s#;]")) then
                    push(base + s - 1, base + e, t.numbers); p = e + 1
                else
                    s, e = line:find("^[%a][%w_%-%.]*", p)
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

        -- full-line comment
        if line:match("^%s*[;#]") then
            push(base, base + #line, t.comments)
            goto next_line
        end
        -- [section] header
        do
            local s, e = line:find("^%s*%b[]", 1)
            if s then push(base + s - 1, base + e, t.keywords); goto next_line end
        end
        -- key <sep> value
        do
            local ks, ke = line:find("^%s*[^=:%s][^=:]*", 1)
            if ks then
                -- trim trailing spaces off the key for the span
                local key = line:sub(ks, ke)
                local trimmed = key:match("^(.-)%s*$")
                push(base + ks - 1, base + ks - 1 + #trimmed, t.attributes)
                local sep = line:find("^%s*[=:]", ke + 1)
                if sep then
                    local sp = line:find("[=:]", ke + 1)
                    push(base + sp - 1, base + sp, t.operators)
                    value(line, base, sp + 1)
                end
            end
        end

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "INI",
    extensions = { ".ini", ".cfg", ".conf", ".editorconfig", ".gitconfig", ".properties" },
    highlight  = lex,
}
