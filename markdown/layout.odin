package markdown

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

import ui "../vendor/loom/loom"

@(private)
Build :: struct {
    page:      ^Page,
    pal:       Palette,
    m:         Metrics,
    base:      i32,
    avail:     f32,
    y:         f32,
    source:    string,
    color:     ui.Color,          // the body text color of the container being laid out
    refs:      map[string]string, // lower-case label to url, which borrows the source
    footnotes: [dynamic]Footnote,
    slugs:     map[string]int, // how often each heading slug was taken
    details:   int,            // the `<details>` blocks laid out so far
}

@(private)
Align :: enum {
    Left,
    Center,
    Right,
}

@(private = "file")
LIST_INDENT :: f32(24)

@(private = "file")
QUOTE_INDENT :: f32(18)

@(private = "file")
CODE_PAD :: f32(8)

@(private = "file")
IMAGE_GAP :: f32(4)

@(private = "file")
BULLET :: f32(5)

@(private = "file")
CHECK_BOX :: f32(12)

@(private = "file")
TOGGLE_INDENT :: f32(18)

@(private = "file")
ALERT_TITLES := [Alert_Kind]string{.Note = "Note", .Tip = "Tip", .Important = "Important", .Warning = "Warning", .Caution = "Caution"}

// Parses the source into the page's item list: the blocks first, so a
// reference defined at the end resolves at the start, then each block laid out
// in the column it is nested in. Every item text borrows from `source` or the
// page, so the caller keeps the source alive as long as the page.
layout :: proc(page: ^Page, source: string, avail: f32, base: i32, pal: Palette, m: Metrics) {
    page_clear(page)
    b := Build{
        page = page,
        pal = pal,
        m = m,
        base = base,
        avail = avail,
        y = PAD_TOP,
        source = source,
        color = pal.text,
        refs = make(map[string]string, 0, context.temp_allocator),
        footnotes = make([dynamic]Footnote, context.temp_allocator),
        slugs = make(map[string]int, 0, context.temp_allocator),
    }

    lines := make([dynamic]string, context.temp_allocator)
    it    := source
    for line in strings.split_lines_iterator(&it) {
        append(&lines, line)
    }
    blocks := parse_blocks(&b, lines[:])
    layout_blocks(&b, blocks[:], 0, avail, false)
    emit_footnotes(&b)
    page.content_height = b.y + PAD_BOTTOM
}

// The byte offset of `s` in the source, or -1 when it is not a slice of it.
@(private)
src_of :: proc(b: ^Build, s: string) -> int {
    if len(s) == 0 || len(b.source) == 0 {
        return -1
    }
    at := int(uintptr(raw_data(s))) - int(uintptr(raw_data(b.source)))
    return at >= 0 && at + len(s) <= len(b.source) ? at : -1
}

// The space between two blocks of one container.
@(private = "file")
block_gap :: proc(b: ^Build, tight: bool) -> f32 {
    return f32(b.base) * (tight ? 0.2 : 0.8)
}

@(private = "file")
layout_blocks :: proc(b: ^Build, blocks: []^Block, x, w: f32, tight: bool) {
    for blk, i in blocks {
        if i > 0 {
            b.y += block_gap(b, tight)
        }
        layout_block(b, blk, x, w, tight)
    }
}

@(private = "file")
layout_block :: proc(b: ^Build, blk: ^Block, x, w: f32, tight: bool) {
    switch blk.kind {
    case .Paragraph:
        tokens := make([dynamic]Token, context.temp_allocator)
        st     := inline_begin(b, &tokens)
        for line in blk.lines {
            inline_line(&st, line, b.color)
        }
        b.y += wrap_run(b, tokens[:], x, b.y, w, b.base)
    case .Heading:
        emit_heading(b, blk, x, w)
    case .Rule:
        b.y += 6
        append(&b.page.items, Item{kind = .Rect, x = x, y = b.y, w = w, h = 2, color = b.pal.rule, src = -1})
        b.y += 8
    case .Code:
        emit_code_block(b, blk, x, w)
    case .Table:
        emit_table(b, blk.lines, x, w)
    case .Quote, .Alert:
        emit_quote(b, blk, x, w)
    case .List:
        emit_list(b, blk, x, w)
    case .Item:
        layout_blocks(b, blk.children[:], x, w, tight)
    case .Details:
        emit_details(b, blk, x, w)
    }
}

// Font size for a heading level (1..6), stepping down toward the body size.
@(private = "file")
heading_size :: proc(base: i32, level: int) -> i32 {
    switch level {
    case 1:
        return base + 13
    case 2:
        return base + 8
    case 3:
        return base + 5
    case 4:
        return base + 3
    case 5:
        return base + 1
    }
    return base
}

