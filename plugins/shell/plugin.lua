local t = thor.theme

-- Shell is case-sensitive. Control-flow words plus the builtins that read as
-- keywords in everyday scripts.
local KEYWORDS = {}
for _, w in ipairs {
    "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "in", "function", "select", "return", "break", "continue",
    "exit", "local", "export", "readonly", "declare", "typeset", "source",
    "eval", "exec", "trap", "set", "unset", "shift", "alias", "unalias", "let",
    "echo", "printf", "read", "cd", "pwd", "test", "true", "false", "getopts",
    "wait", "umask", "ulimit", "times", "type", "command", "builtin",
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

    -- Open here-documents: { word, strip_tabs, raw }, oldest first.
    local pending = {}

    -- Scans line[p..] (p is 1-based) for spans, appending them with the line's
    -- 0-based byte offset `base`. `^` anchors each pattern to the cursor.
    local function inline(line, base, p)
        local len = #line
        while p <= len do
            local c = line:sub(p, p)

            -- comment: '#' at line start or after whitespace, to end of line
            if c == "#" and (p == 1 or line:sub(p - 1, p - 1):match("%s")) then
                push(base + p - 1, base + len, t.comments)
                return
            end

            local s, e
            -- single-quoted string: literal, no escapes
            s, e = line:find("^'[^']*'", p)
            if not s then s, e = line:find("^'[^']*$", p) end
            if s then push(base + s - 1, base + e, t.strings); p = e + 1; goto continue end

            -- double-quoted string: honors backslash escapes
            if c == '"' then
                local q = dquote_end(line, p)
                local last = q or len
                push(base + p - 1, base + last, t.strings)
                p = last + 1
                goto continue
            end

            -- variables: ${...}, $name, $1, and the specials $@ $* $# $? $$ $! $-
            s, e = line:find("^%${[^}]*}", p)
            if not s then s, e = line:find("^%$[%a_][%w_]*", p) end
            if not s then s, e = line:find("^%$%d", p) end
            if not s then s, e = line:find("^%$[@%*#%?%$!%-]", p) end
            if s then push(base + s - 1, base + e, t.variables); p = e + 1; goto continue end

            -- here-document opener: <<WORD, <<-WORD, <<'WORD', <<"WORD", <<\WORD
            if not line:find("^<<<", p) then
                local dash, q, bs, word
                s, e, dash, q, bs, word = line:find("^<<(%-?)%s*(['\"]?)(\\?)([%a_][%w_]*)", p)
                if s then
                    push(base + s - 1, base + s + #dash + 1, t.operators)
                    push(base + e - #word, base + e, t.tags)
                    if q ~= "" and line:sub(e + 1, e + 1) == q then
                        e = e + 1
                    end
                    pending[#pending + 1] = { word, dash == "-", q ~= "" or bs ~= "" }
                    p = e + 1
                    goto continue
                end
            end

            -- operators: separators and redirection
            s, e = line:find("^&&", p)
            if not s then s, e = line:find("^||", p) end
            if not s then s, e = line:find("^;;", p) end
            if not s then s, e = line:find("^>>", p) end
            if not s then s, e = line:find("^<<", p) end
            if not s then s, e = line:find("^[|&;<>=]", p) end
            if s then push(base + s - 1, base + e, t.operators); p = e + 1; goto continue end

            -- bare number
            s, e = line:find("^%d+", p)
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end

            -- word: a `name()` definition is a function; otherwise color known
            -- keywords. Either way skip past it so keywords inside longer words
            -- never light up.
            s, e = line:find("^[%a_][%w_]*", p)
            if s then
                if line:sub(e + 1):match("^%s*%(%)") then
                    push(base + s - 1, base + e, t.functions)
                elseif KEYWORDS[line:sub(s, e)] then
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

        local doc = pending[1]
        if doc then
            local text = line:gsub("\r$", "")
            local lead = 0
            if doc[2] then
                lead = #text:match("^\t*")
                text = text:sub(lead + 1)
            end
            if text == doc[1] then
                push(base + lead, base + lead + #text, t.tags)
                table.remove(pending, 1)
            elseif doc[3] then
                push(base, base + #line, t.strings)
            else
                local from = 1
                while true do
                    local vs, ve = line:find("^%${[^}]*}", from)
                    local pos = from
                    while not vs do
                        pos = line:find("%$", pos)
                        if not pos then break end
                        vs, ve = line:find("^%${[^}]*}", pos)
                        if not vs then vs, ve = line:find("^%$[%a_][%w_]*", pos) end
                        if not vs then pos = pos + 1 end
                    end
                    if not vs then break end
                    push(base + from - 1, base + vs - 1, t.strings)
                    push(base + vs - 1, base + ve, t.variables)
                    from = ve + 1
                end
                push(base + from - 1, base + #line, t.strings)
            end
        else
            inline(line, base, 1)
        end
    end

    return spans
end

thor.register_language {
    name       = "Shell",
    extensions = { ".sh", ".bash", ".zsh", ".ksh", ".bashrc", ".zshrc", ".profile", ".envrc" },
    highlight  = lex,
}
