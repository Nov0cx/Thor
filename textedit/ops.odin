// Higher-level editing operations built on the textedit core: clipboard
// payloads, word/line selection, line moving, indent and comment toggling.
// Every mutating operation lands as a single undo entry.
package textedit

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "../piecetable"

has_any_selection :: proc(state: ^State) -> bool {
    for cursor in state.cursors {
        if has_selection(cursor) {
            return true
        }
    }
    return false
}

// Drops secondary cursors and clears the primary selection (Escape).
clear_selections :: proc(state: ^State) {
    collapse_to_primary(state)
    cursor := &state.cursors[0]
    cursor.anchor = cursor.caret
}

// Text for the clipboard: all selections joined with newlines, or the
// primary cursor's whole line (including its newline) when nothing is
// selected. The bool reports whether a selection was used.
copy_payload :: proc(state: ^State, allocator := context.temp_allocator) -> (string, bool) {
    txt := text(state)

    if has_any_selection(state) {
        builder := strings.builder_make(allocator)
        first := true
        for cursor in state.cursors {
            lo, hi := selection_range(cursor)
            if hi <= lo {
                continue
            }
            if !first {
                strings.write_byte(&builder, '\n')
            }
            strings.write_string(&builder, txt[lo:hi])
            first = false
        }
        return strings.to_string(builder), true
    }

    cursor := primary_cursor(state)
    start := line_start(txt, cursor.caret)
    end := line_end(txt, cursor.caret)
    if end < len(txt) {
        end += 1 // include the newline so pasting reproduces the line
    }
    return strings.clone(txt[start:end], allocator), false
}

// Expands every selection to whole lines including the trailing newline;
// repeating extends by one line (Ctrl+L, and the cut-line path).
select_line :: proc(state: ^State) {
    txt := text(state)
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        start := line_start(txt, lo)
        end := line_end(txt, hi)
        if end < len(txt) {
            end += 1
        }
        cursor.anchor = start
        cursor.caret = end
        cursor.preferred_column = column(txt, end)
    }
    normalize_cursors(state)
}

// Returns the [start, end) byte range of the word-characters surrounding pos,
// and whether any were found. Used by double-click / word-drag selection.
word_range_at :: proc(txt: string, pos: int) -> (int, int, bool) {
    start := pos
    end := pos
    for start > 0 && is_word_byte(txt[start - 1]) {
        start -= 1
    }
    for end < len(txt) && is_word_byte(txt[end]) {
        end += 1
    }
    return start, end, end > start
}

// Ctrl+D: without a selection, selects the word under each cursor; with a
// primary selection, adds a cursor at its next occurrence (wrapping).
select_word_or_next :: proc(state: ^State) {
    txt := text(state)
    primary := primary_cursor(state)

    if !has_selection(primary) {
        for &cursor in state.cursors {
            if has_selection(cursor) {
                continue
            }
            start, end, found := word_range_at(txt, cursor.caret)
            if found {
                cursor.anchor = start
                cursor.caret = end
                cursor.preferred_column = column(txt, end)
            }
        }
        normalize_cursors(state)
        return
    }

    lo, hi := selection_range(primary)
    needle := txt[lo:hi]

    next := -1
    if idx := strings.index(txt[hi:], needle); idx >= 0 {
        next = hi + idx
    } else if idx := strings.index(txt, needle); idx >= 0 && idx < lo {
        next = idx
    }
    if next < 0 {
        return
    }

    for cursor in state.cursors {
        clo, chi := selection_range(cursor)
        if clo == next && chi == next + len(needle) {
            return // already selected
        }
    }

    append(&state.cursors, Cursor {
        anchor = next,
        caret = next + len(needle),
        preferred_column = column(txt, next + len(needle)),
    })
    normalize_cursors(state)
}

delete_word_backward :: proc(state: ^State) {
    txt := text(state)
    for &cursor in state.cursors {
        if !has_selection(cursor) {
            cursor.anchor = word_boundary_left(txt, cursor.caret)
        }
    }
    delete_backward(state)
}

delete_word_forward :: proc(state: ^State) {
    txt := text(state)
    for &cursor in state.cursors {
        if !has_selection(cursor) {
            cursor.anchor = word_boundary_right(txt, cursor.caret)
        }
    }
    delete_forward(state)
}

// Deletes the whole line(s) covered by each cursor (Ctrl+Shift+K).
delete_lines :: proc(state: ^State) {
    select_line(state)
    delete_backward(state)
}

