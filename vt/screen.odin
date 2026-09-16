package vt

import "core:strings"
import "core:unicode/utf8"

// The cursor, the scrolling region and everything that writes into the grid.
// Every column and row here is 0-based; the protocol's 1-based numbers are
// converted where they arrive.

TAB_WIDTH :: 8

@(private)
tabs_reset :: proc(t: ^Term) {
    resize(&t.tabs, t.cols)
    for i in 0 ..< t.cols {
        t.tabs[i] = i % TAB_WIDTH == 0 && i > 0
    }
}

@(private)
tab_stop_next :: proc(t: ^Term, from: int) -> int {
    for x := from + 1; x < t.cols; x += 1 {
        if t.tabs[x] {
            return x
        }
    }
    return t.cols - 1
}

@(private)
tab_stop_prev :: proc(t: ^Term, from: int) -> int {
    for x := from - 1; x > 0; x -= 1 {
        if t.tabs[x] {
            return x
        }
    }
    return 0
}

// The rows the cursor may move between: the scrolling region while origin mode
// holds, the whole screen otherwise.
@(private)
bounds :: proc(t: ^Term) -> (top: int, bottom: int) {
    if t.origin {
        return t.top, t.bottom
    }
    return 0, t.rows - 1
}

@(private)
row :: proc(t: ^Term, y: int) -> ^Line {
    g := grid(t)
    if y < 0 || y >= len(g) {
        return nil
    }
    return &g[y]
}

@(private)
cursor_row :: proc(t: ^Term) -> ^Line {
    return row(t, t.cur.y)
}

// CUP and friends. `x` and `y` are absolute unless origin mode is on, where `y`
// counts from the top of the scrolling region.
@(private)
cursor_move :: proc(t: ^Term, x, y: int) {
    top, bottom := bounds(t)
    t.cur.x = clamp(x, 0, t.cols - 1)
    t.cur.y = clamp(t.origin ? top + y : y, top, bottom)
    t.cur.pending_wrap = false
}

@(private)
cursor_up :: proc(t: ^Term, n: int) {
    top, _ := bounds(t)
    // A cursor already above the region moves within the screen instead, which
    // is what leaving the region by an absolute move leaves behind.
    limit := t.cur.y < top ? 0 : top
    t.cur.y = max(t.cur.y - max(n, 1), limit)
    t.cur.pending_wrap = false
}

@(private)
cursor_down :: proc(t: ^Term, n: int) {
    _, bottom := bounds(t)
    limit := t.cur.y > bottom ? t.rows - 1 : bottom
    t.cur.y = min(t.cur.y + max(n, 1), limit)
    t.cur.pending_wrap = false
}

@(private)
cursor_left :: proc(t: ^Term, n: int) {
    n := max(n, 1)
    t.cur.pending_wrap = false
    // Reverse wrap walks back onto the line above, which is how a shell erases
    // a prompt that ran over the right edge.
    if t.reverse_wrap {
        for _ in 0 ..< n {
            if t.cur.x > 0 {
                t.cur.x -= 1
            } else if t.cur.y > t.top {
                t.cur.y -= 1
                t.cur.x = t.cols - 1
            }
        }
        return
    }
    t.cur.x = max(t.cur.x - n, 0)
}

@(private)
cursor_right :: proc(t: ^Term, n: int) {
    t.cur.x = min(t.cur.x + max(n, 1), t.cols - 1)
    t.cur.pending_wrap = false
}

@(private)
carriage_return :: proc(t: ^Term) {
    t.cur.x = 0
    t.cur.pending_wrap = false
}

// LF, VT and FF: one row down, scrolling the region when the cursor sits on its
// last row.
@(private)
line_feed :: proc(t: ^Term) {
    t.cur.pending_wrap = false
    if t.cur.y == t.bottom {
        scroll_up(t, 1)
        return
    }
    if t.cur.y < t.rows - 1 {
        t.cur.y += 1
    }
}

// RI: one row up, scrolling the region down at its top row.
@(private)
reverse_index :: proc(t: ^Term) {
    t.cur.pending_wrap = false
    if t.cur.y == t.top {
        scroll_down(t, 1)
        return
    }
    if t.cur.y > 0 {
        t.cur.y -= 1
    }
}

@(private)
next_line :: proc(t: ^Term) {
    line_feed(t)
    carriage_return(t)
}

