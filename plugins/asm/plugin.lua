-- Assembly syntax highlighting: one lexer for GAS (x86, ARM, AArch64, RISC-V,
-- MIPS), NASM/YASM, MASM and the 8-bit assemblers. The mnemonic is found by
-- its position on the line, so every instruction set colors without a list.
-- A .asm that reads as FASM goes to the FASM lexer in fasm.lua.

local t = thor.theme
local fasm = require "fasm"

local function set(words)
    local s = {}
    for w in words:gmatch("%S+") do
        s[w] = true
    end
    return s
end

-- Bare directives, matched lowercased in mnemonic position.
local DIRECTIVES = set [[
    section segment global globl extern extrn bits org db dw dd dq dt do dy dz
    resb resw resd resq rest reso resy resz incbin times equ align alignb default
    proc endp macro endm struc endstruc struct ends istruc iend at assume model
    end include invoke public label cpu use16 use32 use64 absolute common static
    option local uses if else elseif endif ifdef ifndef rept irp irpc while exitm
    purge textequ catstr record union typedef ds defb defw defs dfb dfs fcb fdb
    fcc rmb byte sbyte word sword dword sdword fword qword tbyte real4 real8
    real10 oword
]]

-- Size and address words, colored in operand position.
local OPERAND_WORDS = set [[
    byte word dword qword tbyte tword oword fword xmmword ymmword zmmword ptr
    offset rel abs near far short seg wrt flat
]]

-- A word in front of one of these is a name it defines.
local NAME_DIRECTIVES = set [[
    proc endp macro struc struct ends segment record union typedef label equ
    textequ catstr db dw dd dq dt do resb resw resd resq sbyte sword sdword
    real4 real8 real10
]]
local FUNCTION_DIRECTIVES = set "proc endp macro struc struct ends segment record union typedef label"

local PREFIXES = set "rep repe repz repne repnz lock data16 data32 addr16 addr32"

local SECTIONS = set ".text .data .bss .rodata .rdata .code .const .init .fini .tdata .tbss .note .comment"

local CPP = set "include define undef if ifdef ifndef elif else endif error warning pragma line"

local REGISTERS = set [[
    rax rbx rcx rdx rsi rdi rbp rsp rip eax ebx ecx edx esi edi ebp esp eip ax bx
    cx dx si di bp sp ip al bl cl dl ah bh ch dh sil dil bpl spl cs ds es fs gs ss
    eflags rflags flags mxcsr lr pc fp sb sl xzr wzr zero ra gp tp hl bc de af ix
    iy ixh ixl iyh iyl a b c d e h l x y z sr ccr usp ctr xer apsr cpsr spsr fpscr
    nzcv fpcr fpsr
]]

local MIPS = set "zero at v0 v1 k0 k1 gp sp fp ra"

local function is_register(w)
    return REGISTERS[w]
        or w:match("^[rxwvqdshbcpftsaz]%d+[dwb]?$")
        or w:match("^f[tsa]%d+$")
        or w:match("^[xyz]mm%d+$")
        or w:match("^mm%d+$")
        or w:match("^k%d+$")
        or w:match("^st%d*$")
        or w:match("^[cdt]r%d+$")
        or w:match("^bnd%d$")
        or w:match("^tmm%d$")
end

-- True when a .asm buffer reads as FASM or fasm2.
local function is_fasm(src)
    local head = "\n" .. src:sub(1, 8192):lower()
    return head:find("\n[ \t]*format[ \t]+%a") ~= nil
        or head:find("\n[ \t]*entry[ \t]+[%a_]") ~= nil
        or head:find("\n[ \t]*include[ \t]+['\"]") ~= nil
        or head:find("\n[ \t]*macro[ \t]+[%w_.?!@]+") ~= nil
        or head:find("\n[ \t]*end[ \t]+macro") ~= nil
        or head:find("calminstruction", 1, true) ~= nil
        or head:find("\n[ \t]*struc[ \t][^\n;]*{") ~= nil
