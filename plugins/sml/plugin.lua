local t = thor.theme

-- Standard ML pure-Lua lexer. Both available tree-sitter SML grammars fail to
-- build under MSVC (GCC-only `__attribute__` scanner syntax, or a C++-only
-- scanner.cc this build's clone-and-compile pipeline does not handle), so this
-- is a lexer instead. (* *) comments nest, so a depth counter — not a flag —
-- carries across the line loop like css.lua's in_comment flag does.
local KEYWORDS = {}
for _, w in ipairs {
    "abstype", "and", "andalso", "as", "case", "datatype", "do", "else",
    "end", "exception", "fn", "fun", "functor", "handle", "if", "in",
    "infix", "infixr", "let", "local", "nonfix", "of", "op", "open",
    "orelse", "raise", "rec", "sharing", "sig", "signature", "struct",
    "structure", "then", "type", "val", "while", "with", "withtype",
    "eqtype", "include",
} do
    KEYWORDS[w] = true
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

    local depth = 0

    local function inline(line, base, p)
        local len = #line
        while p <= len do
            if depth > 0 then
                local open_at = line:find("(*", p, true)
                local close_at = line:find("*)", p, true)
                if close_at and (not open_at or close_at < open_at) then
                    push(base + p - 1, base + close_at + 1, t.comments)
                    depth = depth - 1
                    p = close_at + 2
                elseif open_at then
                    push(base + p - 1, base + open_at + 1, t.comments)
                    depth = depth + 1
                    p = open_at + 2
                else
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                goto continue
            end

            local c = line:sub(p, p)
            local s, e

            -- (* comment (nests, may run onto later lines)
            if line:sub(p, p + 1) == "(*" then
                push(base + p - 1, base + p + 1, t.comments)
                depth = 1
                p = p + 2
                goto continue
            end
            -- string, honoring backslash escapes
            if c == '"' then
                local q = dquote_end(line, p)
                local last = q or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end
            -- character literal: #"c"
            s, e = line:find('^#"\\?."', p)
            if s then push(base + s - 1, base + e, t.orange); p = e + 1; goto continue end
            -- number: real (with exponent/fraction) or int, `~` is the unary minus
            s, e = line:find("^~?%d+%.%d+[eE]~?%d+", p)
            if not s then s, e = line:find("^~?%d+[eE]~?%d+", p) end
            if not s then s, e = line:find("^~?%d+%.%d+", p) end
            if not s then s, e = line:find("^~?0[wWxX]%x+", p) end
            if not s then s, e = line:find("^~?%d+", p) end
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- type variable: 'a, ''a
            s, e = line:find("^''?[%a][%w_']*", p)
            if s then push(base + s - 1, base + e, t.yellow); p = e + 1; goto continue end
            -- word: keyword, otherwise left uncoloured
            s, e = line:find("^[%a_][%w_']*", p)
            if s then
                local word = line:sub(s, e)
                if KEYWORDS[word] then
                    push(base + s - 1, base + e, t.keywords)
                elseif line:sub(e + 1):match("^%s*%(") then
                    push(base + s - 1, base + e, t.functions)
                end
                p = e + 1
                goto continue
            end

            if c:match("[%+%-%*/=<>!&|%^~%?:;,%.@#]") then
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
    name       = "Standard ML",
    extensions = { ".sml", ".sig", ".fun" },
    highlight  = lex,
}