// Removes trailing spaces and tabs from every line as one undo entry.
trim_trailing_whitespace :: proc(state: ^State) {
    txt := text(state)
    edits := make([dynamic]Line_Edit, context.temp_allocator)
    pos := 0
    for pos <= len(txt) {
        end := line_end(txt, pos)
        trim := end
        for trim > pos && (txt[trim - 1] == ' ' || txt[trim - 1] == '\t') {
            trim -= 1
        }
        if trim < end {
            append(&edits, Line_Edit {pos = trim, remove = end - trim})
        }
        if end >= len(txt) {
            break
        }
        pos = end + 1
    }
    apply_line_edits(state, txt, edits[:])
}

insert_line_below :: proc(state: ^State) {
    move_line_end(state, false)
    insert_text(state, "\n")
}

insert_line_above :: proc(state: ^State) {
    move_line_start(state, false)
    insert_text(state, "\n")
    move_vertical(state, -1, false)
}

// Swaps the lines covered by the primary selection with the adjacent line.
// Multi-cursor line moves are ambiguous, so secondary cursors collapse.
move_lines :: proc(state: ^State, delta: int) {
    collapse_to_primary(state)
    txt := text(state)
    cursor := state.cursors[0]
    lo, hi := selection_range(cursor)

    block_start := line_start(txt, lo)
    block_end := line_end(txt, hi)
    block := txt[block_start:block_end]

    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    start, shift: int
    replacement: string

    if delta < 0 {
        if block_start == 0 {
            entry_destroy(&entry)
            return
        }
        prev_start := line_start(txt, block_start - 1)
        prev := txt[prev_start:block_start - 1]
        replacement = strings.concatenate({block, "\n", prev}, context.temp_allocator)
        start = prev_start
        shift = -(len(prev) + 1)
    } else {
        if block_end >= len(txt) {
            entry_destroy(&entry)
            return
        }
        next_end := line_end(txt, block_end + 1)
        next := txt[block_end + 1:next_end]
        replacement = strings.concatenate({next, "\n", block}, context.temp_allocator)
        start = block_start
        shift = len(next) + 1
        block_end = next_end
    }

    removed := txt[start:block_end]
    append(&entry.ops, Edit_Op {kind = .Delete, pos = start, text = strings.clone(removed)})
    piecetable.piecetable_delete(&state.table, start, len(removed))
    append(&entry.ops, Edit_Op {kind = .Insert, pos = start, text = strings.clone(replacement)})
    piecetable.piecetable_insert(&state.table, start, replacement)

    state.cursors[0].caret += shift
    state.cursors[0].anchor += shift
    finish_edit(state, &entry)
}

// Duplicates the lines covered by the primary selection. delta < 0 keeps
// the cursor on the upper copy, delta > 0 moves it to the lower copy.
duplicate_lines :: proc(state: ^State, delta: int) {
    collapse_to_primary(state)
    txt := text(state)
    cursor := state.cursors[0]
    lo, hi := selection_range(cursor)

    block_start := line_start(txt, lo)
    block_end := line_end(txt, hi)
    inserted := strings.concatenate({txt[block_start:block_end], "\n"}, context.temp_allocator)

    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    append(&entry.ops, Edit_Op {kind = .Insert, pos = block_start, text = strings.clone(inserted)})
    piecetable.piecetable_insert(&state.table, block_start, inserted)

    if delta > 0 {
        state.cursors[0].caret += len(inserted)
        state.cursors[0].anchor += len(inserted)
    }
    finish_edit(state, &entry)
}

Case_Transform :: enum {
    Upper,
    Lower,
    Title, // capitalize the first letter of each word, lower-case the rest
}

// Upper/lower/title-cases each selection, or the word under the caret when it
// has none. ASCII-only, so byte lengths are preserved and cursors stay valid;
// other bytes pass through. One undo entry.
transform_case :: proc(state: ^State, mode: Case_Transform) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    changed := false

    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        had_selection := hi > lo
        if !had_selection {
            start, end, found := word_range_at(txt, cursor.caret)
            if !found {
                continue
            }
            lo, hi = start, end
        }

        original := txt[lo:hi]
        transformed := transform_case_bytes(original, mode)
        if transformed == original {
            continue
        }

        append(&entry.ops, Edit_Op {kind = .Delete, pos = lo, text = strings.clone(original)})
        piecetable.piecetable_delete(&state.table, lo, hi - lo)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo, text = strings.clone(transformed)})
        piecetable.piecetable_insert(&state.table, lo, transformed)
        changed = true

        if had_selection {
            cursor.anchor = lo
            cursor.caret = hi
        }
    }

    if changed {
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
}

