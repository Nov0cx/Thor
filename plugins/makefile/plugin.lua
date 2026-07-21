local t = thor.theme

-- Makefile pure-Lua lexer. Line based: # comments, GNU-make directives, targets
-- (`name:` at line start) as functions, variable assignments (`VAR =`/`:=`/`?=`/
-- `+=`) as attributes, and $(VAR) / ${VAR} / $@ automatic variables. Registers
-- the bare `Makefile` / `GNUmakefile` names too (matched via the host's basename
-- fallback for files without an extension).
local DIRECTIVES = {}
for _, w in ipairs {
    "include", "sinclude", "define", "endef", "ifeq", "ifneq", "ifdef", "ifndef",
    "else", "endif", "export", "unexport", "override", "vpath", "undefine",
} do
    DIRECTIVES[w] = true
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
            local s, e
            if c == "#" then
                push(base + p - 1, base + len, t.comments); return
            end
            -- $(VAR) / ${VAR} / $@ $< $^ $* $? and $$
            s, e = line:find("^%$[%({][^%)}]*[%)}]", p)
            if not s then s, e = line:find("^%$[@<%^%*%?%+%$]", p) end
            if s then push(base + s - 1, base + e, t.variables); p = e + 1; goto continue end
            -- word: colour known directives as keywords, otherwise skip past it
            s, e = line:find("^[%a_][%w_%-]*", p)
            if s then
                if DIRECTIVES[line:sub(s, e)] then push(base + s - 1, base + e, t.keywords) end
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

        if line:match("^%s*#") then
            push(base, base + #line, t.comments)
            goto next_line
        end
        -- recipe line (tab-indented command): just scan for variables/comments
        if line:sub(1, 1) == "\t" then
            inline(line, base, 1)
            goto next_line
        end
        -- variable assignment: NAME =, :=, ?=, +=
        do
            local ks, ke = line:find("^%s*[%w_%.%-]+%s*[:%?%+]?=", 1)
            if ks then
                local name = line:match("^%s*([%w_%.%-]+)")
                local ns = line:find(name, 1, true)
                push(base + ns - 1, base + ns - 1 + #name, t.attributes)
                inline(line, base, ns + #name)
                goto next_line
            end
        end
        -- target: `name:` (but not `:=` assignment, handled above)
        do
            local ts, te = line:find("^[%w_%.%-/%$%(%){} ]+:", 1)
            if ts and line:sub(te + 1, te + 1) ~= "=" then
                push(base + ts - 1, base + te - 1, t.functions)
                push(base + te - 1, base + te, t.operators)
                inline(line, base, te + 1)
                goto next_line
            end
        end

        inline(line, base, 1)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "Makefile",
    extensions = { ".mk", ".mak", ".make", "Makefile", "makefile", "GNUmakefile" },
    highlight  = lex,
}
