local t = thor.theme

-- Groovy pure-Lua lexer (Gradle's build.gradle DSL). C-family shape, so only
-- /* */ carries across the line loop like slang.lua. GString interpolation
-- inside "..." is not resolved separately — the whole quoted run is one
-- string span, same simplification javascript's grammar-free siblings use.
local KEYWORDS = {}
for _, w in ipairs {
    "as", "assert", "break", "case", "catch", "class", "const", "continue",
    "def", "default", "do", "else", "enum", "extends", "finally", "for",
    "goto", "if", "implements", "import", "in", "instanceof", "interface",
    "new", "package", "return", "super", "switch", "this", "throw", "throws",
    "trait", "try", "while", "static", "public", "private", "protected",
    "abstract", "final", "native", "synchronized", "transient", "volatile",
    "strictfp",
} do
    KEYWORDS[w] = true
end

local CONSTANTS = { ["true"] = true, ["false"] = true, ["null"] = true }

local TYPES = {}
for _, w in ipairs {
    "void", "boolean", "byte", "char", "short", "int", "long", "float",
    "double", "String", "Object", "def",
} do
    TYPES[w] = true
end

-- Index (1-based, inclusive) of the closing quote of a double-quoted string
-- that opens at `p`, honoring backslash escapes; nil when unterminated.
local function dquote_end(line, p)
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

    local in_comment = false

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
            local two = line:sub(p, p + 1)
            local s, e

            -- // line comment
            if two == "//" then
                push(base + p - 1, base + len, t.comments)
                return
            end
            -- /* block comment (may run onto later lines)
            if two == "/*" then
                in_comment = true
                goto continue
            end
            -- triple-quoted string: consumed to the closing """/''' on this line,
            -- or to end of line when it runs on (kept simple, single-line span)
            if line:sub(p, p + 2) == '"""' or line:sub(p, p + 2) == "'''" then
                local q = line:sub(p, p + 2)
                local close = line:find(q, p + 3, true)
                local last = close and (close + 2) or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end
            -- double-quoted GString, honoring backslash escapes
            if c == '"' then
                local q = dquote_end(line, p)
                local last = q or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end
            -- single-quoted string: literal
            if c == "'" then
                s, e = line:find("^'[^']*'", p)
                if not s then s, e = line:find("^'.*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1; goto continue
            end
            -- @Annotation
            s, e = line:find("^@[%a_][%w_%.]*", p)
            if s then push(base + s - 1, base + e, t.attributes); p = e + 1; goto continue end
            -- number: hex, then plain, each with a type suffix
            s, e = line:find("^0[xX]%x+[lL]?", p)
            if not s then s, e = line:find("^%d+%.?%d*[eE]?[-+]?%d*[lLfFdDgGiI]?", p) end
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- word: keyword, constant, type, or a call
            s, e = line:find("^[%a_][%w_]*", p)
            if s then
                local w = line:sub(s, e)
                if KEYWORDS[w] then
                    push(base + s - 1, base + e, t.keywords)
                elseif CONSTANTS[w] then
                    push(base + s - 1, base + e, t.conflict)
                elseif TYPES[w] then
                    push(base + s - 1, base + e, t.warning)
                elseif line:sub(e + 1):match("^%s*%(") then
                    push(base + s - 1, base + e, t.functions)
                end
                p = e + 1
                goto continue
            end

            if c:match("[%+%-%*/%%=<>!&|%^~%?:;,%.]") then
                push(base + p - 1, base + p, t.operators)
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
    name       = "Groovy",
    extensions = { ".groovy", ".gradle", ".gvy", ".gy" },
    highlight  = lex,
}