@(private = "file")
emit_heading :: proc(b: ^Build, blk: ^Block, x, w: f32) {
    level := blk.level
    size  := heading_size(b.base, level)
    b.y += f32(b.base) * (level <= 2 ? 0.6 : 0.3)

    anchor := heading_slug(b, blk.lines)
    if anchor != "" && !(anchor in b.page.anchors) {
        b.page.anchors[strings.clone(anchor)] = b.y
    }

    tokens := make([dynamic]Token, context.temp_allocator)
    st     := inline_begin(b, &tokens)
    for line in blk.lines {
        inline_line(&st, line, b.pal.heading, {.Bold})
    }
    b.y += wrap_run(b, tokens[:], x, b.y, w, size)
    if level <= 2 {
        b.y += 4
        append(&b.page.items, Item{kind = .Rect, x = x, y = b.y, w = w, h = 1, color = b.pal.rule, src = -1})
        b.y += 4
    }
}

// The anchor GitHub gives a heading: its text in lower case, punctuation
// dropped, spaces as `-`, and `-1`, `-2`, ... on a repeat. In the temp allocator.
@(private)
heading_slug :: proc(b: ^Build, lines: []string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    for line, n in lines {
        if n > 0 {
            strings.write_byte(&sb, '-')
        }
        i := 0
        for i < len(line) {
            c := line[i]
            // A link's target is not part of its text.
            if c == ']' && i + 1 < len(line) && line[i + 1] == '(' {
                if close := strings.index_byte(line[i:], ')'); close > 0 {
                    i += close + 1
                    continue
                }
            }
            switch {
            case c >= 'A' && c <= 'Z':
                strings.write_byte(&sb, c + ('a' - 'A'))
            case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c >= 0x80:
                strings.write_byte(&sb, c)
            case c == ' ' || c == '\t':
                strings.write_byte(&sb, '-')
            }
            i += 1
        }
    }
    slug := strings.to_string(sb)
    seen := b.slugs[slug]
    b.slugs[slug] = seen + 1
    if seen > 0 {
        return fmt.tprintf("%s-%d", slug, seen)
    }
    return slug
}

// A quote or an alert: its blocks behind one bar, in the quote color. An alert
// takes its kind's color and title.
@(private = "file")
emit_quote :: proc(b: ^Build, blk: ^Block, x, w: f32) {
    top   := b.y
    bar   := b.pal.accent
    saved := b.color
    b.color = b.pal.quote
    if blk.kind == .Alert {
        bar = b.pal.alert[blk.alert]
        b.color = b.pal.text
        title := ALERT_TITLES[blk.alert]
        tw    := measure(b.m, title, b.base, {.Bold})
        h     := line_height(b.m, b.base)
        append(
            &b.page.items,
            Item{kind = .Text, x = x + QUOTE_INDENT, y = b.y, w = tw, h = h, text = title, size = b.base, color = bar, style = {.Bold}, src = -1},
        )
        b.y += h + f32(b.base) * 0.2
    }
    if len(blk.children) > 0 {
        layout_blocks(b, blk.children[:], x + QUOTE_INDENT, w - QUOTE_INDENT, false)
    } else if b.y == top {
        b.y += line_height(b.m, b.base)
    }
    b.color = saved
    append(&b.page.items, Item{kind = .Rect, x = x, y = top, w = 3, h = b.y - top, color = bar, src = -1})
}

// Each item's marker at the list's left edge and its blocks indented under it.
@(private = "file")
emit_list :: proc(b: ^Build, blk: ^Block, x, w: f32) {
    tight := !blk.loose
    for item, n in blk.children {
        if n > 0 {
            b.y += block_gap(b, tight)
        }
        top := b.y
        emit_marker(b, blk, item, n, x)
        if len(item.children) > 0 {
            layout_blocks(b, item.children[:], x + LIST_INDENT, w - LIST_INDENT, tight)
        } else {
            b.y += line_height(b.m, b.base)
        }
        b.y = max(b.y, top + line_height(b.m, b.base))
    }
}

