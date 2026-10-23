// Comment interleaving: one cursor over the comment groups of the file, in
// source order, that the visitor moves up to each position it prints.
package odinfmt

import "core:strings"

// The alignment ids one node was given, filled by a per-body pre-pass and read
// by whichever visitor prints that node. The run decision needs the whole run;
// the emission happens several visitors deeper. A side table keyed on the node
// keeps the two apart without threading an id through print_field, print_expr
// and print_value_decl. Id 0 is "no cell".
Align_Cell :: struct {
    head:  int, // the name..':' cell
    value: int, // the type cell, so what follows it lines up
}

Printer :: struct {
    opts:          Options,
    src:           string,
    line_starts:   []int, // the offset each line starts at
    comments:      []Comment_Group,
    comment_idx:   int,
    next_align_id: int,
    align_ids:     map[u64]Align_Cell,
    depth:         int,
    too_deep:      bool, // the printer went past MAX_DEPTH; the output is not used
}

@(private)
next_align :: proc(pr: ^Printer) -> int {
    pr.next_align_id += 1
    return pr.next_align_id
}

// The key of `n` in Printer.align_ids.
@(private)
align_key :: #force_inline proc(n: Node) -> u64 {
    return u64(n.start) << 16 | u64(n.kind)
}

// The cell ids for `n`, or the zero value when it is in no run.
@(private)
align_cell :: proc(pr: ^Printer, n: Node) -> Align_Cell {
    return pr.align_ids[align_key(n)]
}

// Whether two consecutive body items may share one alignment run: every line
// strictly between them holds a comment, so only a blank line breaks a run. A
// comment line between two cells is printed on its own line at the cells' indent,
// and a trailing comment on prev's own last line is printed after the cell, so
// neither moves a cell's column.
//
// The scan may start at the cursor: every pre-pass runs before its body's emit
// loop, so a comment inside that body is always at an index the cursor has not
// reached, and a comment before it is skipped by the first test.
@(private)
same_align_run :: proc(pr: ^Printer, prev_end_line, next_start_line: int) -> bool {
    expect := prev_end_line + 1
    for i := pr.comment_idx; i < len(pr.comments); i += 1 {
        cg := pr.comments[i]
        if cg.line <= prev_end_line {
            continue
        }
        if cg.line >= next_start_line {
            break
        }
        for tok in cg.list {
            if tok.line != expect {
                return false
            }
            expect = comment_end_line(tok) + 1
        }
    }
    return expect == next_start_line
}

// blanks between two lines that are `gap` apart (gap = next.line - prev.line),
// clamped by the caller's newline_limit at render time — this just turns a
// line gap into "how many blank lines sit between them", never negative.
@(private)
blanks_between :: proc(prev_line, next_line: int) -> int {
    gap := next_line - prev_line - 1
    if gap < 0 {
        return 0
    }
    return gap
}

@(private)
comment_group_text :: proc(pr: ^Printer, cg: Comment_Group, out: ^[dynamic]Doc) {
    for tok, i in cg.list {
        if i > 0 {
            blanks := blanks_between(comment_end_line(cg.list[i - 1]), tok.line)
            append(out, hard_line(blanks))
        }
        trimmed := strings.trim_right_space(tok.text)
        append(out, text(trimmed))
        if strings.has_prefix(trimmed, "//") {
            // A line comment rendered flat would swallow whatever follows it
            // on that line, so every enclosing group has to break.
            append(out, break_parent())
        }
    }
}

// Appends every pending comment group that starts on `line` (the line the
// just-printed node ended on) as a trailing comment: a couple of spaces then
// the comment text, no line break of its own. Returns the line the printer
// should now treat as "last printed" (the trailing comment's own last line).
@(private)
flush_trailing :: proc(pr: ^Printer, out: ^[dynamic]Doc, line: int) -> int {
    last_line := line
    for pr.comment_idx < len(pr.comments) {
        cg := pr.comments[pr.comment_idx]
        if cg.line != last_line {
            break
        }
        append(out, text("  "))
        comment_group_text(pr, cg, out)
        last_line = comment_end_line(cg.list[len(cg.list) - 1])
        pr.comment_idx += 1
    }
    return last_line
}

// Flushes any trailing comment clinging to prev's last line, then every
// own-line comment that falls before next's line (or, with has_next false,
// every comment left), preserving blank-line gaps throughout. Does not add
// the final gap up to `next` itself — see separator, which adds that on top
// for the common "print next right after" case; a caller that supplies its
// own fixed newline before what comes next (a closing brace) wants this one
// instead, or its own hard_line(0) would double up with the gap this leaves
// behind.
@(private)
flush_before :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool, next_line: int, has_next: bool) -> (last_line: int, had_content: bool) {
    last_line = prev_line
    had_content = has_prev
    if has_prev {
        last_line = flush_trailing(pr, out, prev_line)
    }

    for pr.comment_idx < len(pr.comments) {
        cg := pr.comments[pr.comment_idx]
        if has_next && cg.line >= next_line {
            break
        }
        if had_content || len(out^) > 0 {
            append(out, hard_line(blanks_between(last_line, cg.line)))
        }
        comment_group_text(pr, cg, out)
        last_line = comment_end_line(cg.list[len(cg.list) - 1])
        pr.comment_idx += 1
        last_line = flush_trailing(pr, out, last_line)
        had_content = true
    }
    return
}

// flush_before, plus the gap up to `next` itself. Appends everything to
// `out`; the caller still owns emitting `next`'s own content afterward.
@(private)
separator :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool, next_line: int, has_next: bool) {
    last_line, had_content := flush_before(pr, out, prev_line, has_prev, next_line, has_next)
    if has_next {
        if had_content || len(out^) > 0 {
            append(out, hard_line(blanks_between(last_line, next_line)))
        }
    }
}

// Flushes every comment left in pr.comments (called once, after the last
// top-level declaration) so trailing free-floating comments are never lost.
@(private)
flush_remaining :: proc(pr: ^Printer, out: ^[dynamic]Doc, prev_line: int, has_prev: bool) {
    separator(pr, out, prev_line, has_prev, 0, false)
}

// The line a comment ends on: a `/* */` can span several.
@(private)
comment_end_line :: proc(tok: Comment) -> int {
    return tok.line + strings.count(tok.text, "\n")
}

// The pending comment groups that start before `offset`, one Doc each.
@(private)
take_comments_before :: proc(pr: ^Printer, offset: int) -> []Doc {
    out := make([dynamic]Doc)
    for pr.comment_idx < len(pr.comments) {
        cg := pr.comments[pr.comment_idx]
        if cg.start >= offset {
            break
        }
        group_doc: [dynamic]Doc
        comment_group_text(pr, cg, &group_doc)
        append(&out, concat(group_doc[:]))
        pr.comment_idx += 1
    }
    return out[:]
}

// The pending comment groups on `line` that start before `offset`: the
// comments that trail an item on its own line.
@(private)
take_trailing :: proc(pr: ^Printer, line, offset: int) -> []Doc {
    out := make([dynamic]Doc)
    for pr.comment_idx < len(pr.comments) {
        cg := pr.comments[pr.comment_idx]
        if cg.start >= offset || cg.line != line {
            break
        }
        group_doc: [dynamic]Doc
        comment_group_text(pr, cg, &group_doc)
        append(&out, concat(group_doc[:]))
        pr.comment_idx += 1
    }
    return out[:]
}

// Whether a pending comment group starts before `offset`.
@(private)
comment_before :: proc(pr: ^Printer, offset: int) -> bool {
    return pr.comment_idx < len(pr.comments) && pr.comments[pr.comment_idx].start < offset
}