// Moves the region up by `n` rows. On the primary screen with the region at the
// top of the display, the rows that leave become history.
@(private)
scroll_up :: proc(t: ^Term, n: int) {
    n := min(max(n, 1), t.bottom - t.top + 1)
    context.allocator = t.allocator
    g := grid(t)
    keep_history := !t.alt_active && t.top == 0

    for _ in 0 ..< n {
        line := g[t.top]
        ordered_remove(g, t.top)
        if keep_history {
            scrollback_push(t, line)
            inject_at(g, t.bottom, line_make(t.cols))
        } else {
            line_clear(&line, t.cur.pen)
            inject_at(g, t.bottom, line)
        }
    }
}

// Moves the region down by `n` rows, blanking the rows that open at its top.
@(private)
scroll_down :: proc(t: ^Term, n: int) {
    n := min(max(n, 1), t.bottom - t.top + 1)
    context.allocator = t.allocator
    g := grid(t)
    for _ in 0 ..< n {
        line := g[t.bottom]
        ordered_remove(g, t.bottom)
        line_clear(&line, t.cur.pen)
        inject_at(g, t.top, line)
    }
}

// IL: opens `n` blank rows at the cursor, pushing the rest of the region down.
// Outside the region it does nothing.
@(private)
insert_lines :: proc(t: ^Term, n: int) {
    if t.cur.y < t.top || t.cur.y > t.bottom {
        return
    }
    n := min(max(n, 1), t.bottom - t.cur.y + 1)
    context.allocator = t.allocator
    g := grid(t)
    for _ in 0 ..< n {
        line := g[t.bottom]
        ordered_remove(g, t.bottom)
        line_clear(&line, t.cur.pen)
        inject_at(g, t.cur.y, line)
    }
    t.cur.x = 0
    t.cur.pending_wrap = false
}

// DL: drops `n` rows at the cursor, pulling the rest of the region up.
@(private)
delete_lines :: proc(t: ^Term, n: int) {
    if t.cur.y < t.top || t.cur.y > t.bottom {
        return
    }
    n := min(max(n, 1), t.bottom - t.cur.y + 1)
    context.allocator = t.allocator
    g := grid(t)
    for _ in 0 ..< n {
        line := g[t.cur.y]
        ordered_remove(g, t.cur.y)
        line_clear(&line, t.cur.pen)
        inject_at(g, t.bottom, line)
    }
    t.cur.x = 0
    t.cur.pending_wrap = false
}

// ICH: opens `n` blank cells at the cursor, pushing the rest of the row off its
// right edge.
@(private)
insert_chars :: proc(t: ^Term, n: int) {
    line := cursor_row(t)
    if line == nil {
        return
    }
    n := min(max(n, 1), t.cols - t.cur.x)
    blank := blank_cell(t.cur.pen)
    for x := t.cols - 1; x >= t.cur.x + n; x -= 1 {
        line.cells[x] = line.cells[x - n]
    }
    for x in t.cur.x ..< t.cur.x + n {
        line.cells[x] = blank
    }
    t.cur.pending_wrap = false
}

// DCH: drops `n` cells at the cursor, pulling the rest of the row left.
@(private)
delete_chars :: proc(t: ^Term, n: int) {
    line := cursor_row(t)
    if line == nil {
        return
    }
    n := min(max(n, 1), t.cols - t.cur.x)
    blank := blank_cell(t.cur.pen)
    for x := t.cur.x; x < t.cols - n; x += 1 {
        line.cells[x] = line.cells[x + n]
    }
    for x in t.cols - n ..< t.cols {
        line.cells[x] = blank
    }
    t.cur.pending_wrap = false
}

// ECH: blanks `n` cells from the cursor without moving anything.
@(private)
erase_chars :: proc(t: ^Term, n: int) {
    line := cursor_row(t)
    if line == nil {
        return
    }
    blank := blank_cell(t.cur.pen)
    for x in t.cur.x ..< min(t.cur.x + max(n, 1), t.cols) {
        line.cells[x] = blank
    }
    t.cur.pending_wrap = false
}

// EL: 0 to the end of the row, 1 to its start, 2 the whole row.
@(private)
erase_line :: proc(t: ^Term, mode: int) {
    line := cursor_row(t)
    if line == nil {
        return
    }
    blank := blank_cell(t.cur.pen)
    lo, hi := 0, 0
    switch mode {
    case 0:
        lo, hi = t.cur.x, t.cols
    case 1:
        lo, hi = 0, min(t.cur.x + 1, t.cols)
    case 2:
        lo, hi = 0, t.cols
        line.wrapped = false
    case:
        return
    }
    for x in lo ..< hi {
        line.cells[x] = blank
    }
    t.cur.pending_wrap = false
}