@(private = "file")
transform_case_bytes :: proc(s: string, mode: Case_Transform, allocator := context.temp_allocator) -> string {
    buf := make([]u8, len(s), allocator)
    at_word_start := true
    for i in 0 ..< len(s) {
        c := s[i]
        switch mode {
        case .Upper:
            buf[i] = ascii_upper(c)
        case .Lower:
            buf[i] = ascii_lower(c)
        case .Title:
            word := is_word_byte(c)
            switch {
            case word && at_word_start:
                buf[i] = ascii_upper(c)
            case word:
                buf[i] = ascii_lower(c)
            case:
                buf[i] = c
            }
            at_word_start = !word
        }
    }
    return string(buf)
}

@(private = "file")
ascii_upper :: proc(b: u8) -> u8 {
    return b >= 'a' && b <= 'z' ? b - 32 : b
}

@(private = "file")
ascii_lower :: proc(b: u8) -> u8 {
    return b >= 'A' && b <= 'Z' ? b + 32 : b
}

// Joins the lines covered by the primary selection into one; with no selection,
// joins the current line with the one below. Each joined-in line's indentation
// is replaced by a single space. Secondary cursors collapse.
join_lines :: proc(state: ^State) {
    collapse_to_primary(state)
    txt := text(state)
    cursor := state.cursors[0]
    lo, hi := selection_range(cursor)

    first := line_start(txt, lo)
    last_ls := line_start(txt, hi)
    if last_ls == first {
        // Single line selected: join it with the following line.
        le := line_end(txt, first)
        if le >= len(txt) {
            return // nothing below to join
        }
        last_ls = le + 1
    }
    region_end := line_end(txt, last_ls)
    region := txt[first:region_end]

    joined := strings.builder_make(context.temp_allocator)
    segments := strings.split(region, "\n", context.temp_allocator)
    caret_at := first
    for seg, i in segments {
        if i == 0 {
            head := strings.trim_right(seg, " \t\r")
            strings.write_string(&joined, head)
            caret_at = first + len(head)
            continue
        }
        piece := strings.trim_space(seg)
        if piece == "" {
            continue
        }
        current := strings.to_string(joined)
        if len(current) > 0 && current[len(current) - 1] != ' ' {
            strings.write_byte(&joined, ' ')
        }
        strings.write_string(&joined, piece)
    }
    replacement := strings.to_string(joined)

    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    removed := txt[first:region_end]
    append(&entry.ops, Edit_Op {kind = .Delete, pos = first, text = strings.clone(removed)})
    piecetable.piecetable_delete(&state.table, first, len(removed))
    append(&entry.ops, Edit_Op {kind = .Insert, pos = first, text = strings.clone(replacement)})
    piecetable.piecetable_insert(&state.table, first, replacement)

    state.cursors[0].caret = caret_at
    state.cursors[0].anchor = caret_at
    finish_edit(state, &entry)
}

@(private = "file")
Line_Edit :: struct {
    pos:    int,    // position in the original text
    remove: int,    // bytes to delete at pos
    insert: string, // text to insert at pos (after the removal)
}

// Line starts covered by any cursor, ascending and unique. A selection
// ending exactly at a line start does not include that line.
@(private = "file")
covered_line_starts :: proc(txt: string, state: ^State) -> [dynamic]int {
    starts := make([dynamic]int, context.temp_allocator)
    for cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi > lo && txt[hi - 1] == '\n' {
            hi -= 1
        }
        pos := line_start(txt, lo)
        for {
            append(&starts, pos)
            end := line_end(txt, pos)
            if end >= hi || end >= len(txt) {
                break
            }
            pos = end + 1
        }
    }

    slice.sort(starts[:])
    unique := 0
    for start, index in starts {
        if index == 0 || start != starts[unique - 1] {
            starts[unique] = start
            unique += 1
        }
    }
    resize(&starts, unique)
    return starts
}

@(private = "file")
remap_pos :: proc(pos: int, edits: []Line_Edit) -> int {
    result := pos
    for edit in edits {
        if edit.pos > pos {
            break
        }
        removed := edit.remove
        if pos < edit.pos + removed {
            removed = pos - edit.pos
        }
        result += len(edit.insert) - removed
    }
    return result
}

