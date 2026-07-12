local t = thor.theme

local function lex(src)
    local spans = {}

    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- Scans line[p..] (p is 1-based) for inline spans, appending them with the
    -- line's 0-based byte offset `base`. The cursor only advances, so spans stay
    -- ordered and non-overlapping. `^` anchors each pattern to the cursor.
    local function inline(line, base, p)
        local len = #line
        while p <= len do
            local s, e
            -- link / image: [text](url) or ![alt](url)
            s, e = line:find("^!?%[.-%]%(.-%)", p)
            if s then push(base + s - 1, base + e, t.links); p = e + 1; goto continue end
            -- inline code: `code`, ``co`de``
            s, e = line:find("^(`+).-%1", p)
            if s then push(base + s - 1, base + e, t.strings); p = e + 1; goto continue end
            -- bold: **text** or __text__
            s, e = line:find("^%*%*.-%*%*", p)
            if not s then s, e = line:find("^__.-__", p) end
            if s then push(base + s - 1, base + e, t.orange); p = e + 1; goto continue end
            -- strikethrough: ~~text~~
            s, e = line:find("^~~.-~~", p)
            if s then push(base + s - 1, base + e, t.gray); p = e + 1; goto continue end
            -- italic: *text* or _text_
            s, e = line:find("^%*.-%*", p)
            if not s then s, e = line:find("^_.-_", p) end
            if s then push(base + s - 1, base + e, t.attributes); p = e + 1; goto continue end

            p = p + 1
            ::continue::
        end
    end

    local in_fence = false
    local fence_char = nil

    local i = 1
    local n = #src
    while i <= n do
        local nl = src:find("\n", i, true)
        local stop = nl and (nl - 1) or n
        local line = src:sub(i, stop)
        local base = i - 1
        i = (nl or n) + 1

        -- Fenced code block delimiter: 3+ backticks or tildes, optional indent.
        local _, ticks = line:match("^(%s*)([`~]+)")
        if ticks and #ticks >= 3 then
            local ch = ticks:sub(1, 1)
            if in_fence then
                if ch == fence_char then in_fence = false end
            else
                in_fence = true
                fence_char = ch
            end
            push(base, base + #line, t.comments)
            goto next_line
        end
        if in_fence then
            push(base, base + #line, t.strings)
            goto next_line
        end

        -- ATX heading: leading # .. ######
        if line:match("^%s*#+%s") or line:match("^%s*#+$") then
            push(base, base + #line, t.keywords)
            goto next_line
        end

        do
            -- Horizontal rule or setext underline: a line of only -, *, _ or =.
            local body = line:gsub("%s", "")
            if #body >= 3 and (body:match("^%-+$") or body:match("^%*+$")
                or body:match("^_+$") or body:match("^=+$")) then
                push(base, base + #line, t.comments)
                goto next_line
            end
        end

        do
            -- Blockquote marker(s): dim the '>' run, then scan the quoted text.
            local q = line:match("^(%s*>+%s?)")
            if q then
                push(base, base + #q, t.comments)
                inline(line, base, #q + 1)
                goto next_line
            end
        end

        do
            -- List item marker: -, +, * or "1." / "1)". Color just the marker,
            -- then scan the item text for inline spans.
            local m = line:match("^(%s*[-+*]%s+)") or line:match("^(%s*%d+[.)]%s+)")
            if m then
                push(base, base + #m, t.operators)
                inline(line, base, #m + 1)
                goto next_line
            end
        end

        inline(line, base, 1)

        ::next_line::
    end

    return spans
end

thor.register_language {
    name       = "Markdown",
    extensions = { ".md", ".markdown", ".mdown", ".mkd", ".mkdn" },
    highlight  = lex,
}