// ED: 0 to the end of the screen, 1 to its start, 2 the whole screen, 3 the
// scrollback.
@(private)
erase_display :: proc(t: ^Term, mode: int) {
    blank := blank_cell(t.cur.pen)
    switch mode {
    case 0:
        erase_line(t, 0)
        for y in t.cur.y + 1 ..< t.rows {
            line_clear_with(row(t, y), blank)
        }
    case 1:
        erase_line(t, 1)
        for y in 0 ..< t.cur.y {
            line_clear_with(row(t, y), blank)
        }
    case 2:
        for y in 0 ..< t.rows {
            line_clear_with(row(t, y), blank)
        }
    case 3:
        term_clear_scrollback(t)
    }
    t.cur.pending_wrap = false
}

@(private = "file")
line_clear_with :: proc(line: ^Line, blank: Cell) {
    if line == nil {
        return
    }
    for &cell in line.cells {
        cell = blank
    }
    line.wrapped = false
}

// DECALN: the whole screen filled with E, which is the alignment test.
@(private)
screen_align_test :: proc(t: ^Term) {
    for y in 0 ..< t.rows {
        line := row(t, y)
        for &cell in line.cells {
            cell = {ch = 'E'}
        }
        line.wrapped = false
    }
    t.cur.x, t.cur.y = 0, 0
    t.cur.pending_wrap = false
}

// Switches between the primary and the alternate screen. `save` is what modes
// 1049 and 1048 add: the cursor is kept across the switch.
@(private)
set_alt_screen :: proc(t: ^Term, on: bool, save: bool, clear_on_enter: bool) {
    if on == t.alt_active {
        return
    }
    if on {
        if save {
            save_cursor(t)
        }
        t.alt_active = true
        if clear_on_enter {
            erase_display(t, 2)
            t.cur.x, t.cur.y = 0, 0
        }
        return
    }
    // What the alt screen held is never history; it goes when it is left.
    erase_display(t, 2)
    t.alt_active = false
    if save {
        restore_cursor(t)
    }
}

@(private)
save_cursor :: proc(t: ^Term) {
    slot := t.alt_active ? &t.saved_alt : &t.saved
    slot^ = {cur = t.cur, charsets = t.charsets, gl = t.gl, gr = t.gr, origin = t.origin, valid = true}
}

@(private)
restore_cursor :: proc(t: ^Term) {
    slot := t.alt_active ? &t.saved_alt : &t.saved
    if !slot.valid {
        t.cur = {}
        t.cur.pending_wrap = false
        return
    }
    t.cur = slot.cur
    t.charsets = slot.charsets
    t.gl, t.gr = slot.gl, slot.gr
    t.origin = slot.origin
    t.cur.x = clamp(t.cur.x, 0, t.cols - 1)
    t.cur.y = clamp(t.cur.y, 0, t.rows - 1)
    t.cur.pending_wrap = false
}

// ---- printing ------------------------------------------------------------------

// Writes one rune at the cursor, wrapping, inserting and combining as the modes
// and the rune's width ask.
@(private)
put_rune :: proc(t: ^Term, r: rune) {
    r := charset_map(t, r)
    width := rune_width(r)

    if width == 0 {
        combine_with_previous(t, r)
        return
    }

    if t.cur.pending_wrap && t.autowrap {
        if line := cursor_row(t); line != nil {
            line.wrapped = true
        }
        next_line(t)
    }
    // A double-width rune never straddles the right edge: it wraps first, or
    // sits in the last column as a single when wrapping is off.
    if width == 2 && t.cur.x + 1 >= t.cols {
        if !t.autowrap {
            return
        }
        if line := cursor_row(t); line != nil {
            line.wrapped = true
        }
        next_line(t)
    }

    if t.insert {
        insert_chars(t, width)
    }

    line := cursor_row(t)
    if line == nil {
        return
    }
    clear_wide_partner(t, line, t.cur.x)

    cell := Cell {
        ch        = r,
        fg        = t.cur.pen.fg,
        bg        = t.cur.pen.bg,
        ul        = t.cur.pen.ul,
        link      = t.cur.pen.link,
        attrs     = t.cur.pen.attrs,
        underline = t.cur.pen.underline,
    }
    if width == 2 {
        cell.flags += {.Wide}
        clear_wide_partner(t, line, t.cur.x + 1)
        line.cells[t.cur.x] = cell
        line.cells[t.cur.x + 1] = Cell {
            ch    = ' ',
            fg    = cell.fg,
            bg    = cell.bg,
            attrs = cell.attrs,
            flags = {.Spacer},
        }
    } else {
        line.cells[t.cur.x] = cell
    }

    if t.cur.x + width >= t.cols {
        t.cur.x = t.cols - 1
        t.cur.pending_wrap = true
    } else {
        t.cur.x += width
    }
}

