local t = thor.theme

local function lex(src)
    local spans = {}

    -- s and e are 0-based byte offsets into the source, e exclusive.
    local function push(s, e, role)
        if e > s then
            spans[#spans + 1] = { s, e, role }
        end
    end

    -- True when `_` at p is a delimiter and not part of an identifier: the `_`
    -- of pending_jobs must not open emphasis that runs to the next word.
    local function word_edge(region, p)
        return p == 1 or region:sub(p - 1, p - 1):match("[%s%p]") ~= nil
    end

    local inline

    -- Colors region[s..e] (1-based, inclusive) with `role` and scans between the
    -- two `marker`-byte delimiters, so `code` inside **bold** keeps its own color.
    local function emphasis(region, base, s, e, marker, role)
        push(base + s - 1, base + s - 1 + marker, role)
        inline(region:sub(s + marker, e - marker), base + s + marker - 1, role)
        push(base + e - marker, base + e, role)
    end

    -- Scans one region -- a paragraph, or the text of a list item or a quote --
    -- for inline spans. `base` is the region's 0-based offset in the source. A
    -- region is not one line: emphasis holds over a soft line break. The cursor
    -- only advances, so spans stay ordered and non-overlapping. `^` anchors each
    -- pattern to the cursor. Text no span covers takes `default`, which is nil
    -- outside emphasis and the emphasis role inside one.
    inline = function(region, base, default)
        local len = #region
        local p, gap = 1, 1
        -- Colors the uncovered run that ends before `upto` (1-based, exclusive).
        local function fill(upto)
            if default then
                push(base + gap - 1, base + upto - 1, default)
            end
            gap = upto
        end
        while p <= len do
            local s, e
            -- link / image: [text](url) or ![alt](url)
            s, e = region:find("^!?%[.-%]%(.-%)", p)
            if s then
                fill(s)
                push(base + s - 1, base + e, t.links)
                p = e + 1
                gap = p
                goto continue
            end
            -- inline code: `code`, ``co`de``
            s, e = region:find("^(`+).-%1", p)
            if s then
                fill(s)
                push(base + s - 1, base + e, t.strings)
                p = e + 1
                gap = p
                goto continue
            end
            -- bold: **text** or __text__. The first byte of the text rules out
            -- the empty match that made a lone ** read as italics.
            s, e = region:find("^%*%*[^%s%*].-%*%*", p)
            if not s and word_edge(region, p) then
                s, e = region:find("^__[^%s_].-__", p)
            end
            if s then
                fill(s)
                emphasis(region, base, s, e, 2, t.conflict)
                p = e + 1
                gap = p
                goto continue
            end
            -- strikethrough: ~~text~~
            s, e = region:find("^~~[^%s].-~~", p)
            if s then
                fill(s)
                emphasis(region, base, s, e, 2, t.muted)
                p = e + 1
                gap = p
                goto continue
            end
            -- italic: *text* or _text_
            s, e = region:find("^%*[^%s%*].-%*", p)
            if not s and word_edge(region, p) then
                s, e = region:find("^_[^%s_].-_", p)
            end
            if s then
                fill(s)
                emphasis(region, base, s, e, 1, t.attributes)
                p = e + 1
                gap = p
                goto continue
            end

            p = p + 1
            ::continue::
        end
        fill(len + 1)
    end

    local in_fence = false
    local fence_char = nil
    -- The paragraph waiting to be scanned, as a 0-based [start, stop) range. A
    -- list item's text and the lines that continue it are one range.
    local para_start, para_stop = nil, nil

    local function flush()
        if para_start then
            inline(src:sub(para_start + 1, para_stop), para_start, nil)
            para_start, para_stop = nil, nil
        end
    end

    local function extend(s, e)
        if not para_start then para_start = s end
        para_stop = e
    end

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
            flush()
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

        -- A blank line ends the paragraph.
        if line:match("^%s*$") then
            flush()
            goto next_line
        end

        -- ATX heading: leading # .. ######
        if line:match("^%s*#+%s") or line:match("^%s*#+$") then
            flush()
            push(base, base + #line, t.keywords)
            goto next_line
        end

        do
            -- Horizontal rule or setext underline: a line of only -, *, _ or =.
            local body = line:gsub("%s", "")
            if #body >= 3 and (body:match("^%-+$") or body:match("^%*+$")
                or body:match("^_+$") or body:match("^=+$")) then
                flush()
                push(base, base + #line, t.comments)
                goto next_line
            end
        end

        do
            -- Blockquote marker(s): dim the '>' run, then scan the quoted text.
            local q = line:match("^(%s*>+%s?)")
            if q then
                flush()
                push(base, base + #q, t.comments)
                extend(base + #q, base + #line)
                goto next_line
            end
        end

        do
            -- List item marker: -, +, * or "1." / "1)". Color just the marker,
            -- then scan the item text with the lines that continue it.
            local m = line:match("^(%s*[-+*]%s+)") or line:match("^(%s*%d+[.)]%s+)")
            if m then
                flush()
                push(base, base + #m, t.operators)
                extend(base + #m, base + #line)
                goto next_line
            end
        end

        extend(base, base + #line)

        ::next_line::
    end
    flush()

    return spans
end

thor.register_language {
    name       = "Markdown",
    extensions = { ".md", ".markdown", ".mdown", ".mkd", ".mkdn" },
    highlight  = lex,
}
