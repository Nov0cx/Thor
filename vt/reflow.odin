// Reflow: a width change on the primary screen joins the rows a wrap split and
// wraps them again at the new width, the scrollback included.
package vt

// A place in a logical line to find again after the rewrap: the cursor, the
// saved cursor, the old top row of the screen.
@(private = "file")
Mark :: struct {
    line:    int, // the logical line, counted from the oldest history line
    offset:  int, // cells into it
    set:     bool,
    // Where it landed: an index into the new rows, the column, and whether it
    // sits past the last column.
    row:     int,
    col:     int,
    pending: bool,
}

@(private = "file")
MARK_CURSOR :: 0
@(private = "file")
MARK_SAVED :: 1
@(private = "file")
MARK_TOP :: 2

// Rewraps the scrollback and the primary screen at `cols` and gives the screen
// `rows` rows. The top screen row keeps its place unless the cursor would fall
// off the bottom, so the screen moves down only as far as the cursor needs.
@(private)
reflow_primary :: proc(t: ^Term, cols, rows: int) {
    context.allocator = t.allocator
    marks: [3]Mark
    if !t.alt_active {
        marks[MARK_CURSOR] = {offset = t.cur.x + (t.cur.pending_wrap ? 1 : 0), set = true}
    }
    marks[MARK_SAVED] = {offset = t.saved.cur.x + (t.saved.cur.pending_wrap ? 1 : 0), set = true}
    marks[MARK_TOP] = {set = true}

    // The physical rows, oldest first, and the screen row each mark sits on.
    history   := len(t.scrollback)
    total     := history + len(t.primary)
    mark_rows := [3]int{history + t.cur.y, history + t.saved.cur.y, history}

    out     := make([dynamic]Line)
    logical := make([dynamic]Cell, context.temp_allocator)
    line_no := 0
    wrapped := false
    for i in 0 ..< total {
        src := i < history ? &t.scrollback[(t.scrollback_head + i) % history] : &t.primary[i - history]
        // A line on its own that fits the new width moves across as it is.
        if !wrapped && !src.wrapped && mark_rows[MARK_CURSOR] != i && mark_rows[MARK_SAVED] != i && mark_rows[MARK_TOP] != i {
            if used := used_cells(src.cells[:]); used <= cols {
                resize(&src.cells, used)
                append(&out, src^)
                line_no += 1
                continue
            }
        }
        // A wide rune that did not fit left one pad cell before the wrap.
        if wrapped && len(logical) > 0 && len(src.cells) > 0 && .Wide in src.cells[0].flags && is_pad(logical[len(logical) - 1]) {
            pop(&logical)
        }
        for &m, k in marks {
            if m.set && mark_rows[k] == i {
                m.line = line_no
                m.offset += len(logical)
            }
        }
        append(&logical, ..src.cells[:])
        delete(src.cells)
        wrapped = src.wrapped
        if !wrapped || i == total - 1 {
            rewrap(&out, &logical, line_no, marks[:], cols)
            clear(&logical)
            line_no += 1
        }
    }
    delete(t.primary)
    delete(t.scrollback)
    t.scrollback = make([dynamic]Line)
    t.scrollback_head = 0

    start := marks[MARK_TOP].row
    if !t.alt_active && marks[MARK_CURSOR].row - start >= rows {
        start = marks[MARK_CURSOR].row - rows + 1
    }
    start = clamp(start, 0, len(out))

    for i in 0 ..< start {
        scrollback_push(t, out[i])
    }
    t.primary = make([dynamic]Line, 0, rows)
    for i in start ..< len(out) {
        if len(t.primary) < rows {
            line := out[i]
            if old := len(line.cells); old != cols {
                resize(&line.cells, cols)
                for x in old ..< cols {
                    line.cells[x] = {ch = ' '}
                }
            }
            append(&t.primary, line)
        } else {
            delete(out[i].cells)
        }
    }
    delete(out)
    for len(t.primary) < rows {
        append(&t.primary, line_make(cols))
    }

    if !t.alt_active {
        c := marks[MARK_CURSOR]
        t.cur.x, t.cur.y, t.cur.pending_wrap = c.col, clamp(c.row - start, 0, rows - 1), c.pending
    }
    s := marks[MARK_SAVED]
    t.saved.cur.x, t.saved.cur.y, t.saved.cur.pending_wrap = s.col, clamp(s.row - start, 0, rows - 1), s.pending
}

// Wraps one logical line into rows of `cols` cells appended to `out`, and
// places the marks that sit on it. A double-width rune is never split: one
// that does not fit leaves a pad and starts the next row.
@(private = "file")
rewrap :: proc(out: ^[dynamic]Line, logical: ^[dynamic]Cell, line_no: int, marks: []Mark, cols: int) {
    // Trailing blanks go, but never the cells a mark stands on.
    keep := 0
    for m in marks {
        if m.set && m.line == line_no {
            keep = max(keep, m.offset)
        }
    }
    end := len(logical)
    for end > keep && is_pad(logical[end - 1]) {
        end -= 1
    }
    for len(logical) < keep {
        append(logical, Cell{ch = ' '})
    }
    end = max(end, min(keep, len(logical)))
    cells := logical[:end]

    row := line_make(cols)
    col := 0
    place :: proc(marks: []Mark, line_no, index, row, col: int) {
        for &m in marks {
            if m.set && m.line == line_no && m.offset == index {
                m.row, m.col, m.pending = row, col, false
            }
        }
    }
    for i := 0; i < len(cells); {
        cell  := cells[i]
        width := 1
        if .Wide in cell.flags {
            if i + 1 < len(cells) && .Spacer in cells[i + 1].flags {
                width = 2
            } else {
                cell = {ch = ' ', bg = cell.bg}
            }
        } else if .Spacer in cell.flags {
            cell = {ch = ' ', bg = cell.bg}
        }
        if col + width > cols && col > 0 {
            row.wrapped = true
            append(out, row)
            row = line_make(cols)
            col = 0
        }
        place(marks, line_no, i, len(out), col)
        if width == 2 {
            place(marks, line_no, i + 1, len(out), col)
        }
        if width > cols {
            row.cells[col] = {ch = ' ', bg = cell.bg}
            col += 1
        } else {
            row.cells[col] = cell
            for k in 1 ..< width {
                row.cells[col + k] = cells[i + k]
            }
            col += width
        }
        i += width
    }
    append(out, row)
    // A mark past the last cell: after it on the same row, or past the edge.
    for &m in marks {
        if m.set && m.line == line_no && m.offset >= len(cells) {
            m.row = len(out) - 1
            m.col, m.pending = col, false
            if col >= cols {
                m.col, m.pending = cols - 1, true
            }
        }
    }
}

// The cells of a row up to its last one that is not a pad.
@(private = "file")
used_cells :: proc(cells: []Cell) -> int {
    end := len(cells)
    for end > 0 && is_pad(cells[end - 1]) {
        end -= 1
    }
    return end
}

// A cell that holds nothing: no glyph, no colour, no decoration.
@(private = "file")
is_pad :: proc(c: Cell) -> bool {
    return c.ch == ' ' && c.bg.kind == .Default && c.attrs == {} && c.flags == {} && c.grapheme == 0 && c.link == 0
}