end

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    local in_block = false

    -- Lexes line[p..]; `base` is the line's 0-based byte offset.
    local function inline(line, base, p)
        local len = #line
        local inst = true

        while p <= len do
            local c = line:sub(p, p)
            local s, e

            if c:match("%s") then
                p = p + 1
                goto continue
            end

            -- comments
            if c == ";" or line:sub(p, p + 1) == "//" then
                push(base + p - 1, base + len, t.comments)
                return
            end
            if line:sub(p, p + 1) == "/*" then
                e = line:find("*/", p + 2, true)
                if not e then
                    push(base + p - 1, base + len, t.comments)
                    in_block = true
                    return
                end
                push(base + p - 1, base + e + 1, t.comments)
                p = e + 2
                goto continue
            end
            if c == "#" then
                local nxt = line:sub(p + 1, p + 1)
                if inst then
                    s, e = line:find("^#%s*%a+", p)
                    if s and CPP[line:sub(s, e):match("%a+$")] then
                        push(base + s - 1, base + e, t.keywords)
                        p = e + 1
                        inst = false
                        goto continue
                    end
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                if nxt == "" or nxt:match("%s") then
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                push(base + p - 1, base + p, t.operators)
                p = p + 1
                goto continue
            end
            if c == "@" then
                local nxt = line:sub(p + 1, p + 1)
                if nxt == "" or nxt:match("%s") then
                    push(base + p - 1, base + len, t.comments)
                    return
                end
                s, e = line:find("^@@:?", p)
                if not s then s, e = line:find("^@[FfBb]%f[^%w_]", p) end
                if s then
                    push(base + s - 1, base + e, t.functions)
                    p = e + 1
                    goto continue
                end
                s, e = line:find("^@[%a_][%w_]*", p)
                if s then
                    push(base + s - 1, base + e, t.attributes)
                    p = e + 1
                    goto continue
                end
                push(base + p - 1, base + p, t.operators)
                p = p + 1
                goto continue
            end

            -- strings
            if c == '"' or c == "'" or c == "`" then
                local q = p + 1
                while q <= len do
                    local d = line:sub(q, q)
                    if d == "\\" then
                        q = q + 2
                    elseif d == c then
                        break
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

            -- %: NASM preprocessor and macro arguments, AT&T and SPARC registers
            if c == "%" then
                s, e = line:find("^%%%%?[%w_%.]+", p)
                if s then
                    local role = t.variables
                    if inst and line:sub(s + 1, s + 1):match("%a") then
                        role = t.attributes
                    end
                    push(base + s - 1, base + e, role)
                    p = e + 1
                    inst = false
                    goto continue
                end
                push(base + p - 1, base + p, t.operators)
                p = p + 1
                goto continue
            end

            -- $: AT&T immediates, hex, MIPS registers, the location counter
            if c == "$" then
                s, e = line:find("^%$[%a_][%w_]*", p)
                if s then
                    local w = line:sub(s + 1, e):lower()
                    if MIPS[w] or is_register(w) or w:match("^[vatskf]%d+$") then
                        push(base + s - 1, base + e, t.variables)
                        p = e + 1
                        goto continue
                    end
                    if w:match("^[%x_]+$") then
                        push(base + s - 1, base + e, t.numbers)
                        p = e + 1
                        goto continue
                    end
                    p = e + 1
                    goto continue
                end
                s, e = line:find("^%$%-?[%d][%w_%.]*", p)
                if s then
                    push(base + s - 1, base + e, t.numbers)
                    p = e + 1
                    goto continue
                end
                s, e = line:find("^%$%$?", p)
                push(base + s - 1, base + e, t.variables)
                p = e + 1
                goto continue
            end

            -- numbers, with numeric local labels (1:, 1f, 1b)
            if c:match("%d") then
                s, e = line:find("^%d[%w_]*%.?[%w_]*", p)
                if line:sub(e, e):match("[eE]") then
                    local _, x = line:find("^[%+%-]%d+", e + 1)
                    if x then e = x end
                end
                if inst and line:sub(e + 1, e + 1) == ":" then
                    push(base + s - 1, base + e + 1, t.functions)
                    p = e + 2
                    goto continue
                end
                push(base + s - 1, base + e, t.numbers)
                p = e + 1
                inst = false
                goto continue
            end

            -- words
            s, e = line:find("^[%a_%.][%w_%.%$@]*", p)
            if s then
                local w = line:sub(s, e)
                local lw = w:lower()
                if lw == "af" and line:sub(e + 1, e + 1) == "'" then
                    e = e + 1
                end
                if inst then
                    if line:sub(e + 1, e + 1) == ":" and line:sub(e + 2, e + 2) ~= "=" then
                        local stop = e + 1
                        if line:sub(stop + 1, stop + 1) == ":" then stop = stop + 1 end
                        push(base + s - 1, base + stop, t.functions)
                        p = stop + 1
                        goto continue
                    end
                    local nxt = line:match("^%s+([%w_%.]+)", e + 1)
                    local assigns = line:find("^%s*=[^=]", e + 1) ~= nil
                    if (nxt and NAME_DIRECTIVES[nxt:lower()]) or assigns then
                        local role = t.variables
                        if nxt and FUNCTION_DIRECTIVES[nxt:lower()] then role = t.functions end
                        push(base + s - 1, base + e, role)
                        p = e + 1
                        goto continue
                    end
                    if lw:sub(1, 1) == "." or DIRECTIVES[lw] then
                        push(base + s - 1, base + e, t.attributes)
                    else
                        push(base + s - 1, base + e, t.keywords)
                    end
                    inst = PREFIXES[lw] or false
                    p = e + 1
                    goto continue
                end
                if is_register(lw) then
                    push(base + s - 1, base + e, t.variables)
                elseif OPERAND_WORDS[lw] or SECTIONS[lw] then
                    push(base + s - 1, base + e, OPERAND_WORDS[lw] and t.keywords or t.attributes)
                end
                p = e + 1
                goto continue
            end

            -- line-start comments of SPARC and the 6800/68k family
            if inst and (c == "!" or (c == "*" and p == 1)) then
                push(base + p - 1, base + len, t.comments)
                return
            end

            if c:match("[,%+%-%*/%[%]%(%):!=<>&|%^~{}]") then
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

        local p = 1
        if in_block then
            local e = line:find("*/", 1, true)
            if not e then
                push(base, base + #line, t.comments)
                goto next_line
            end
            push(base, base + e + 1, t.comments)
            in_block = false
            p = e + 2
        end
        inline(line, base, p)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "Assembly",
    extensions = {
        ".asm", ".ASM", ".s", ".S", ".nasm", ".yasm", ".masm",
        ".a51", ".z80", ".a65", ".6502", ".avr", ".mac",
    },
    highlight  = function(src)
        if is_fasm(src) then
            return fasm.lex(src)
        end
        return lex(src)
    end,
}

thor.register_language {
    name       = "FASM",
    extensions = { ".fasm", ".fasmg", ".fasm2", ".ash" },
    highlight  = fasm.lex,
}
