// Package textedit is the UI-independent editing core: cursors, selection,
// movement, edits, and undo/redo on top of a piece table. Widgets translate
// input into these operations and only handle measuring and drawing.
package textedit

import "core:strings"
import "core:unicode/utf8"

import "../piecetable"

// Selection spans anchor..caret; anchor == caret means no selection.
Cursor :: struct {
    caret:            int,
    anchor:           int,
    preferred_column: int,
}

Op_Kind :: enum {
    Insert,
    Delete,
}

Edit_Op :: struct {
    kind: Op_Kind,
    pos:  int,
    text: string, // owned copy
}

Undo_Entry :: struct {
    ops:            [dynamic]Edit_Op,
    cursors_before: [dynamic]Cursor,
    cursors_after:  [dynamic]Cursor,
}

State :: struct {
    table:      piecetable.Piece_Table,
    cursors:    [dynamic]Cursor,
    undo_stack: [dynamic]Undo_Entry,
    redo_stack: [dynamic]Undo_Entry,
    // Bumped on every content change (edits, undo, redo); reset by set_text.
    // Callers compare against a saved revision to detect unsaved changes.
    revision:   u64,
}

init :: proc(state: ^State) {
    append(&state.cursors, Cursor {})
}

destroy :: proc(state: ^State) {
    piecetable.piecetable_destroy(&state.table)
    delete(state.cursors)
    clear_entries(&state.undo_stack)
    clear_entries(&state.redo_stack)
    delete(state.undo_stack)
    delete(state.redo_stack)
}

set_text :: proc(state: ^State, new_text: string) {
    piecetable.piecetable_set_text(&state.table, new_text)
    clear_entries(&state.undo_stack)
    clear_entries(&state.redo_stack)
    clear(&state.cursors)
    append(&state.cursors, Cursor {})
    state.revision = 0
}

// Materializes the buffer; valid until the allocator is reset.
text :: proc(state: ^State, allocator := context.temp_allocator) -> string {
    return piecetable.piecetable_to_string(&state.table, allocator)
}

length :: proc(state: ^State) -> int {
    return piecetable.piecetable_length(&state.table)
}

// ---------------------------------------------------------------------------
// Cursors

has_selection :: proc(cursor: Cursor) -> bool {
    return cursor.anchor != cursor.caret
}

selection_range :: proc(cursor: Cursor) -> (lo, hi: int) {
    if cursor.anchor <= cursor.caret {
        return cursor.anchor, cursor.caret
    }
    return cursor.caret, cursor.anchor
}

primary_cursor :: proc(state: ^State) -> Cursor {
    return state.cursors[len(state.cursors) - 1]
}

set_single_cursor :: proc(state: ^State, pos: int) {
    txt := text(state)
    p := clamp(pos, 0, len(txt))
    clear(&state.cursors)
    append(&state.cursors, Cursor {caret = p, anchor = p, preferred_column = column(txt, p)})
}

collapse_to_primary :: proc(state: ^State) {
    primary := primary_cursor(state)
    clear(&state.cursors)
    append(&state.cursors, primary)
}

select_all :: proc(state: ^State) {
    txt := text(state)
    clear(&state.cursors)
    append(&state.cursors, Cursor {
        caret = len(txt),
        anchor = 0,
        preferred_column = column(txt, len(txt)),
    })
}

// Keeps cursors sorted by caret and merges duplicates.
@(private)
normalize_cursors :: proc(state: ^State) {
    for i in 1 ..< len(state.cursors) {
        j := i
        for j > 0 && state.cursors[j - 1].caret > state.cursors[j].caret {
            state.cursors[j - 1], state.cursors[j] = state.cursors[j], state.cursors[j - 1]
            j -= 1
        }
    }

    i := len(state.cursors) - 1
    for i > 0 {
        if state.cursors[i].caret == state.cursors[i - 1].caret {
            ordered_remove(&state.cursors, i - 1)
        }
        i -= 1
    }
}

