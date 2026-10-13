package markdown

import "core:strings"

@(private = "file")
CELL_PAD_X :: f32(10)

@(private = "file")
CELL_PAD_Y :: f32(4)

// True when a table starts at line `at`: a row of cells with a delimiter row of
// as many cells under it.
@(private)
table_at :: proc(b: ^Build, at: int) -> bool {
    if at + 1 >= len(b.lines) || !strings.contains_rune(b.lines[at], '|') {
        return false
    }
    aligns, ok := table_delimiter(b.lines[at + 1])
    return ok && len(aligns) == len(table_cells(b.lines[at]))
}

// Lays out the table that starts at line `at`. A column takes the width of its
// widest cell; when the table is wider than the page the columns share the page
// and their cells wrap. Returns the line after the table.
@(private)
emit_table :: proc(b: ^Build, at: int) -> int {
    aligns, _ := table_delimiter(b.lines[at + 1])
    cols := len(aligns)

    rows := make([dynamic][]string, context.temp_allocator)
    append(&rows, table_cells(b.lines[at])[:])
    next := at + 2
    for next < len(b.lines) {
        line := b.lines[next]
        if b.skip[next] || !strings.contains_rune(line, '|') || len(strings.trim_space(line)) == 0 {
            break
        }
        append(&rows, table_cells(line)[:])
        next += 1
    }

    // The tokens of each cell, row by row. A short row has empty cells. A
    // column is never narrower than the widest thing in it that cannot break.
    cells := make([][]Token, len(rows) * cols, context.temp_allocator)
    natural := make([]f32, cols, context.temp_allocator)
    least := make([]f32, cols, context.temp_allocator)
    for row, r in rows {
        for c in 0 ..< min(cols, len(row)) {
            tokens := inline(b, row[c], r == 0 ? b.pal.strong : b.pal.text)
            cells[r * cols + c] = tokens[:]
            whole, unit := run_width(b, tokens[:])
            natural[c] = max(natural[c], whole)
            least[c] = max(least[c], unit)
        }
    }

    // Too wide for the page: each column keeps its least width and the room
    // that is left is shared by what each one still wants.
    widths := natural
    total, floor := f32(0), f32(0)
    for w, c in natural {
        total += w
        floor += least[c]
    }
    room := b.avail - f32(cols) * CELL_PAD_X * 2
    if total > room {
        spare := max(0, room - floor)
        want := total - floor
        for &w, c in widths {
            w = least[c] + (want > 0 ? (w - least[c]) * spare / want : 0)
        }
    }
    table_w := f32(0)
    for w in widths {
        table_w += w + CELL_PAD_X * 2
    }

    y := b.y
    for r in 0 ..< len(rows) {
        height := line_height(b.m, b.base)
        for c in 0 ..< cols {
            height = max(height, wrap_run(b, cells[r * cols + c], 0, 0, widths[c], b.base, aligns[c], false))
        }
        if r == 0 {
            append(
                &b.page.items,
                Item{kind = .Rect, y = y, w = table_w, h = height + CELL_PAD_Y * 2, color = b.pal.code_bg},
            )
        }
        x := f32(0)
        for c in 0 ..< cols {
            if len(cells[r * cols + c]) > 0 {
                wrap_run(b, cells[r * cols + c], x + CELL_PAD_X, y + CELL_PAD_Y, widths[c], b.base, aligns[c])
            }
            x += widths[c] + CELL_PAD_X * 2
        }
        y += height + CELL_PAD_Y * 2
        append(&b.page.items, Item{kind = .Rect, y = y, w = table_w, h = r == 0 ? 2 : 1, color = b.pal.rule})
    }
    b.y = y + f32(b.base) * 0.6
    return next
}

// The width of a token run on one row, and of the widest part of it that a
// row cannot break.
@(private = "file")
run_width :: proc(b: ^Build, tokens: []Token) -> (whole, unit: f32) {
    space_w := measure(b.m, " ", b.base)
    current := f32(0)
    for tok, i in tokens {
        w := measure(b.m, tok.text, b.base)
        if i > 0 && !tok.glue {
            whole += space_w
            current = 0
        }
        whole += w
        current += w
        unit = max(unit, current)
    }
    return
}

// The cells of a table row, trimmed. The outer pipes are optional; an escaped
// pipe and a pipe in a code span stay in their cell. In the temp allocator.
@(private = "file")
table_cells :: proc(line: string) -> [dynamic]string {
    cells := make([dynamic]string, context.temp_allocator)
    s := strings.trim_space(line)
    if strings.has_prefix(s, "|") {
        s = s[1:]
    }
    if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") {
        s = s[:len(s) - 1]
    }
    start := 0
    code := false
    for i := 0; i < len(s); i += 1 {
        switch s[i] {
        case '\\':
            i += 1
        case '`':
            code = !code
        case '|':
            if !code {
                append(&cells, strings.trim_space(s[start:i]))
                start = i + 1
            }
        }
    }
    append(&cells, strings.trim_space(s[start:]))
    return cells
}

// The column alignments of a delimiter row (`|---|:-:|--:|`), in the temp
// allocator. False when the line is not one.
@(private = "file")
table_delimiter :: proc(line: string) -> (aligns: [dynamic]Align, ok: bool) {
    if !strings.contains_rune(line, '-') {
        return
    }
    aligns = make([dynamic]Align, context.temp_allocator)
    for cell in table_cells(line) {
        left := strings.has_prefix(cell, ":")
        right := strings.has_suffix(cell, ":") && len(cell) > 1
        dashes := cell[left ? 1 : 0:len(cell) - (right ? 1 : 0)]
        if len(dashes) == 0 {
            return nil, false
        }
        for i in 0 ..< len(dashes) {
            if dashes[i] != '-' {
                return nil, false
            }
        }
        switch {
        case left && right:
            append(&aligns, Align.Center)
        case right:
            append(&aligns, Align.Right)
        case:
            append(&aligns, Align.Left)
        }
    }
    return aligns, len(aligns) > 0
}