// A number, a bullet or a task box at the head of item `n`.
@(private = "file")
emit_marker :: proc(b: ^Build, list, item: ^Block, n: int, x: f32) {
    line_h := line_height(b.m, b.base)
    mid    := b.y + line_h * 0.5
    if item.task != .None {
        box := Item{kind = .Rect, x = x + 6, y = mid - CHECK_BOX * 0.5, w = CHECK_BOX, h = CHECK_BOX, src = -1}
        if item.task == .Done {
            box.color = b.pal.accent
            append(&b.page.items, box)
            check := "✓"
            cw    := measure(b.m, check, b.base - 3)
            append(
                &b.page.items,
                Item{
                    kind = .Text,
                    x = box.x + (CHECK_BOX - cw) * 0.5,
                    y = mid - line_height(b.m, b.base - 3) * 0.5,
                    w = cw,
                    h = line_height(b.m, b.base - 3),
                    text = check,
                    size = b.base - 3,
                    color = b.pal.code_bg,
                    style = {.Bold},
                    src = -1,
                },
            )
            return
        }
        box.color = b.pal.rule
        append(&b.page.items, box)
        inner := box
        inner.x += 1
        inner.y += 1
        inner.w -= 2
        inner.h -= 2
        inner.color = b.pal.code_bg
        append(&b.page.items, inner)
        return
    }
    if list.ordered {
        label := fmt.aprintf("%d.", list.start + n)
        append(&b.page.owned, label)
        // Right-aligned, so a number of two digits ends where one of one does.
        lw := measure(b.m, label, b.base)
        append(
            &b.page.items,
            Item{kind = .Text, x = x + max(0, LIST_INDENT - 6 - lw), y = b.y, w = lw, h = line_h, text = label, size = b.base, color = b.pal.accent, src = -1},
        )
        return
    }
    // A square, not a glyph: the bullet character is not in every face.
    append(&b.page.items, Item{kind = .Rect, x = x + 8, y = mid - BULLET * 0.5, w = BULLET, h = BULLET, color = b.pal.accent, src = -1})
}

// A `<details>` block: its summary row is the toggle, and its blocks show
// only while the reader has it open.
@(private = "file")
emit_details :: proc(b: ^Build, blk: ^Block, x, w: f32) {
    ref := b.details
    b.details += 1
    open   := b.page.open[ref]
    line_h := line_height(b.m, b.base)
    top    := b.y
    tokens := inline(b, blk.summary, b.color)
    h      := wrap_run(b, tokens[:], x + TOGGLE_INDENT, b.y, w - TOGGLE_INDENT, b.base)
    append(&b.page.items, Item{kind = .Toggle, x = x, y = top, w = w, h = max(h, line_h), size = open ? 1 : 0, ref = ref, color = b.pal.accent, src = -1})
    b.y += h
    if open && len(blk.children) > 0 {
        b.y += block_gap(b, false)
        layout_blocks(b, blk.children[:], x + TOGGLE_INDENT, w - TOGGLE_INDENT, false)
    }
}

// The footnote definitions under a rule, each anchored at `^label`.
@(private = "file")
emit_footnotes :: proc(b: ^Build) {
    if len(b.footnotes) == 0 {
        return
    }
    size := max(b.base - 2, 8)
    b.y += f32(b.base)
    append(&b.page.items, Item{kind = .Rect, y = b.y, w = b.avail, h = 1, color = b.pal.rule, src = -1})
    b.y += f32(b.base) * 0.5
    for note, n in b.footnotes {
        if n > 0 {
            b.y += f32(b.base) * 0.2
        }
        key := strings.concatenate({"^", note.label})
        if key in b.page.anchors {
            delete(key)
        } else {
            b.page.anchors[key] = b.y
        }
        append(
            &b.page.items,
            Item{
                kind = .Text,
                y = b.y,
                w = measure(b.m, note.label, size),
                h = line_height(b.m, size),
                text = note.label,
                size = size,
                color = b.pal.accent,
                src = src_of(b, note.label),
            },
        )
        tokens := make([dynamic]Token, context.temp_allocator)
        st     := inline_begin(b, &tokens)
        for line in note.lines {
            inline_line(&st, line, b.pal.quote)
        }
        b.y += wrap_run(b, tokens[:], LIST_INDENT, b.y, b.avail - LIST_INDENT, size)
    }
}