// Applies position-ascending edits as one undo entry and remaps cursors.
@(private = "file")
apply_line_edits :: proc(state: ^State, txt: string, edits: []Line_Edit) {
    if len(edits) == 0 {
        return
    }

    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    offset := 0
    for edit in edits {
        pos := edit.pos + offset
        if edit.remove > 0 {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = pos, text = strings.clone(txt[edit.pos:edit.pos + edit.remove])})
            piecetable.piecetable_delete(&state.table, pos, edit.remove)
        }
        if len(edit.insert) > 0 {
            append(&entry.ops, Edit_Op {kind = .Insert, pos = pos, text = strings.clone(edit.insert)})
            piecetable.piecetable_insert(&state.table, pos, edit.insert)
        }
        offset += len(edit.insert) - edit.remove
    }

    for &cursor in state.cursors {
        cursor.caret = remap_pos(cursor.caret, edits)
        cursor.anchor = remap_pos(cursor.anchor, edits)
    }
    finish_edit(state, &entry)
}

// Soft indentation: a level is g_tab_width spaces, never a literal tab.
// Configurable at runtime, so a package variable rather than a constant.
@(private)
g_tab_width := 4

// Backing storage for indent_unit(); slicing gives 1..MAX_TAB_WIDTH spaces.
@(private)
MAX_TAB_WIDTH :: 16
@(private)
INDENT_SPACES :: "                " // MAX_TAB_WIDTH spaces

tab_width :: proc() -> int {
    return g_tab_width
}

set_tab_width :: proc(width: int) {
    g_tab_width = clamp(width, 1, MAX_TAB_WIDTH)
}

@(private)
indent_unit :: proc() -> string {
    spaces := INDENT_SPACES
    return spaces[:g_tab_width]
}

// Soft-tab insert at each caret: adds spaces up to the next TAB_WIDTH column so
// indentation snaps to consistent stops. Used for Tab without a selection.
insert_soft_tab :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    // Cursors are kept sorted; apply low to high, shifting later positions.
    offset := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            piecetable.piecetable_delete(&state.table, lo + offset, hi - lo)
        }
        count := g_tab_width - (column(txt, lo) % g_tab_width)
        all_spaces := INDENT_SPACES
        spaces := all_spaces[:count]
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(spaces)})
        piecetable.piecetable_insert(&state.table, lo + offset, spaces)
        cursor.caret = lo + offset + count
        cursor.anchor = cursor.caret
        offset += count - (hi - lo)
    }

    finish_edit(state, &entry)
}

// Inserts a newline that keeps the current line's leading whitespace, and adds
// one extra indent level when the caret follows an opening bracket. Replaces
// any selection, like a normal newline insert.
insert_newline :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    offset := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            piecetable.piecetable_delete(&state.table, lo + offset, hi - lo)
        }

        ls := line_start(txt, lo)
        ws_end := ls
        for ws_end < len(txt) && (txt[ws_end] == ' ' || txt[ws_end] == '\t') {
            ws_end += 1
        }
        indent := txt[ls:min(ws_end, lo)]

        // One extra level if the last non-blank character before the caret on
        // this line opens a bracket.
        j := lo - 1
        for j >= ls && (txt[j] == ' ' || txt[j] == '\t') {
            j -= 1
        }
        extra := ""
        if j >= ls && (txt[j] == '{' || txt[j] == '[' || txt[j] == '(') {
            extra = indent_unit()
        }

        insert_str := strings.concatenate({"\n", indent, extra}, context.temp_allocator)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(insert_str)})
        piecetable.piecetable_insert(&state.table, lo + offset, insert_str)
        cursor.caret = lo + offset + len(insert_str)
        cursor.anchor = cursor.caret
        offset += len(insert_str) - (hi - lo)
    }

    finish_edit(state, &entry)
}

// True when typing `{` should expand into a three-line block rather than a
// plain `{}` pair: a single cursor with no selection sitting at the end of its
// line (only whitespace, if any, follows the caret on that line).
brace_block_applies :: proc(state: ^State) -> bool {
    if len(state.cursors) != 1 {
        return false
    }
    cursor := state.cursors[0]
    if has_selection(cursor) {
        return false
    }
    txt := text(state)
    for i := cursor.caret; i < len(txt) && txt[i] != '\n'; i += 1 {
        if txt[i] != ' ' && txt[i] != '\t' {
            return false
        }
    }
    return true
}

// Inserts a `{ }` block spread over three lines with the caret on the indented
// middle line. Assumes brace_block_applies(state) held (single collapsed cursor).
insert_brace_block :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    cursor := &state.cursors[0]
    lo := cursor.caret
    ls := line_start(txt, lo)
    ws_end := ls
    for ws_end < len(txt) && (txt[ws_end] == ' ' || txt[ws_end] == '\t') {
        ws_end += 1
    }
    indent := txt[ls:min(ws_end, lo)]

    head := strings.concatenate({"{\n", indent, indent_unit()}, context.temp_allocator)
    full := strings.concatenate({head, "\n", indent, "}"}, context.temp_allocator)

    piecetable.piecetable_insert(&state.table, lo, full)
    append(&entry.ops, Edit_Op {kind = .Insert, pos = lo, text = strings.clone(full)})
    cursor.caret = lo + len(head)
    cursor.anchor = cursor.caret

    finish_edit(state, &entry)
}

