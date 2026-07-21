local t = thor.theme

-- HTML has no compiled grammar, so this is a pure-Lua lexer using the same
-- tag/attribute model as the XML plugin: tag names as tags, attribute names as
-- attributes, quoted values as strings, <!-- --> comments across lines, and
-- &entities highlighted. Embedded <script>/<style> bodies are left as plain
-- text. The cursor only advances, so spans stay ordered and non-overlapping.
local function lex(src)
    local spans = {}
    local n = #src

    local function emit(a, b, role)
        if b >= a then
            spans[#spans + 1] = { a - 1, b, role }
        end
    end

    -- Colors a tag starting at the '<' at position i and returns the index just
    -- past it. `<!DOCTYPE ...>` arrives here through the '!' lead.
    local function scan_tag(i)
        emit(i, i, t.operators)
        local j = i + 1
        local name_role = t.tags
        local lead = src:sub(j, j)
        if lead == "/" then
            emit(j, j, t.operators); j = j + 1
        elseif lead == "!" or lead == "?" then
            emit(j, j, t.operators); j = j + 1; name_role = t.keywords
        end
        local s, e = src:find("^[%w_:%-%.]+", j)
        if s then emit(s, e, name_role); j = e + 1 end

        while j <= n do
            local c = src:sub(j, j)
            if c == ">" then
                emit(j, j, t.operators); return j + 1
            elseif (c == "/" or c == "?") and src:sub(j + 1, j + 1) == ">" then
                emit(j, j + 1, t.operators); return j + 2
            elseif c:match("%s") then
                j = j + 1
            elseif c == '"' or c == "'" then
                local q = src:find(c, j + 1, true)
                local last = q or n
                emit(j, last, t.strings)
                j = last + 1
            elseif c == "=" then
                emit(j, j, t.operators); j = j + 1
            else
                local as, ae = src:find("^[%w_:%-%.]+", j)
                if as then emit(as, ae, t.attributes); j = ae + 1 else j = j + 1 end
            end
        end
        return j
    end

    local i = 1
    while i <= n do
        if src:sub(i, i + 3) == "<!--" then
            local e = src:find("-->", i + 4, true)
            local last = e and (e + 2) or n
            emit(i, last, t.comments)
            i = last + 1
        elseif src:sub(i, i) == "<" then
            i = scan_tag(i)
        elseif src:sub(i, i) == "&" then
            local s, e = src:find("^&[#%w]+;", i)
            if s then emit(s, e, t.orange); i = e + 1 else i = i + 1 end
        else
            i = i + 1
        end
    end

    return spans
end

thor.register_language {
    name       = "HTML",
    extensions = { ".html", ".htm", ".xhtml" },
    highlight  = lex,
}