// A code block: a panel, each source line verbatim and colored by the host's
// highlighter, and the copy area over the whole panel. A line wider than the
// panel continues on the next row.
@(private = "file")
emit_code_block :: proc(b: ^Build, blk: ^Block, x, w: f32) {
    if len(blk.lines) == 0 {
        return
    }
    code := strings.join(blk.lines, "\n")
    append(&b.page.owned, code)
    spans: []Color_Span
    if b.m.highlight != nil && blk.lang != "" {
        spans = b.m.highlight(blk.lang, code, b.m.user)
    }

    Row :: struct {
        text: string,
        at:   int, // the offset of `text` in `code`
    }
    line_h := line_height(b.m, b.base)
    max_w  := w - CODE_PAD * 2
    rows   := make([dynamic]Row, 0, len(blk.lines), context.temp_allocator)
    at     := 0
    for line in blk.lines {
        rest   := line
        offset := at
        for {
            n := fit(b, rest, max_w, b.base)
            append(&rows, Row{text = rest[:n], at = offset})
            rest = rest[n:]
            offset += n
            if len(rest) == 0 {
                break
            }
        }
        at += len(line) + 1
    }

    top    := b.y
    height := line_h * f32(len(rows)) + CODE_PAD * 2
    append(&b.page.items, Item{kind = .Rect, x = x, y = top, w = w, h = height, color = b.pal.code_bg, src = -1})
    ty   := top + CODE_PAD
    next := 0
    for row in rows {
        emit_code_row(b, row.text, row.at, spans, &next, x + CODE_PAD, ty, line_h)
        ty += line_h
    }
    append(&b.page.items, Item{kind = .Copy, x = x, y = top, w = w, h = height, text = code, url = blk.lang, size = b.base, color = b.pal.quote, src = -1})
    b.y = top + height
}

// One row of a code block, cut where the highlight spans change color. `next`
// is the first span that may still reach this row, so the walk is forward only.
@(private = "file")
emit_code_row :: proc(b: ^Build, text: string, at: int, spans: []Color_Span, next: ^int, x, y, line_h: f32) {
    if len(text) == 0 {
        return
    }
    end := at + len(text)
    for next^ < len(spans) && spans[next^].end <= at {
        next^ += 1
    }
    pos := at
    pen := x
    piece :: proc(b: ^Build, text: string, color: ui.Color, pen: ^f32, y, line_h: f32) {
        if len(text) == 0 {
            return
        }
        w := measure(b.m, text, b.base)
        append(&b.page.items, Item{kind = .Text, x = pen^, y = y, w = w, h = line_h, text = text, size = b.base, color = color, src = src_of(b, text)})
        pen^ += w
    }
    for k := next^; k < len(spans) && spans[k].start < end; k += 1 {
        span := spans[k]
        lo   := clamp(span.start, pos, end)
        hi   := clamp(span.end, pos, end)
        if lo >= hi {
            continue
        }
        piece(b, text[pos - at:lo - at], b.pal.code, &pen, y, line_h)
        piece(b, text[lo - at:hi - at], span.color, &pen, y, line_h)
        pos = hi
    }
    piece(b, text[pos - at:], b.pal.code, &pen, y, line_h)
}

// How many bytes of `s` fit in `max_w`: cut at a rune, after a space when one
// is near, and at least one rune.
@(private)
fit :: proc(b: ^Build, s: string, max_w: f32, size: i32) -> int {
    if len(s) == 0 || measure(b.m, s, size) <= max_w {
        return len(s)
    }
    ends := make([dynamic]int, 0, len(s), context.temp_allocator)
    for i := 0; i < len(s); {
        _, width := utf8.decode_rune_in_string(s[i:])
        i += width
        append(&ends, i)
    }
    // The widest prefix that fits, by bisection over the rune ends.
    lo, hi := 0, len(ends) - 1
    for lo < hi {
        mid := (lo + hi + 1) / 2
        if measure(b.m, s[:ends[mid]], size) <= max_w {
            lo = mid
        } else {
            hi = mid - 1
        }
    }
    // A space in the later half of the row is a better place to cut.
    n := ends[lo]
    if space := strings.last_index_byte(s[:n], ' '); space + 1 < n && space > n / 2 {
        n = space + 1
    }
    return n
}

@(private = "file")
Placed :: struct {
    token: int,
    x:     f32,
    w:     f32,
}

// The width a token takes on a row: a key cap has room on each side.
@(private = "file")
token_width :: proc(b: ^Build, tok: Token, size: i32) -> f32 {
    w := measure(b.m, tok.text, size, tok.style)
    if tok.kbd {
        w += 8
    }
    return w
}