@(private)
clone_cursors :: proc(state: ^State) -> [dynamic]Cursor {
    out := make([dynamic]Cursor, len(state.cursors))
    copy(out[:], state.cursors[:])
    return out
}

// ---------------------------------------------------------------------------
// Movement

move_horizontal :: proc(state: ^State, delta: int, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        if !extend && has_selection(cursor) {
            lo, hi := selection_range(cursor)
            cursor.caret = delta < 0 ? lo : hi
        } else if delta < 0 && cursor.caret > 0 {
            _, width := utf8.decode_last_rune_in_string(txt[:cursor.caret])
            cursor.caret -= width
        } else if delta > 0 && cursor.caret < len(txt) {
            _, width := utf8.decode_rune_in_string(txt[cursor.caret:])
            cursor.caret += width
        }
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
}

move_word :: proc(state: ^State, direction: int, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        if direction < 0 {
            cursor.caret = word_boundary_left(txt, cursor.caret)
        } else {
            cursor.caret = word_boundary_right(txt, cursor.caret)
        }
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
}

move_vertical :: proc(state: ^State, delta: int, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        target := line_index(txt, cursor.caret) + delta
        if target < 0 {
            target = 0
        }
        start := line_start_of_index(txt, target)
        cursor.caret = offset_for_column(txt, start, cursor.preferred_column)
        if !extend {
            cursor.anchor = cursor.caret
        }
    }
    normalize_cursors(state)
}

move_line_start :: proc(state: ^State, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.caret = line_start(txt, cursor.caret)
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = 0
    }
    normalize_cursors(state)
}

move_line_end :: proc(state: ^State, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.caret = line_end(txt, cursor.caret)
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
}

move_document_start :: proc(state: ^State, extend: bool) {
    for &cursor in state.cursors {
        cursor.caret = 0
        if !extend {
            cursor.anchor = 0
        }
        cursor.preferred_column = 0
    }
    normalize_cursors(state)
}

move_document_end :: proc(state: ^State, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.caret = len(txt)
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
}

// Jumps to (or selects up to, with extend) the bracket matching the one the
// cursor sits in front of.
move_to_matching_bracket :: proc(state: ^State, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        bracket_pos, match_pos, forward, found := find_matching_bracket(txt, cursor.caret)
        if !found {
            continue
        }
        if extend {
            // Select the bracketed range including both brackets.
            if forward {
                cursor.anchor = bracket_pos
                cursor.caret = match_pos + 1
            } else {
                cursor.anchor = bracket_pos + 1
                cursor.caret = match_pos
            }
        } else {
            cursor.caret = match_pos
            cursor.anchor = match_pos
        }
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
}

// Spawns an extra cursor one line above (delta < 0) or below each existing one.
add_cursor_vertical :: proc(state: ^State, delta: int) {
    txt := text(state)
    spawned := make([dynamic]Cursor, context.temp_allocator)
    for cursor in state.cursors {
        target := line_index(txt, cursor.caret) + delta
        if target < 0 {
            continue
        }
        start := line_start_of_index(txt, target)
        if line_index(txt, start) != target {
            continue
        }
        pos := offset_for_column(txt, start, cursor.preferred_column)
        append(&spawned, Cursor {caret = pos, anchor = pos, preferred_column = cursor.preferred_column})
    }
    for cursor in spawned {
        append(&state.cursors, cursor)
    }
    normalize_cursors(state)
}

// ---------------------------------------------------------------------------
// Edits (all recorded for undo)

insert_text :: proc(state: ^State, s: string) {
    if len(s) == 0 {
        return
    }
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
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(s)})
        piecetable.piecetable_insert(&state.table, lo + offset, s)
        cursor.caret = lo + offset + len(s)
        cursor.anchor = cursor.caret
        offset += len(s) - (hi - lo)
    }

    finish_edit(state, &entry)
}

