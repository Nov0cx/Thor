package vt

import "core:strings"

// Reading the grid back as text: what a copy puts on the clipboard and what the
// host matches a file path in.

// A cell in the scrollback-plus-screen sequence, as `term_line` numbers it.
Position :: struct {
    line, col: int,
}

// Writes the text of `line` into `builder`, stopping at the last cell that
// carries anything. A spacer is skipped, so a double-width character counts once.
line_write :: proc(t: ^Term, line: ^Line, builder: ^strings.Builder, from := 0, to := -1) {
    if line == nil {
        return
    }
    hi := to < 0 ? len(line.cells) : min(to, len(line.cells))
    hi = trimmed_end(line, hi)
    for x in max(from, 0) ..< hi {
        cell := line.cells[x]
        if .Spacer in cell.flags {
            continue
        }
        if g := term_grapheme(t, cell.grapheme); g != "" {
            strings.write_string(builder, g)
            continue
        }
        strings.write_rune(builder, cell.ch == 0 ? ' ' : cell.ch)
    }
}

// The text of `line` with its trailing blanks dropped.
line_text :: proc(t: ^Term, line: ^Line, allocator := context.temp_allocator) -> string {
    builder := strings.builder_make(allocator)
    line_write(t, line, &builder)
    return strings.to_string(builder)
}

// The text of the line at `index`, or "" when the index names none.
term_line_text :: proc(t: ^Term, index: int, allocator := context.temp_allocator) -> string {
    return line_text(t, term_line(t, index), allocator)
}

// Where the content of a row ends: the last cell that is not a plain blank.
@(private = "file")
trimmed_end :: proc(line: ^Line, limit: int) -> int {
    end := limit
    for end > 0 {
        cell := line.cells[end - 1]
        if cell.ch != ' ' && cell.ch != 0 {
            break
        }
        if cell.grapheme != 0 {
            break
        }
        end -= 1
    }
    return end
}

// The text between two cells, `end` not included. A row that wrapped joins the
// next with no newline between them, since the two are one line of output.
term_text_range :: proc(
    t: ^Term,
    start, end: Position,
    allocator := context.temp_allocator,
) -> string {
    start, end := start, end
    if end.line < start.line || (end.line == start.line && end.col < start.col) {
        start, end = end, start
    }
    builder := strings.builder_make(allocator)
    for index in start.line ..= end.line {
        line := term_line(t, index)
        if line == nil {
            continue
        }
        from := index == start.line ? start.col : 0
        to := index == end.line ? end.col : len(line.cells)
        line_write(t, line, &builder, from, to)
        if index < end.line && !line.wrapped {
            strings.write_byte(&builder, '\n')
        }
    }
    return strings.to_string(builder)
}

// The whole scrollback and screen as text.
term_text_all :: proc(t: ^Term, allocator := context.temp_allocator) -> string {
    total := term_total_lines(t)
    if total == 0 {
        return ""
    }
    last := term_line(t, total - 1)
    return term_text_range(
        t,
        {line = 0, col = 0},
        {line = total - 1, col = last == nil ? 0 : len(last.cells)},
        allocator,
    )
}

// The column a byte offset of `line_text` falls in, which is how a host that
// matched a pattern in the row text paints the match back onto cells.
column_of_offset :: proc(t: ^Term, line: ^Line, offset: int) -> int {
    if line == nil {
        return 0
    }
    seen := 0
    for x in 0 ..< len(line.cells) {
        if seen >= offset {
            return x
        }
        cell := line.cells[x]
        if .Spacer in cell.flags {
            continue
        }
        if g := term_grapheme(t, cell.grapheme); g != "" {
            seen += len(g)
            continue
        }
        seen += rune_byte_len(cell.ch == 0 ? ' ' : cell.ch)
    }
    return len(line.cells)
}

@(private = "file")
rune_byte_len :: proc(r: rune) -> int {
    switch {
    case r < 0x80:
        return 1
    case r < 0x800:
        return 2
    case r < 0x10000:
        return 3
    }
    return 4
}