// Lays a token run out in the column [x, x + max_w) from `y` down and returns
// the height it takes. A row breaks before a token that has a space before it;
// glued tokens stay on one row. With `emit` false nothing is added to the page.
@(private)
wrap_run :: proc(b: ^Build, tokens: []Token, x, y, max_w: f32, size: i32, align := Align.Left, emit := true) -> f32 {
    line_h := line_height(b.m, size)
    if len(tokens) == 0 {
        return line_h
    }
    space_w := measure(b.m, " ", size)
    row     := make([dynamic]Placed, context.temp_allocator)
    row_w   := f32(0)
    row_y   := y

    i := 0
    for i < len(tokens) {
        // An image takes a row of its own, scaled down to the column.
        if tok := tokens[i]; tok.image {
            if len(row) > 0 {
                if emit {
                    emit_row(b, tokens, row[:], x, row_y, max_w, row_w, size, align)
                }
                clear(&row)
                row_y += line_h
                row_w = 0
            }
            scale := min(1, max_w / tok.size.x)
            w, h := tok.size.x * scale, tok.size.y * scale
            if emit {
                left := x
                switch align {
                case .Left:
                case .Center:
                    left += (max_w - w) * 0.5
                case .Right:
                    left += max_w - w
                }
                append(&b.page.items, Item{kind = .Image, x = left, y = row_y, w = w, h = h, text = tok.text, url = tok.url, src = -1})
            }
            row_y += h + IMAGE_GAP
            i += 1
            continue
        }

        last := i + 1
        for last < len(tokens) && tokens[last].glue && !tokens[last - 1].brk && !tokens[last].image {
            last += 1
        }
        first  := len(row)
        unit_w := f32(0)
        for k in i ..< last {
            w := token_width(b, tokens[k], size)
            append(&row, Placed{token = k, x = unit_w, w = w})
            unit_w += w
        }
        gap := first > 0 ? space_w : 0
        if first > 0 && row_w + gap + unit_w > max_w {
            if emit {
                emit_row(b, tokens, row[:first], x, row_y, max_w, row_w, size, align)
            }
            remove_range(&row, 0, first)
            row_y += line_h
            row_w = 0
            gap = 0
        }
        for &placed in row[len(row) - (last - i):] {
            placed.x += row_w + gap
        }
        row_w += gap + unit_w

        if tokens[last - 1].brk {
            if emit {
                emit_row(b, tokens, row[:], x, row_y, max_w, row_w, size, align)
            }
            clear(&row)
            row_y += line_h
            row_w = 0
        }
        i = last
    }
    if len(row) > 0 {
        if emit {
            emit_row(b, tokens, row[:], x, row_y, max_w, row_w, size, align)
        }
        row_y += line_h
    }
    return row_y - y
}

// Adds one row of placed tokens to the page. A code token gets a chip, a key
// cap a chip with a rule under it, a link an underline right after its text, a
// struck token a line through it.
@(private = "file")
emit_row :: proc(b: ^Build, tokens: []Token, row: []Placed, x, y, max_w, row_w: f32, size: i32, align: Align) {
    line_h := line_height(b.m, size)
    left   := x
    switch align {
    case .Left:
    case .Center:
        left += max(0, (max_w - row_w) * 0.5)
    case .Right:
        left += max(0, max_w - row_w)
    }
    for placed, n in row {
        tok   := tokens[placed.token]
        tx    := left + placed.x
        tw    := placed.w
        // A link's underline runs on under the space to the next word of it.
        under := tw
        if tok.link && n + 1 < len(row) && tokens[row[n + 1].token].url == tok.url {
            under = row[n + 1].x - placed.x
        }
        if tok.code {
            append(&b.page.items, Item{kind = .Rect, x = tx - 2, y = y, w = tw + 4, h = line_h, color = b.pal.code_bg, src = -1})
        }
        if tok.kbd {
            append(&b.page.items, Item{kind = .Rect, x = tx, y = y + 1, w = tw, h = line_h - 2, color = b.pal.code_bg, src = -1})
            append(&b.page.items, Item{kind = .Rect, x = tx, y = y + line_h - 2, w = tw, h = 1, color = b.pal.rule, src = -1})
            tx += 4
            tw -= 8
        }
        // A text item carries its whole box: the draw culls with it, and a link
        // is hit-tested against it.
        append(
            &b.page.items,
            Item{
                kind = .Text,
                x = tx,
                y = y,
                w = tw,
                h = line_h,
                text = tok.text,
                size = size,
                color = tok.color,
                url = tok.url,
                style = tok.style,
                src = src_of(b, tok.text),
            },
        )
        if tok.link {
            append(&b.page.items, Item{kind = .Rect, x = tx, y = y + line_h - 3, w = max(tw, under), h = 1, color = tok.color, src = -1})
        }
        if tok.strike {
            append(&b.page.items, Item{kind = .Rect, x = tx, y = y + line_h * 0.5, w = tw, h = 1, color = tok.color, src = -1})
        }
    }
}