delete_backward :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    offset := 0
    changed := false
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && lo > 0 {
            _, width := utf8.decode_last_rune_in_string(txt[:lo])
            lo -= width
        }
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            piecetable.piecetable_delete(&state.table, lo + offset, hi - lo)
            changed = true
        }
        cursor.caret = lo + offset
        cursor.anchor = cursor.caret
        offset -= hi - lo
    }

    if changed {
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
}

delete_forward :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    offset := 0
    changed := false
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && lo < len(txt) {
            _, width := utf8.decode_rune_in_string(txt[lo:])
            hi = lo + width
        }
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            piecetable.piecetable_delete(&state.table, lo + offset, hi - lo)
            changed = true
        }
        cursor.caret = lo + offset
        cursor.anchor = cursor.caret
        offset -= hi - lo
    }

    if changed {
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
}

undo :: proc(state: ^State) {
    if len(state.undo_stack) == 0 {
        return
    }
    entry := pop(&state.undo_stack)

    #reverse for op in entry.ops {
        switch op.kind {
        case .Insert:
            piecetable.piecetable_delete(&state.table, op.pos, len(op.text))
        case .Delete:
            piecetable.piecetable_insert(&state.table, op.pos, op.text)
        }
    }

    clear(&state.cursors)
    for cursor in entry.cursors_before {
        append(&state.cursors, cursor)
    }
    append(&state.redo_stack, entry)
    state.revision += 1
}

redo :: proc(state: ^State) {
    if len(state.redo_stack) == 0 {
        return
    }
    entry := pop(&state.redo_stack)

    for op in entry.ops {
        switch op.kind {
        case .Insert:
            piecetable.piecetable_insert(&state.table, op.pos, op.text)
        case .Delete:
            piecetable.piecetable_delete(&state.table, op.pos, len(op.text))
        }
    }

    clear(&state.cursors)
    for cursor in entry.cursors_after {
        append(&state.cursors, cursor)
    }
    append(&state.undo_stack, entry)
    state.revision += 1
}

@(private)
finish_edit :: proc(state: ^State, entry: ^Undo_Entry) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.preferred_column = column(txt, cursor.caret)
    }
    normalize_cursors(state)
    entry.cursors_after = clone_cursors(state)
    append(&state.undo_stack, entry^)
    clear_entries(&state.redo_stack)
    state.revision += 1
}

@(private)
entry_destroy :: proc(entry: ^Undo_Entry) {
    for op in entry.ops {
        delete(op.text)
    }
    delete(entry.ops)
    delete(entry.cursors_before)
    delete(entry.cursors_after)
}

@(private)
clear_entries :: proc(stack: ^[dynamic]Undo_Entry) {
    for &entry in stack {
        entry_destroy(&entry)
    }
    clear(stack)
}

// ---------------------------------------------------------------------------
// String geometry helpers (byte offsets, UTF-8 aware columns)

// Byte offset of the start of the line containing `pos`.
line_start :: proc(txt: string, pos: int) -> int {
    start := pos
    for start > 0 && txt[start - 1] != '\n' {
        start -= 1
    }
    return start
}

// Byte offset of the '\n' terminating the line containing `pos` (or len(txt)).
line_end :: proc(txt: string, pos: int) -> int {
    end := pos
    for end < len(txt) && txt[end] != '\n' {
        end += 1
    }
    return end
}

// Zero-based index of the line containing `pos`.
line_index :: proc(txt: string, pos: int) -> int {
    count := 0
    for i in 0 ..< pos {
        if txt[i] == '\n' {
            count += 1
        }
    }
    return count
}

line_count :: proc(txt: string) -> int {
    count := 1
    for i in 0 ..< len(txt) {
        if txt[i] == '\n' {
            count += 1
        }
    }
    return count
}

// Start byte of the given line index, clamped to the last line.
line_start_of_index :: proc(txt: string, line: int) -> int {
    start := 0
    index := 0
    for index < line {
        end := line_end(txt, start)
        if end >= len(txt) {
            break
        }
        start = end + 1
        index += 1
    }
    return start
}

