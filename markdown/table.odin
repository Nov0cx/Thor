package markdown

import "core:strings"

@(private = "file")
CELL_PAD_X :: f32(10)

@(private = "file")
CELL_PAD_Y :: f32(4)

// True when a table starts at line `at`: a row of cells with a delimiter row of
// as many cells under it.
@(private)
table_at :: proc(lines: []string, at: int) -> bool {
    if at + 1 >= len(lines) || !strings.contains_rune(lines[at], '|') {
        return false
    }
    aligns, ok := table_delimiter(lines[at + 1])
    return ok && len(aligns) == len(table_cells(lines[at]))
}

// Lays out a table: its header row, its delimiter row, then its body rows, in
// the column [x, x + w). A column takes the width of its widest cell; when the
// table is wider than the column the columns share it and their cells wrap.
@(private)
emit_table :: proc(b: ^Build, lines: []string, x, w: f32) {
    aligns, _ := table_delimiter(lines[1])
    cols      := len(aligns)

    rows := make([dynamic][]string, context.temp_allocator)
    append(&rows, table_cells(lines[0])[:])
    for line in lines[2:] {
        append(&rows, table_cells(line)[:])
    }

    // The tokens of each cell, row by row. A short row has empty cells. A
    // column is never narrower than the widest thing in it that cannot break.
    cells   := make([][]Token, len(rows) * cols, context.temp_allocator)
    natural := make([]f32, cols, context.temp_allocator)
    least   := make([]f32, cols, context.temp_allocator)
    for row, r in rows {
        for c in 0 ..< min(cols, len(row)) {
            tokens := r == 0 ? inline(b, row[c], b.pal.strong, {.Bold}) : inline(b, row[c], b.pal.text)
            cells[r * cols + c] = tokens[:]
            whole, unit := run_width(b, tokens[:])
            natural[c] = max(natural[c], whole)
            least[c] = max(least[c], unit)
        }
    }

    // Too wide for the column: each column keeps its least width and the room
    // that is left is shared by what each one still wants.
    widths := natural
    total, floor := f32(0), f32(0)
    for cw, c in natural {
        total += cw
        floor += least[c]
    }
    room := w - f32(cols) * CELL_PAD_X * 2
    if total > room {
        spare := max(0, room - floor)
        want  := total - floor
        for &cw, c in widths {
            cw = least[c] + (want > 0 ? (cw - least[c]) * spare / want : 0)
        }
    }
    table_w := f32(0)
    for cw in widths {
        table_w += cw + CELL_PAD_X * 2
    }

    top   := b.y
    y     := b.y
    zebra := b.pal.code_bg
    zebra[3] /= 2
    for r in 0 ..< len(rows) {
        height := line_height(b.m, b.base)
        for c in 0 ..< cols {
            height = max(height, wrap_run(b, cells[r * cols + c], 0, 0, widths[c], b.base, aligns[c], false))
        }
        // The header and every second body row are shaded.
        if r == 0 || r % 2 == 0 {
            append(&b.page.items, Item{kind = .Rect, x = x, y = y, w = table_w, h = height + CELL_PAD_Y * 2, color = r == 0 ? b.pal.code_bg : zebra, src = -1})
        }
        cx := x
        for c in 0 ..< cols {
            if len(cells[r * cols + c]) > 0 {
                wrap_run(b, cells[r * cols + c], cx + CELL_PAD_X, y + CELL_PAD_Y, widths[c], b.base, aligns[c])
            }
            cx += widths[c] + CELL_PAD_X * 2
        }
        y += height + CELL_PAD_Y * 2
        append(&b.page.items, Item{kind = .Rect, x = x, y = y, w = table_w, h = r == 0 ? 2 : 1, color = b.pal.rule, src = -1})
    }
    // The outer edge: a rule on top and down each side.
    append(&b.page.items, Item{kind = .Rect, x = x, y = top, w = table_w, h = 1, color = b.pal.rule, src = -1})
    append(&b.page.items, Item{kind = .Rect, x = x, y = top, w = 1, h = y - top, color = b.pal.rule, src = -1})
    append(&b.page.items, Item{kind = .Rect, x = x + table_w - 1, y = top, w = 1, h = y - top, color = b.pal.rule, src = -1})
    b.y = y
}

// The width of a token run on one row, and of the widest part of it that a
// row cannot break.
@(private = "file")
run_width :: proc(b: ^Build, tokens: []Token) -> (whole, unit: f32) {
    space_w := measure(b.m, " ", b.base)
    current := f32(0)
    for tok, i in tokens {
        w := measure(b.m, tok.text, b.base, tok.style)
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
    s     := strings.trim_space(line)
    if strings.has_prefix(s, "|") {
        s = s[1:]
    }
    if strings.has_suffix(s, "|") && !strings.has_suffix(s, "\\|") {
        s = s[:len(s) - 1]
    }
    start := 0
    code  := false
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
        left   := strings.has_prefix(cell, ":")
        right  := strings.has_suffix(cell, ":") && len(cell) > 1
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
