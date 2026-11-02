-- FASM and fasm2 (fasmg + CALM) lexer. Tracks the open macro blocks across
-- lines: fasm1 bodies in { } (a nested level escaped as \{ \}), fasmg bodies
-- closed by `end <kind>`. Parameters of every open block color inside it.

local t = thor.theme

local function set(words)
    local s = {}
    for w in words:gmatch("%S+") do
        s[w] = true
    end
    return s
end

local DIRECTIVES = set [[
    format entry section segment include include! org use16 use32 use64 align
    virtual label at from as file define redefine equ reequ fix restore purge
    restruc element namespace load store display err assert times data import
    library export heap stack db dw du dd dp df dq dt rb rw rd rp rf rq rt dqq
    ddq dqd dy rdq ry dz rz emit
]]

local OPERAND_ATTRIBUTES = set [[
    pe pe64 elf elf64 mz coff ms ms64 binary gui console native dll efi
    efiboot efiruntime wdm readable writeable writable executable code data
    discardable shareable notpageable import export fixups resource at from as
    dynamic interpreter note gnustack
]]

local SIZES = set [[
    byte word dword fword pword qword tbyte tword dqword xword qqword yword
    dqqword zword ptr near far short
]]

local LOGIC = set "eq eqtype relativeto defined used definite not and or xor shl shr bsf bsr mod rva plt"

local CONTROL = set "if else end break common forward reverse local esc outscope"

-- Words that open a block; the value names what binds parameters.
local HEADERS = {
    macro = "macro", struc = "macro", calminstruction = "macro",
    iterate = "iterate", irp = "iterate", irps = "iterate", irpv = "iterate",
    rept = "rept", ["repeat"] = "rept",
    match = "match", rmatch = "match",
    ["while"] = "none", postpone = "none",
}

local CALM = set [[
    assemble arrange compute check jyes jno jump exit match publish transform
    stringify take display err emit call local init load store
]]

local PREFIXES = set "rep repe repz repne repnz lock"

local REGISTERS = set [[
    rax rbx rcx rdx rsi rdi rbp rsp rip eax ebx ecx edx esi edi ebp esp eip ax bx
    cx dx si di bp sp ip al bl cl dl ah bh ch dh sil dil bpl spl cs ds es fs gs ss
]]

local function is_register(w)
    return REGISTERS[w]
        or w:match("^r%d+[dwbl]?$")
        or w:match("^[xyz]mm%d+$")
        or w:match("^mm%d+$")
        or w:match("^k%d+$")
        or w:match("^st%d*$")
        or w:match("^[cdt]r%d+$")
        or w:match("^bnd%d$")
        or w:match("^tmm%d$")
end

local IDENT = "[%a_%.%$@%?][%w_%.%$@%?!]*"

local function add_name(params, piece)
    local name = piece:match("^[%s%[%]<>]*(" .. IDENT .. ")")
    if name then
        params[name] = true
    end
end

-- Adds each comma-separated element's leading name to `params`.
local function add_list(params, list)
    for piece in (list .. ","):gmatch("([^,]*),") do
        add_name(params, piece)
    end
end

-- Reads a header; `rest` is the line after the header word. Returns the
-- parameter set and, for a macro, its name.
local function parse_header(kind, rest)
    local params = {}
    rest = rest:gsub("[;{\\].*$", "")
    if kind == "macro" then
        local lbl, after = rest:match("^%s*%(%s*(" .. IDENT .. ")%s*%)(.*)$")
        if lbl then
            params[lbl] = true
            rest = after
        end
        local name, tail = rest:match("^%s*(" .. IDENT .. ")(.*)$")
        if tail then
            tail = tail:gsub("^:", "")
            add_list(params, tail)
        end
        return params, name
    elseif kind == "iterate" then
        local group = rest:match("^%s*<([^>]*)>")
        if group then
            add_list(params, group)
        else
            add_name(params, rest)
        end
    elseif kind == "rept" then
        local tail = rest:match("^%s*[^%s,]+(.*)$")
        if tail then
            add_list(params, (tail:gsub("^%s*,", "")))
        end
    elseif kind == "match" then
        local depth, stop = 0, #rest + 1
        for q = 1, #rest do
            local c = rest:sub(q, q)
            if c == "<" or c == "(" or c == "[" then
                depth = depth + 1
            elseif c == ">" or c == ")" or c == "]" then
                depth = depth - 1
            elseif c == "," and depth <= 0 and rest:sub(q - 1, q - 1) ~= "=" then
                stop = q
                break
            end
        end
        local pattern = rest:sub(1, stop - 1)
        for at, w in pattern:gmatch("()(" .. IDENT .. ")") do
            if pattern:sub(at - 1, at - 1) ~= "=" then
                params[w] = true
            end
        end
    end
    return params