// Rune column of `pos` within its line.
column :: proc(txt: string, pos: int) -> int {
    start := line_start(txt, pos)
    return utf8.rune_count_in_string(txt[start:pos])
}

// Byte offset `col` runes into the line starting at `start`, clamped to the
// end of that line.
offset_for_column :: proc(txt: string, start: int, col: int) -> int {
    pos := start
    current := 0
    for pos < len(txt) && txt[pos] != '\n' && current < col {
        _, width := utf8.decode_rune_in_string(txt[pos:])
        pos += width
        current += 1
    }
    return pos
}

// ---------------------------------------------------------------------------
// Word and bracket scanning

@(private)
is_word_byte :: proc(b: u8) -> bool {
    return b == '_' ||
        (b >= '0' && b <= '9') ||
        (b >= 'a' && b <= 'z') ||
        (b >= 'A' && b <= 'Z') ||
        b >= 0x80
}

@(private)
is_space_byte :: proc(b: u8) -> bool {
    return b == ' ' || b == '\t' || b == '\r'
}

@(private)
word_boundary_right :: proc(txt: string, pos: int) -> int {
    p := pos
    if p >= len(txt) {
        return p
    }
    if txt[p] == '\n' {
        return p + 1
    }
    for p < len(txt) && is_space_byte(txt[p]) {
        p += 1
    }
    if p < len(txt) && txt[p] == '\n' {
        return p
    }
    if p < len(txt) && is_word_byte(txt[p]) {
        for p < len(txt) && is_word_byte(txt[p]) {
            p += 1
        }
    } else {
        for p < len(txt) && !is_word_byte(txt[p]) && !is_space_byte(txt[p]) && txt[p] != '\n' {
            p += 1
        }
    }
    return p
}

@(private)
word_boundary_left :: proc(txt: string, pos: int) -> int {
    p := pos
    if p <= 0 {
        return 0
    }
    if txt[p - 1] == '\n' {
        return p - 1
    }
    for p > 0 && is_space_byte(txt[p - 1]) {
        p -= 1
    }
    if p > 0 && txt[p - 1] == '\n' {
        return p
    }
    if p > 0 && is_word_byte(txt[p - 1]) {
        for p > 0 && is_word_byte(txt[p - 1]) {
            p -= 1
        }
    } else {
        for p > 0 && !is_word_byte(txt[p - 1]) && !is_space_byte(txt[p - 1]) && txt[p - 1] != '\n' {
            p -= 1
        }
    }
    return p
}

@(private)
bracket_kind :: proc(b: u8) -> (open: u8, close: u8, forward: bool, ok: bool) {
    switch b {
    case '(':
        return '(', ')', true, true
    case '[':
        return '[', ']', true, true
    case '{':
        return '{', '}', true, true
    case ')':
        return '(', ')', false, true
    case ']':
        return '[', ']', false, true
    case '}':
        return '{', '}', false, true
    }
    return 0, 0, false, false
}

// Looks for a bracket at `pos` (or just before it) and finds its match.
@(private)
find_matching_bracket :: proc(txt: string, pos: int) -> (bracket_pos, match_pos: int, forward, found: bool) {
    candidates := [2]int {pos, pos - 1}
    for p in candidates {
        if p < 0 || p >= len(txt) {
            continue
        }
        open, close, fwd, ok := bracket_kind(txt[p])
        if !ok {
            continue
        }
        depth := 1
        if fwd {
            for i := p + 1; i < len(txt); i += 1 {
                if txt[i] == open {
                    depth += 1
                } else if txt[i] == close {
                    depth -= 1
                    if depth == 0 {
                        return p, i, true, true
                    }
                }
            }
        } else {
            for i := p - 1; i >= 0; i -= 1 {
                if txt[i] == close {
                    depth += 1
                } else if txt[i] == open {
                    depth -= 1
                    if depth == 0 {
                        return p, i, false, true
                    }
                }
            }
        }
    }
    return 0, 0, false, false
}
