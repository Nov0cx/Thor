local t = thor.theme

-- CMake pure-Lua lexer. Quoted arguments and `#[[ ]]` bracket comments both run
-- onto later lines, so their flags are carried across the line loop. Commands are
-- case-insensitive: control flow is a keyword, any other `name(` is a function,
-- and the all-caps argument words (PUBLIC, REQUIRED, ...) read as attributes.
-- Registers the bare `CMakeLists.txt` name too, since the host prefers a claimed
-- extension and no plugin claims `.txt`.
local KEYWORDS = {}
for _, w in ipairs {
    "if", "elseif", "else", "endif", "foreach", "endforeach", "while",
    "endwhile", "function", "endfunction", "macro", "endmacro", "break",
    "continue", "return", "block", "endblock",
} do
    KEYWORDS[w] = true
end

-- The words that read as operators inside an if() condition.
local OPERATORS = {}
for _, w in ipairs {
    "AND", "OR", "NOT", "STREQUAL", "STRLESS", "STRGREATER", "MATCHES",
    "EQUAL", "LESS", "GREATER", "LESS_EQUAL", "GREATER_EQUAL", "VERSION_EQUAL",
    "VERSION_LESS", "VERSION_GREATER", "VERSION_LESS_EQUAL",
    "VERSION_GREATER_EQUAL", "DEFINED", "EXISTS", "COMMAND", "TARGET", "TEST",
    "IN_LIST", "IS_DIRECTORY", "IS_ABSOLUTE", "IS_NEWER_THAN",
} do
    OPERATORS[w] = true
end

local CONSTANTS = {}
for _, w in ipairs { "TRUE", "FALSE", "ON", "OFF", "YES", "NO", "NOTFOUND", "IGNORE" } do
    CONSTANTS[w] = true
end

-- Index (1-based, inclusive) of the closing quote of a string that opens at `p`,
-- honoring backslash escapes; nil when the string runs onto the next line.
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

    local in_comment = false -- inside a #[[ ]] bracket comment
    local in_string = false

    local function inline(line, base, p)
        local len = #line
        while p <= len do
            if in_comment then
                local e = line:find("]]", p, true)
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
            if in_string then
                local e = line:find('"', p, true)
                if e then
                    push(base + p - 1, base + e, t.strings)
                    in_string = false
                    p = e + 1
                else
                    push(base + p - 1, base + len, t.strings)
                    return
                end
                goto continue
            end

            local c = line:sub(p, p)
            local s, e

            -- #[[ bracket comment ]] (may run onto later lines)
            if line:sub(p, p + 2) == "#[[" then
                in_comment = true
                goto continue
            end
            -- # line comment
            if c == "#" then
                push(base + p - 1, base + len, t.comments)
                return
            end
            -- quoted argument (may run onto later lines)
            if c == '"' then
                local q = dquote_end(line, p)
                if q then
                    push(base + p - 1, base + q, t.strings)
                    p = q + 1
                else
                    push(base + p - 1, base + len, t.strings)
                    in_string = true
                    return
                end
                goto continue
            end
            -- ${VAR}, $ENV{VAR}, $CACHE{VAR} and the $<...> generator expressions
            s, e = line:find("^%$%u*{[^}]*}", p)
            if not s then s, e = line:find("^%$<[^>]*>", p) end
            if s then push(base + s - 1, base + e, t.variables); p = e + 1; goto continue end
            -- version or plain number
            s, e = line:find("^%d+[%.%d]*", p)
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- word: control flow, a `name(` command, a constant, an operator
            -- word, or an all-caps argument word
            s, e = line:find("^[%a_][%w_%-]*", p)
            if s then
                local w = line:sub(s, e)
                if KEYWORDS[w:lower()] then
                    push(base + s - 1, base + e, t.keywords)
                elseif line:sub(e + 1):match("^%s*%(") then
                    push(base + s - 1, base + e, t.functions)
                elseif CONSTANTS[w] then
                    push(base + s - 1, base + e, t.conflict)
                elseif OPERATORS[w] then
                    push(base + s - 1, base + e, t.keywords)
                elseif w:match("^%u[%u%d_]*$") then
                    push(base + s - 1, base + e, t.attributes)
                end
                p = e + 1
                goto continue
            end

            if c == "(" or c == ")" or c == ";" then
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
    name       = "CMake",
    extensions = { ".cmake", "CMakeLists.txt", "cmakelists.txt" },
    highlight  = lex,
}