end

-- Strips the fasmg name suffixes `?`, `!` and `:` and lowercases.
local function macro_key(name)
    return (name:gsub("[%?!:]+$", "")):lower()
end

local M = {}

function M.lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local stack = {}   -- open blocks: { kind, word, params, brace }
    local pending = nil -- a header whose body has not started
    local macros = {}

    local function is_param(w)
        if pending and pending.params[w] then
            return true
        end
        for k = #stack, 1, -1 do
            if stack[k].params[w] then
                return true
            end
        end
        return false
    end

    local function in_calm()
        local top = stack[#stack]
        return top ~= nil and top.word == "calminstruction"
    end

    local function close_brace()
        for k = #stack, 1, -1 do
            if stack[k].brace then
                for _ = k, #stack do
                    table.remove(stack)
                end
                return true
            end
        end
        return false
    end

    local function close_end(word)
        for k = #stack, 1, -1 do
            if not stack[k].brace and stack[k].word == word then
                for _ = k, #stack do
                    table.remove(stack)
                end
                return
            end
        end
    end

    local function inline(line, base)
        local len = #line
        local p = 1
        local inst = true
        local expect_name = false
        local match_pattern = false
        local escaped = false

        -- A header with no `{` on its line opens a fasmg body at the next
        -- line that holds code.
        if pending then
            local first = line:match("^%s*(.)")
            if first and first ~= ";" and first ~= "{" and first ~= "\\" then
                pending.brace = false
                stack[#stack + 1] = pending
                pending = nil
            end
        end

        while p <= len do
            local c = line:sub(p, p)
            local s, e

            if c:match("%s") then
                p = p + 1
                goto continue
            end

            if c == ";" then
                push(base + p - 1, base + len, t.comments)
                return
            end

            if c == '"' or c == "'" then
                local q = p + 1
                while q <= len do
                    if line:sub(q, q) == c then
                        if line:sub(q + 1, q + 1) ~= c then break end
                        q = q + 2
                    else
                        q = q + 1
                    end
                end
                if q > len then q = len end
                push(base + p - 1, base + q, t.strings)
                p = q + 1
                inst = false
                goto continue
            end

            -- braces, escaped braces and escapes
            if c == "\\" or c == "{" or c == "}" then
                s, e = line:find("^\\*", p)
                local brace = line:sub(e + 1, e + 1)
                if brace == "{" or brace == "}" then
                    e = e + 1
                    if brace == "{" and pending then
                        pending.brace = true
                        stack[#stack + 1] = pending
                        pending = nil
                    elseif brace == "}" then
                        close_brace()
                    end
                    inst = true
                end
                if e < s then e = s end
                push(base + s - 1, base + e, t.operators)
                p = e + 1
                goto continue
            end

            if c:match("%d") then
                s, e = line:find("^%d[%w_]*%.?[%w_]*", p)
                if line:sub(e, e):match("[eE]") then
                    local _, x = line:find("^[%+%-]%d+", e + 1)
                    if x then e = x end
                end
                push(base + s - 1, base + e, t.numbers)
                p = e + 1
                inst = false
                goto continue
            end

            -- $ and $$ location counters, $FF hex
            if c == "$" then
                s, e = line:find("^%$[%x_]+%f[^%w_%.%$@%?!]", p)
                if s then
                    push(base + s - 1, base + e, t.numbers)
                    p = e + 1
                    inst = false
                    goto continue
                end
                s, e = line:find("^%$%$?%f[^%w_%.%$@%?!]", p)
                if s then
                    push(base + s - 1, base + e, t.variables)
                    p = e + 1
                    inst = false
                    goto continue
                end
            end

            -- % and %% repeat counters, %t timestamp
            if c == "%" then
                s, e = line:find("^%%[%%t]?%f[^%w_]", p)
                if s then
                    push(base + s - 1, base + e, t.variables)
                    p = e + 1
                    goto continue
                end
            end

            -- ? alone is uninitialized data
            if c == "?" and not line:sub(p + 1, p + 1):match("[%w_%.%$@%?!]") then
                push(base + p - 1, base + p, t.variables)
                p = p + 1
                goto continue
            end

            -- =word in a match pattern is a literal
            if c == "=" and match_pattern then
                s, e = line:find("^=" .. IDENT, p)
                if not s then s, e = p, p end
                push(base + s - 1, base + e, t.operators)
                p = e + 1
                goto continue
            end
            if c == "," and match_pattern and line:sub(p - 1, p - 1) ~= "=" then
                match_pattern = false
            end

            s, e = line:find("^" .. IDENT, p)
            if s then
                local w = line:sub(s, e)
                local lw = w:lower()

                if is_param(w) and not expect_name then
                    push(base + s - 1, base + e, t.parameters)
                    inst = false
                    p = e + 1
                    goto continue
                end

                if expect_name then
                    expect_name = false
                    if line:sub(s - 1, s - 1) ~= "(" or not is_param(w) then
                        macros[macro_key(w)] = true
                        push(base + s - 1, base + e, t.functions)
                        p = e + 1
                        goto continue
                    end
                    expect_name = true
                    push(base + s - 1, base + e, t.parameters)
                    p = e + 1
                    goto continue
                end

                if lw == "@f" or lw == "@b" or lw == "@r" then
                    push(base + s - 1, base + e, t.functions)
                    p = e + 1
                    inst = false
                    goto continue
                end

                if inst then
                    -- label
                    local after = line:sub(e + 1, e + 1)
                    if after == ":" and line:sub(e + 2, e + 2) ~= "=" then
                        push(base + s - 1, base + e + 1, t.functions)
                        p = e + 2
                        goto continue
                    end

                    if in_calm() and CALM[lw] then
                        push(base + s - 1, base + e, t.keywords)
                        if lw == "match" then match_pattern = true end
                        inst = false
                        p = e + 1
                        goto continue
                    end

                    if lw == "esc" then
                        escaped = true
                        push(base + s - 1, base + e, t.keywords)
                        p = e + 1
                        goto continue
                    end

                    if lw == "end" then
                        local ws, we = line:find("^%s+" .. IDENT, e + 1)
                        if ws then
                            local kind = line:sub(ws, we):match(IDENT .. "$")
                            if not escaped then
                                close_end(kind:lower())
                            end
                            e = we
                        end
                        push(base + s - 1, base + e, t.keywords)
                        inst = false
                        p = e + 1
                        goto continue
                    end

                    local kind = HEADERS[lw]
                    if kind then
                        push(base + s - 1, base + e, t.keywords)
                        if not escaped then
                            local params, _ = parse_header(kind, line:sub(e + 1))
                            pending = { word = lw, params = params, brace = false }
                        end
                        if kind == "macro" then expect_name = true end
                        if kind == "match" then match_pattern = true end
                        inst = false
                        p = e + 1
                        goto continue
                    end

                    if CONTROL[lw] then
                        push(base + s - 1, base + e, t.keywords)
                        if lw == "local" and #stack > 0 then
                            add_list(stack[#stack].params, (line:sub(e + 1):gsub(";.*$", "")))
                        end
                        inst = lw == "common" or lw == "forward" or lw == "reverse"
                        p = e + 1
                        goto continue
                    end

                    if DIRECTIVES[lw] then
                        push(base + s - 1, base + e, t.attributes)
                        inst = false
                        p = e + 1
                        goto continue
                    end

                    -- a name that a directive or an assignment defines
                    local nxt = line:match("^%s+(" .. IDENT .. ")", e + 1)
                    if (nxt and DIRECTIVES[nxt:lower()]) or line:find("^%s*:?=[^=]", e + 1)
                        or line:find("^%s*=:", e + 1) then
                        push(base + s - 1, base + e, t.variables)
                        p = e + 1
                        goto continue
                    end

                    if macros[macro_key(w)] then
                        push(base + s - 1, base + e, t.functions)
                    else
                        push(base + s - 1, base + e, t.keywords)
                    end
                    inst = PREFIXES[lw] or false
                    p = e + 1
                    goto continue
                end

                if is_register(lw) then
                    push(base + s - 1, base + e, t.variables)
                elseif SIZES[lw] or LOGIC[lw] then
                    push(base + s - 1, base + e, t.keywords)
                elseif OPERAND_ATTRIBUTES[lw] then
                    push(base + s - 1, base + e, t.attributes)
                end
                p = e + 1
                goto continue
            end

            if c:match("[,%+%-%*/%[%]%(%):!=<>&|%^~#`]") then
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
        inline(src:sub(i, stop), i - 1)
        i = (nl or n) + 1
    end

    return spans
end

return M
