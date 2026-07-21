local t = thor.theme

-- Dockerfile pure-Lua lexer. Line based: # comments, the leading instruction
-- (FROM/RUN/COPY/...) as a keyword, `AS`/`ENV`-style continuation words, quoted
-- strings, ${VAR} / $VAR references and numbers. Registers the bare `Dockerfile`
-- name too (matched via the host's basename fallback for extensionless files).
local INSTRUCTIONS = {}
for _, w in ipairs {
    "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
    "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
    "HEALTHCHECK", "SHELL",
} do
    INSTRUCTIONS[w] = true
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
            elseif c == '"' or c == "'" then
                s, e = line:find("^" .. c .. "[^" .. c .. "]*" .. c, p)
                if not s then s, e = line:find("^" .. c .. ".*$", p) end
                push(base + s - 1, base + e, t.strings); p = e + 1
            elseif c == "$" then
                s, e = line:find("^%${[^}]*}", p)
                if not s then s, e = line:find("^%$[%a_][%w_]*", p) end
                if s then push(base + s - 1, base + e, t.variables); p = e + 1 else p = p + 1 end
            else
                s, e = line:find("^[%a][%w_]*", p)
                if s then
                    if line:sub(s, e) == "AS" or line:sub(s, e) == "as" then
                        push(base + s - 1, base + e, t.keywords)
                    end
                    p = e + 1
                else
                    s, e = line:find("^%d+", p)
                    if s then push(base + s - 1, base + e, t.numbers); p = e + 1 else p = p + 1 end
                end
            end
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
        -- leading instruction keyword
        do
            local s, e = line:find("^%s*[%a]+", 1)
            if s and INSTRUCTIONS[line:sub(s, e):upper()] then
                push(base + s - 1, base + e, t.keywords)
                inline(line, base, e + 1)
                goto next_line
            end
        end

        inline(line, base, 1)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "Dockerfile",
    extensions = { ".dockerfile", "Dockerfile", "dockerfile", "Containerfile" },
    highlight  = lex,
}