indent_lines :: proc(state: ^State) {
    txt := text(state)
    starts := covered_line_starts(txt, state)
    edits := make([dynamic]Line_Edit, context.temp_allocator)
    for start in starts {
        append(&edits, Line_Edit {pos = start, insert = indent_unit()})
    }
    apply_line_edits(state, txt, edits[:])
}

outdent_lines :: proc(state: ^State) {
    txt := text(state)
    starts := covered_line_starts(txt, state)
    edits := make([dynamic]Line_Edit, context.temp_allocator)
    for start in starts {
        if start < len(txt) && txt[start] == '\t' {
            append(&edits, Line_Edit {pos = start, remove = 1})
            continue
        }
        spaces := 0
        for start + spaces < len(txt) && spaces < g_tab_width && txt[start + spaces] == ' ' {
            spaces += 1
        }
        if spaces > 0 {
            append(&edits, Line_Edit {pos = start, remove = spaces})
        }
    }
    apply_line_edits(state, txt, edits[:])
}

// Comments the covered lines with `prefix`, or uncomments when every
// non-blank covered line already starts with it. Blank lines are skipped.
toggle_comment :: proc(state: ^State, prefix: string) {
    if prefix == "" {
        return
    }
    txt := text(state)
    starts := covered_line_starts(txt, state)

    all_commented := true
    any_content := false
    for start in starts {
        end := line_end(txt, start)
        i := start
        for i < end && (txt[i] == ' ' || txt[i] == '\t') {
            i += 1
        }
        if i == end {
            continue // blank line
        }
        any_content = true
        if !strings.has_prefix(txt[i:end], prefix) {
            all_commented = false
        }
    }
    if !any_content {
        return
    }

    edits := make([dynamic]Line_Edit, context.temp_allocator)
    marker := strings.concatenate({prefix, " "}, context.temp_allocator)
    for start in starts {
        end := line_end(txt, start)
        i := start
        for i < end && (txt[i] == ' ' || txt[i] == '\t') {
            i += 1
        }
        if i == end {
            continue
        }

        if all_commented {
            remove := len(prefix)
            if i + remove < end && txt[i + remove] == ' ' {
                remove += 1
            }
            append(&edits, Line_Edit {pos = i, remove = remove})
        } else if !strings.has_prefix(txt[i:end], prefix) {
            append(&edits, Line_Edit {pos = i, insert = marker})
        }
    }
    apply_line_edits(state, txt, edits[:])
}

// Aligns the covered lines so the first `target` on each lands in one column,
// normalizing the whitespace before it to the needed padding (min one space).
// Lines without the target, or where it is the first non-blank character, are
// left untouched. One undo entry.
align_at_char :: proc(state: ^State, target: rune) {
    txt := text(state)
    starts := covered_line_starts(txt, state)

    // First pass: locate the target on each line and the column just after the
    // token preceding it; the alignment column is one past the widest of those.
    Line_Target :: struct {
        ws_start, char_pos, content_col: int,
    }
    targets := make([dynamic]Line_Target, context.temp_allocator)
    align_col := 0
    for start in starts {
        end := line_end(txt, start)
        char_pos := -1
        for i := start; i < end; {
            r, w := utf8.decode_rune_in_string(txt[i:])
            if r == target {
                char_pos = i
                break
            }
            i += w
        }
        if char_pos < 0 {
            continue
        }
        ws := char_pos
        for ws > start && (txt[ws - 1] == ' ' || txt[ws - 1] == '\t') {
            ws -= 1
        }
        if ws == start {
            continue // target is the first non-blank; leave indentation alone
        }
        content_col := column(txt, ws)
        append(&targets, Line_Target {ws_start = ws, char_pos = char_pos, content_col = content_col})
        align_col = max(align_col, content_col + 1)
    }

    edits := make([dynamic]Line_Edit, context.temp_allocator)
    for t in targets {
        spaces := strings.repeat(" ", align_col - t.content_col, context.temp_allocator)
        append(&edits, Line_Edit {pos = t.ws_start, remove = t.char_pos - t.ws_start, insert = spaces})
    }
    apply_line_edits(state, txt, edits[:])
}