// Overwriting one half of a double-width character blanks the other, so no
// spacer is left without its glyph.
@(private = "file")
clear_wide_partner :: proc(t: ^Term, line: ^Line, x: int) {
    if x < 0 || x >= len(line.cells) {
        return
    }
    cell := line.cells[x]
    if .Wide in cell.flags && x + 1 < len(line.cells) {
        line.cells[x + 1] = {ch = ' ', bg = cell.bg}
    }
    if .Spacer in cell.flags && x > 0 {
        line.cells[x - 1] = {ch = ' ', bg = cell.bg}
    }
}

// A zero-width rune decorates the cell the cursor last wrote. The base and its
// marks are interned, since a cell holds one rune.
@(private = "file")
combine_with_previous :: proc(t: ^Term, r: rune) {
    line := cursor_row(t)
    if line == nil {
        return
    }
    x := t.cur.pending_wrap ? t.cur.x : t.cur.x - 1
    if x < 0 || x >= len(line.cells) {
        return
    }
    if .Spacer in line.cells[x].flags && x > 0 {
        x -= 1
    }
    cell := &line.cells[x]

    context.allocator = t.allocator
    base := term_grapheme(t, cell.grapheme)
    builder := strings.builder_make(context.temp_allocator)
    if base != "" {
        strings.write_string(&builder, base)
    } else {
        strings.write_rune(&builder, cell.ch)
    }
    strings.write_rune(&builder, r)

    id, ok := grapheme_intern(t, strings.to_string(builder))
    if !ok {
        return
    }
    cell.grapheme = id
}

// Adds a grapheme to the pool. The pool only grows, so it is capped: past the
// cap a combining mark is dropped rather than left to grow without bound.
@(private = "file")
grapheme_intern :: proc(t: ^Term, text: string) -> (u32, bool) {
    if len(t.graphemes) >= MAX_GRAPHEMES {
        return 0, false
    }
    append(&t.graphemes, strings.clone(text, t.allocator))
    return u32(len(t.graphemes) - 1), true
}

// Applies the character set the active Gn slot names. Only DEC special graphics
// and the UK pound sign change what a byte draws.
@(private = "file")
charset_map :: proc(t: ^Term, r: rune) -> rune {
    slot := t.single_shift > 0 ? t.single_shift : t.gl
    t.single_shift = 0
    if r < 0x20 || r > 0x7e {
        return r
    }
    switch t.charsets[slot] {
    case .Ascii:
        return r
    case .Uk:
        return r == '#' ? '£' : r
    case .Dec_Graphics:
        if r >= 0x5f && r <= 0x7e {
            return DEC_GRAPHICS[r - 0x5f]
        }
        return r
    }
    return r
}

// DEC special graphics, 0x5f to 0x7e: the line-drawing set every full-screen
// program that predates Unicode boxes with.
@(private = "file")
DEC_GRAPHICS := [?]rune {
    ' ', '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└',
    '┼', '⎺', '⎻', '─', '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠',
    '£', '·',
}

@(private)
put_tab :: proc(t: ^Term, n: int) {
    for _ in 0 ..< max(n, 1) {
        t.cur.x = tab_stop_next(t, t.cur.x)
    }
    t.cur.pending_wrap = false
}

@(private)
put_backtab :: proc(t: ^Term, n: int) {
    for _ in 0 ..< max(n, 1) {
        t.cur.x = tab_stop_prev(t, t.cur.x)
    }
    t.cur.pending_wrap = false
}

// REP: the last printed rune again, `n` times.
@(private)
repeat_last :: proc(t: ^Term, last: rune, n: int) {
    if last == 0 {
        return
    }
    for _ in 0 ..< max(n, 1) {
        put_rune(t, last)
    }
}

// Writes `text` into the reply the host owes the shell.
@(private)
reply :: proc(t: ^Term, text: string) {
    append(&t.reply, ..transmute([]u8) text)
}

@(private)
reply_rune :: proc(t: ^Term, r: rune) {
    buf, n := utf8.encode_rune(r)
    append(&t.reply, ..buf[:n])
}
