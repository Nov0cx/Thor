local t = thor.theme

-- CSS pure-Lua lexer. Block comments (/* */) and rule blocks span lines, so the
-- comment flag and brace depth are carried across the line loop. Inside a block
-- (depth > 0) an identifier before ':' is a property; at depth 0 identifiers are
-- part of a selector.
local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local in_comment = false
    local depth = 0

    local function inline(line, base, p)
        local len = #line
        while p <= len do
            if in_comment then
                local e = line:find("*/", p, true)
                if e then
                    push(base + p - 1, base + e + 1, t.comments)
                    in_comment = false
                    p = e + 2
                else
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                goto continue
            end

            local c = line:sub(p, p)
            local s, e

            -- /* block comment (may run onto later lines)
            if line:sub(p, p + 1) == "/*" then
                in_comment = true
                goto continue
            end
            -- string
            if c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1; goto continue
            end
            -- @media / @import / ... at-rule
            s, e = line:find("^@[%a-]+", p)
            if s then push(base + s - 1, base + e, t.keywords); p = e + 1; goto continue end
            -- !important and friends
            s, e = line:find("^!%a+", p)
            if s then push(base + s - 1, base + e, t.keywords); p = e + 1; goto continue end
            -- braces adjust depth; braces/semicolons/colons are operators
            if c == "{" then push(base + p - 1, base + p, t.operators); depth = depth + 1; p = p + 1; goto continue end
            if c == "}" then push(base + p - 1, base + p, t.operators); if depth > 0 then depth = depth - 1 end; p = p + 1; goto continue end
            if c == ";" or c == "," then push(base + p - 1, base + p, t.operators); p = p + 1; goto continue end
            -- #hex color / #id selector
            s, e = line:find("^#[%x]+", p)
            if s and (e - s == 3 or e - s == 6 or e - s == 8) and depth > 0 then
                push(base + s - 1, base + e, t.orange); p = e + 1; goto continue
            end
            s, e = line:find("^#[%w_-]+", p)
            if s then push(base + s - 1, base + e, t.tags); p = e + 1; goto continue end
            -- .class / :pseudo selector marker
            s, e = line:find("^%.[%w_-]+", p)
            if s and depth == 0 then push(base + s - 1, base + e, t.tags); p = e + 1; goto continue end
            -- number, optionally with a unit or %
            s, e = line:find("^%-?%d+%.?%d*%%?[%a]*", p)
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- identifier: a property (before ':') in a block, else a selector name
            s, e = line:find("^%-?[%a_][%w_-]*", p)
            if s then
                if depth > 0 and line:sub(e + 1):match("^%s*:") then
                    push(base + s - 1, base + e, t.attributes)
                elseif depth == 0 then
                    push(base + s - 1, base + e, t.tags)
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
    name       = "CSS",
    extensions = { ".css" },
    highlight  = lex,
}
