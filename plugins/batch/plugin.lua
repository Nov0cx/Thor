local t = thor.theme

-- Batch is case-insensitive; keywords are matched lowercased. Covers the shell
-- built-ins, control-flow words, and the comparison operators used by `if`.
local KEYWORDS = {}
for _, w in ipairs {
    "echo", "set", "setlocal", "endlocal", "if", "else", "for", "in", "do",
    "goto", "call", "exit", "shift", "pause", "rem", "not", "exist", "defined",
    "errorlevel", "equ", "neq", "lss", "leq", "gtr", "geq", "cd", "chdir", "md",
    "mkdir", "rd", "rmdir", "del", "erase", "copy", "xcopy", "move", "ren",
    "rename", "type", "cls", "start", "pushd", "popd", "title", "color",
    "choice", "find", "findstr", "ver", "verify", "vol", "path", "prompt",
    "date", "time", "assoc", "ftype", "break", "attrib", "more", "sort", "tree",
} do
    KEYWORDS[w] = true
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- Scans line[p..] (p is 1-based) for spans, appending them with the line's
    -- 0-based byte offset `base`. The cursor only advances, so spans stay
    -- ordered and non-overlapping. `^` anchors each pattern to the cursor.
    local function inline(line, base, p)
        local len = #line
        while p <= len do
            local s, e
            -- double-quoted string (closed, else run to end of line)
            s, e = line:find('^"[^"]*"', p)
            if not s then s, e = line:find('^"[^"]*$', p) end
            if s then push(base + s - 1, base + e, t.strings); p = e + 1; goto continue end
            -- variables: %~dp0, %*, %1, %VAR%, %%, !DELAYED!
            s, e = line:find("^%%~[%w]*", p)
            if not s then s, e = line:find("^%%%*", p) end
            if not s then s, e = line:find("^%%%d", p) end
            if not s then s, e = line:find("^%%[^%%%s]-%%", p) end
            if not s then s, e = line:find("^![%w_]+!", p) end
            if s then push(base + s - 1, base + e, t.variables); p = e + 1; goto continue end
            -- label reference: goto :eof / call :sub
            s, e = line:find("^:[%w_%.%-]+", p)
            if s then push(base + s - 1, base + e, t.functions); p = e + 1; goto continue end
            -- operators: @ prefix, redirection and command separators
            s, e = line:find("^&&", p)
            if not s then s, e = line:find("^||", p) end
            if not s then s, e = line:find("^>>", p) end
            if not s then s, e = line:find("^[@&|<>=]", p) end
            if s then push(base + s - 1, base + e, t.operators); p = e + 1; goto continue end
            -- bare number
            s, e = line:find("^%d+", p)
            if s then push(base + s - 1, base + e, t.numbers); p = e + 1; goto continue end
            -- word: color it only when it is a known keyword, but always skip
            -- past it so a keyword inside a longer word never lights up.
            s, e = line:find("^[%a][%w_]*", p)
            if s then
                if KEYWORDS[line:sub(s, e):lower()] then
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

        -- Full-line comment: `::` label-comment, or REM (optionally @-prefixed).
        if line:match("^%s*::")
            or line:match("^%s*@?[Rr][Ee][Mm]%s")
            or line:match("^%s*@?[Rr][Ee][Mm]$") then
            push(base, base + #line, t.comments)
            goto next_line
        end

        inline(line, base, 1)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "Batch",
    extensions = { ".bat", ".cmd" },
    highlight  = lex,
}
