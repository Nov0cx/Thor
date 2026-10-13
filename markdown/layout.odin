package markdown

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

@(private)
Build :: struct {
    page:  ^Page,
    pal:   Palette,
    m:     Metrics,
    base:  i32,
    avail: f32,
    y:     f32,
    lines: []string,
    skip:  []bool,             // a reference definition: not drawn
    refs:  map[string]string,  // lower-case label to url, which borrows the source
    lists: [dynamic]int,       // the indent of each open list level
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
CODE_PAD :: f32(8)

// Parses the source into the page's item list. Block detection is line-oriented;
// inline styling and word wrap happen per block. Every item text borrows from
// `source`, so the caller keeps that alive as long as the page.
layout :: proc(page: ^Page, source: string, avail: f32, base: i32, pal: Palette, m: Metrics) {
    page_clear(page)
    b := Build {
        page  = page,
        pal   = pal,
        m     = m,
        base  = base,
        avail = avail,
        y     = PAD_TOP,
        refs  = make(map[string]string, 0, context.temp_allocator),
        lists = make([dynamic]int, context.temp_allocator),
    }

    lines := make([dynamic]string, context.temp_allocator)
    it := source
    for line in strings.split_lines_iterator(&it) {
        append(&lines, line)
    }
    b.lines = lines[:]
    b.skip = make([]bool, len(lines), context.temp_allocator)
    collect_refs(&b)

    i := 0
    for i < len(lines) {
        trimmed := strings.trim_left_space(lines[i])
        if b.skip[i] {
            i += 1
            continue
        }

        // Blank line: paragraph spacing. A list stays open across it.
        if len(trimmed) == 0 {
            b.y += f32(base) * 0.5
            i += 1
            continue
        }

        marker, content, ordered, num, is_list := list_item(trimmed)
        is_list = is_list && !is_rule(trimmed)
        if !is_list {
            clear(&b.lists)
        }

        // Fenced code block: gather verbatim lines until the closing fence.
        if fence, count := fence_open(trimmed); count > 0 {
            start := i + 1
            end := start
            for end < len(lines) && !fence_close(lines[end], fence, count) {
                end += 1
            }
            emit_code_block(&b, lines[start:end])
            i = end < len(lines) ? end + 1 : end
            continue
        }

        if table_at(&b, i) {
            i = emit_table(&b, i)
            continue
        }

        // Horizontal rule: a line of only -, * or _, three or more.
        if is_rule(trimmed) {
            b.y += 6
            append(&page.items, Item{kind = .Rect, y = b.y, w = avail, h = 2, color = pal.rule})
            b.y += line_height(m, base)
            i += 1
            continue
        }

        if level, rest, ok := heading(trimmed); ok {
            tokens := inline(&b, rest, pal.heading)
            emit_heading(&b, level, tokens[:])
            i += 1
            continue
        }

        if trimmed[0] == '>' {
            i = emit_quote(&b, i)
            continue
        }

        if is_list {
            depth := list_depth(&b, indent_columns(lines[i]))
            tokens := make([dynamic]Token, context.temp_allocator)
            st := inline_begin(&b, &tokens)
            inline_line(&st, content, pal.text)
            i += 1
            // A plain line under an item continues it.
            for i < len(lines) && !starts_block(&b, i, true) {
                inline_line(&st, lines[i], pal.text)
                i += 1
            }
            emit_list_item(&b, depth, marker, ordered, num, tokens[:])
            continue
        }

        // Paragraph: consecutive plain lines fold into one wrapped block, so a
        // soft line break flows, which is what markdown means by it. A line of
        // `=` or `-` under it makes it a heading.
        end := i + 1
        for end < len(lines) && !starts_block(&b, end) && setext_level(lines[end]) == 0 {
            end += 1
        }
        level := end < len(lines) ? setext_level(lines[end]) : 0
        tokens := make([dynamic]Token, context.temp_allocator)
        st := inline_begin(&b, &tokens)
        for line in lines[i:end] {
            inline_line(&st, line, level > 0 ? pal.heading : pal.text)
        }
        if level > 0 {
            emit_heading(&b, level, tokens[:])
            i = end + 1
            continue
        }
        b.y += wrap_run(&b, tokens[:], 0, b.y, avail, base)
        b.y += f32(base) * 0.35
        i = end
    }

    page.content_height = b.y + PAD_BOTTOM
}

// Takes the `[label]: url` lines out of the flow. A fenced block is not read.
@(private = "file")
collect_refs :: proc(b: ^Build) {
    fence: u8
    count := 0
    for line, i in b.lines {
        trimmed := strings.trim_left_space(line)
        if count > 0 {
            if fence_close(line, fence, count) {
                count = 0
            }
            continue
        }
        if fence, count = fence_open(trimmed); count > 0 {
            continue
        }
        if label, url, ok := ref_definition(line); ok {
            key := ref_key(label)
            if !(key in b.refs) {
                b.refs[key] = url
            }
            b.skip[i] = true
        }
    }
}

// True when line `at` ends the paragraph or the list item above it.
@(private)
starts_block :: proc(b: ^Build, at: int, in_list := false) -> bool {
    t := strings.trim_left_space(b.lines[at])
    if len(t) == 0 || b.skip[at] || t[0] == '>' || is_rule(t) {
        return true
    }
    if _, count := fence_open(t); count > 0 {
        return true
    }
    if _, _, ok := heading(t); ok {
        return true
    }
    if table_at(b, at) {
        return true
    }
    // Only a list that starts at 1 interrupts running text.
    if _, _, ordered, num, ok := list_item(t); ok && (in_list || !ordered || num == 1) {
        return true
    }
    return false
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
emit_heading :: proc(b: ^Build, level: int, tokens: []Token) {
    size := heading_size(b.base, level)
    b.y += f32(b.base) * (level <= 2 ? 0.8 : 0.4)
    b.y += wrap_run(b, tokens, 0, b.y, b.avail, size)
    if level <= 2 {
        b.y += 4
        append(&b.page.items, Item{kind = .Rect, y = b.y, w = b.avail, h = 1, color = b.pal.rule})
        b.y += 6
    }
}

// Lays out the run of `>` lines that starts at `at` behind one bar. A bare `>`
// is a paragraph break inside it. Returns the line after the run.
@(private = "file")
emit_quote :: proc(b: ^Build, at: int) -> int {
    top := b.y
    tokens := make([dynamic]Token, context.temp_allocator)
    st := inline_begin(b, &tokens)
    i := at
    for i < len(b.lines) {
        trimmed := strings.trim_left_space(b.lines[i])
        if len(trimmed) == 0 || trimmed[0] != '>' {
            break
        }
        content := strings.trim_left_space(trimmed[1:])
        if content == "" && len(tokens) > 0 {
            b.y += wrap_run(b, tokens[:], 18, b.y, b.avail - 18, b.base)
            b.y += f32(b.base) * 0.35
            clear(&tokens)
        } else if content != "" {
            inline_line(&st, content, b.pal.quote)
        }
        i += 1
    }
    if len(tokens) > 0 || b.y == top {
        b.y += wrap_run(b, tokens[:], 18, b.y, b.avail - 18, b.base)
    }
    append(&b.page.items, Item{kind = .Rect, y = top, w = 3, h = b.y - top, color = b.pal.accent})
    return i
}

@(private)
is_rule :: proc(s: string) -> bool {
    if len(s) < 3 {
        return false
    }
    c := s[0]
    if c != '-' && c != '*' && c != '_' {
        return false
    }
    count := 0
    for i in 0 ..< len(s) {
        switch s[i] {
        case c:
            count += 1
        case ' ', '\t':
        // spacing between markers is allowed
        case:
            return false
        }
    }
    return count >= 3
}

// Splits an ATX heading `### Title` into its level and title text. A closing
// run of `#` is not part of the title.
@(private = "file")
heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
    n := 0
    for n < len(s) && s[n] == '#' {
        n += 1
    }
    if n == 0 || n > 6 || n >= len(s) || s[n] != ' ' {
        return 0, "", false
    }
    rest = strings.trim_space(s[n + 1:])
    end := len(rest)
    for end > 0 && rest[end - 1] == '#' {
        end -= 1
    }
    if end < len(rest) && (end == 0 || rest[end - 1] == ' ') {
        rest = strings.trim_space(rest[:end])
    }
    return n, rest, true
}

// The heading level a setext underline gives the paragraph above it: 1 for a
// line of `=`, 2 for a line of `-`, 0 for any other line.
@(private = "file")
setext_level :: proc(line: string) -> int {
    s := strings.trim_space(line)
    if len(s) < 2 || (s[0] != '=' && s[0] != '-') {
        return 0
    }
    for i in 1 ..< len(s) {
        if s[i] != s[0] {
            return 0
        }
    }
    return s[0] == '=' ? 1 : 2
}

// The fence character and length when `s` opens a fenced code block.
@(private)
fence_open :: proc(s: string) -> (fence: u8, count: int) {
    if len(s) < 3 || (s[0] != '`' && s[0] != '~') {
        return 0, 0
    }
    for count < len(s) && s[count] == s[0] {
        count += 1
    }
    if count < 3 {
        return 0, 0
    }
    return s[0], count
}

// True when `line` closes a fence of `count` `fence` characters.
@(private)
fence_close :: proc(line: string, fence: u8, count: int) -> bool {
    s := strings.trim_space(line)
    if len(s) < count {
        return false
    }
    for i in 0 ..< len(s) {
        if s[i] != fence {
            return false
        }
    }
    return true
}

// Recognizes a list marker at the head of a line, returning the display marker,
// the remaining content and, for an ordered item, the parsed number.
@(private = "file")
list_item :: proc(
    s: string,
) -> (
    marker: string,
    content: string,
    ordered: bool,
    num: int,
    ok: bool,
) {
    if len(s) >= 2 && (s[0] == '-' || s[0] == '*' || s[0] == '+') && s[1] == ' ' {
        return "•", strings.trim_left_space(s[2:]), false, 0, true
    }
    // Ordered: one or more digits, then '.' or ')', then a space.
    d := 0
    for d < len(s) && s[d] >= '0' && s[d] <= '9' {
        d += 1
    }
    if d > 0 && d + 1 < len(s) && (s[d] == '.' || s[d] == ')') && s[d + 1] == ' ' {
        value, _ := strconv.parse_int(s[:d])
        return "", strings.trim_left_space(s[d + 2:]), true, value, true
    }
    return "", "", false, 0, false
}

// The width of a line's leading white space, a tab counting four.
@(private = "file")
indent_columns :: proc(line: string) -> int {
    columns := 0
    for i in 0 ..< len(line) {
        switch line[i] {
        case ' ':
            columns += 1
        case '\t':
            columns += 4
        case:
            return columns
        }
    }
    return columns
}

// The nesting level of a list item indented `columns`: deeper than the open
// level opens one more, shallower closes down to the level it lines up with.
@(private = "file")
list_depth :: proc(b: ^Build, columns: int) -> int {
    for len(b.lists) > 0 && columns < b.lists[len(b.lists) - 1] {
        pop(&b.lists)
    }
    if len(b.lists) == 0 || columns >= b.lists[len(b.lists) - 1] + 2 {
        append(&b.lists, columns)
    }
    return len(b.lists) - 1
}

// Emits a bullet or number and its wrapped content, indented under the marker.
@(private = "file")
emit_list_item :: proc(b: ^Build, depth: int, marker: string, ordered: bool, num: int, tokens: []Token) {
    label := marker
    if ordered {
        s := fmt.aprintf("%d.", num)
        append(&b.page.owned, s)
        label = s
    }
    left := LIST_INDENT * f32(depth)
    append(
        &b.page.items,
        Item{kind = .Text, x = left + 6, y = b.y, text = label, size = b.base, color = b.pal.accent},
    )
    indent := left + LIST_INDENT
    b.y += wrap_run(b, tokens, indent, b.y, b.avail - indent, b.base)
}

// A background panel and each source line verbatim. A line wider than the panel
// continues on the next row.
@(private = "file")
emit_code_block :: proc(b: ^Build, lines: []string) {
    if len(lines) == 0 {
        return
    }
    line_h := line_height(b.m, b.base)
    max_w := b.avail - CODE_PAD * 2
    rows := make([dynamic]string, 0, len(lines), context.temp_allocator)
    for line in lines {
        rest := line
        for {
            n := fit(b, rest, max_w, b.base)
            append(&rows, rest[:n])
            rest = rest[n:]
            if len(rest) == 0 {
                break
            }
        }
    }

    top := b.y
    height := line_h * f32(len(rows)) + CODE_PAD * 2
    append(
        &b.page.items,
        Item{kind = .Rect, y = top, w = b.avail, h = height, color = b.pal.code_bg},
    )
    ty := top + CODE_PAD
    for row in rows {
        append(
            &b.page.items,
            Item{kind = .Text, x = CODE_PAD, y = ty, text = row, size = b.base, color = b.pal.code},
        )
        ty += line_h
    }
    b.y = top + height + f32(b.base) * 0.4
}

// How many bytes of `s` fit in `max_w`, cut at a rune and at least one rune.
@(private = "file")
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
    return ends[lo]
}

