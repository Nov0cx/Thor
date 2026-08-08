local t = thor.theme

-- PowerShell pure-Lua lexer. `<# #>` block comments span lines, so the
-- comment flag is carried across the line loop like css.lua's /* */. Word
-- operators (-eq, -and, ...) and Verb-Noun cmdlet names are pattern-matched
-- rather than pulled from a fixed table, since PowerShell's cmdlet surface
-- is open-ended.
local KEYWORDS = {}
for _, w in ipairs {
    "begin", "break", "catch", "class", "continue", "data", "define", "do",
    "dynamicparam", "else", "elseif", "end", "enum", "exit", "filter",
    "finally", "for", "foreach", "from", "function", "hidden", "if", "in",
    "inlinescript", "parallel", "param", "process", "return", "sequence",
    "static", "switch", "throw", "trap", "try", "until", "using", "var",
    "while", "workflow", "module", "namespace",
} do
    KEYWORDS[w] = true
end

local LITERALS = { ["$true"] = true, ["$false"] = true, ["$null"] = true }

-- Index (1-based, inclusive) of the closing quote of a double-quoted string
-- that opens at `p`, honoring PowerShell's backtick escape; nil when
-- unterminated on this line.
local function dquote_end(line, p)
    local i = p + 1
    local len = #line
    while i <= len do
        local c = line:sub(i, i)
        if c == "`" then
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
                local e = line:find("#>", p, true)
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

            -- <# block comment (may run onto later lines)
            if line:sub(p, p + 1) == "<#" then
                in_comment = true
                goto continue
            end
            -- # line comment
            if c == "#" then
                push(base + p - 1, base + len, t.comments)
                return
            end
            -- single-quoted string: literal, '' is an escaped quote
            s, e = line:find("^'[^']*''[^']*'", p)
            if not s then s, e = line:find("^'[^']*'", p) end
            if not s then s, e = line:find("^'.*$", p) end
            if s then push(base + s - 1, base + e, t.strings); p = e + 1; goto continue end
            -- double-quoted string: honors backtick escapes
            if c == '"' then
                local q = dquote_end(line, p)
                local last = q or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end
            -- $true / $false / $null, then ${name}, $scope:name, $name, $_
            s, e = line:find("^%$%a+", p)
            if s and LITERALS[line:sub(s, e):lower()] then
                push(base + s - 1, base + e, t.orange); p = e + 1; goto continue
            end
            s, e = line:find("^%${[^}]*}", p)
            if not s then s, e = line:find("^%$[%a_][%w_]*:[%a_][%w_]*", p) end
            if not s then s, e = line:find("^%$[%a_][%w_]*", p) end
            if not s then s, e = line:find("^%$_", p) end
            if s then push(base + s - 1, base + e, t.variables); p = e + 1; goto continue end
            -- word operator: -eq, -and, -replace, ...
            s, e = line:find("^%-%a+", p)
            if s then push(base + s - 1, base + e, t.operators); p = e + 1; goto continue end
            -- number: decimal/hex, optional size suffix (KB/MB/GB/TB/PB) or type suffix (l/d)
            s, e = line:find("^0[xX]%x+", p)
            if not s then s, e = line:find("^%d+%.?%d*[kKmMgGtTpP]?[bB]?[lLdD]?", p) end
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- operators / punctuation
            s, e = line:find("^%+%+", p)
            if not s then s, e = line:find("^%-%-", p) end
            if not s then s, e = line:find("^[%+%-%*/%%]=", p) end
            if not s then s, e = line:find("^::", p) end
            if not s then s, e = line:find("^[%+%-%*/%%=|&;,%.<>!]", p) end
            if s then push(base + s - 1, base + e, t.operators); p = e + 1; goto continue end
            -- Verb-Noun cmdlet name: the hyphen is not a %w character, so this
            -- is matched separately from a plain identifier.
            s, e = line:find("^%u%l+%-%u[%w]*", p)
            if s then push(base + s - 1, base + e, t.functions); p = e + 1; goto continue end
            -- word: a keyword from the table, otherwise left uncoloured
            s, e = line:find("^[%a_][%w_]*", p)
            if s then
                local word = line:sub(s, e)
                if KEYWORDS[word:lower()] then
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
    name       = "PowerShell",
    extensions = { ".ps1", ".psm1", ".psd1", ".ps1xml" },
    highlight  = lex,
}
