local t = thor.theme

-- Index (1-based, inclusive) of the closing quote of the string opening at `p`,
-- honoring backslash escapes; nil when unterminated.
local function string_end(line, p)
    local i = p + 1
    local len = #line
    while i <= len do
        local c = line:sub(i, i)
        if c == "\\" then
            i = i + 2
        elseif c == '"' then
            return i
        else
            i = i + 1
        end
    end
    return nil
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local function inline(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)

            -- // line comment (JSONC)
            if c == "/" and line:sub(p + 1, p + 1) == "/" then
                push(base + p - 1, base + len, t.comments)
                return
            end

            -- string: an object key when the next non-space char is ':',
            -- otherwise a value.
            if c == '"' then
                local q = string_end(line, p)
                local last = q or len
                local role = t.strings
                if q and line:sub(q + 1):match("^%s*:") then
                    role = t.tags
                end
                push(base + p - 1, base + last, role)
                p = last + 1
                goto continue
            end

            -- number: JSON allows a leading '-' and an exponent
            if c:match("%d") or (c == "-" and line:sub(p + 1, p + 1):match("%d")) then
                local s, e = line:find("^%-?%d+%.?%d*[eE]?[+-]?%d*", p)
                push(base + s - 1, base + e, t.numbers)
                p = e + 1
                goto continue
            end

            -- literals: true / false / null
            if c:match("%a") then
                local s, e = line:find("^%a+", p)
                local w = line:sub(s, e)
                if w == "true" or w == "false" or w == "null" then
                    push(base + s - 1, base + e, t.keywords)
                end
                p = e + 1
                goto continue
            end

            p = p + 1
            ::continue::
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

        inline(line, base, 1)
    end

    return spans
end

thor.register_language {
    name       = "JSON",
    extensions = { ".json", ".jsonc" },
    highlight  = lex,
}