@(private = "file")
Placed :: struct {
    token: int,
    x:     f32,
    w:     f32,
}

// Lays a token run out in the column [x, x + max_w) from `y` down and returns
// the height it takes. A row breaks before a token that has a space before it;
// glued tokens stay on one row. With `emit` false nothing is added to the page.
@(private)
wrap_run :: proc(
    b: ^Build,
    tokens: []Token,
    x, y, max_w: f32,
    size: i32,
    align := Align.Left,
    emit := true,
) -> f32 {
    line_h := line_height(b.m, size)
    if len(tokens) == 0 {
        return line_h
    }
    space_w := measure(b.m, " ", size)
    row := make([dynamic]Placed, context.temp_allocator)
    row_w := f32(0)
    row_y := y

    i := 0
    for i < len(tokens) {
        last := i + 1
        for last < len(tokens) && tokens[last].glue && !tokens[last - 1].brk {
            last += 1
        }
        first := len(row)
        unit_w := f32(0)
        for k in i ..< last {
            w := measure(b.m, tokens[k].text, size)
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

// Adds one row of placed tokens to the page. A code token gets a chip, a link
// an underline right after its text, a struck token a line through it.
@(private = "file")
emit_row :: proc(
    b: ^Build,
    tokens: []Token,
    row: []Placed,
    x, y, max_w, row_w: f32,
    size: i32,
    align: Align,
) {
    line_h := line_height(b.m, size)
    left := x
    switch align {
    case .Left:
    case .Center:
        left += max(0, (max_w - row_w) * 0.5)
    case .Right:
        left += max(0, max_w - row_w)
    }
    for placed in row {
        tok := tokens[placed.token]
        tx := left + placed.x
        if tok.code {
            append(
                &b.page.items,
                Item{kind = .Rect, x = tx - 2, y = y, w = placed.w + 4, h = line_h, color = b.pal.code_bg},
            )
        }
        // A text item carries its whole box: the draw culls with it, and a link
        // is hit-tested against it.
        append(
            &b.page.items,
            Item {
                kind = .Text,
                x = tx,
                y = y,
                w = placed.w,
                h = line_h,
                text = tok.text,
                size = size,
                color = tok.color,
                url = tok.url,
            },
        )
        if tok.link {
            append(
                &b.page.items,
                Item{kind = .Rect, x = tx, y = y + line_h - 3, w = placed.w, h = 1, color = tok.color},
            )
        }
        if tok.strike {
            append(
                &b.page.items,
                Item{kind = .Rect, x = tx, y = y + line_h * 0.5, w = placed.w, h = 1, color = tok.color},
            )
        }
    }
}
