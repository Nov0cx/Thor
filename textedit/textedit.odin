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

// Replaces the cursor set with a single selection anchored at lo, caret at hi
// (used by find to highlight a match).
select_range :: proc(state: ^State, lo, hi: int) {
    txt := text(state)
    a := clamp(lo, 0, len(txt))
    b := clamp(hi, 0, len(txt))
    clear(&state.cursors)
    append(&state.cursors, Cursor {anchor = a, caret = b, preferred_column = column(txt, b)})
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

// Public entry point for callers (e.g. the editor's visual movement) that set
// cursor carets directly and need the sorted/merged invariant restored.
normalize :: proc(state: ^State) {
    normalize_cursors(state)
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

// Jumps to (or selects up to, with extend) the delimiter matching the one the
// cursor sits in front of. Brackets ()[]{} match by nesting depth; quotes
// " ' ` match their partner on the same line.
move_to_matching_bracket :: proc(state: ^State, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        // Adjacent bracket.
        if bracket_pos, match_pos, forward, found := find_matching_bracket(txt, cursor.caret); found {
            apply_delimiter_jump(&cursor, txt, bracket_pos, match_pos, forward, extend)
            continue
        }
        // Adjacent quote.
        if quote_pos, match_pos, forward, found := find_matching_quote(txt, cursor.caret); found {
            apply_delimiter_jump(&cursor, txt, quote_pos, match_pos, forward, extend)
            continue
        }

        // Not adjacent to a delimiter: fall back to the enclosing pair (bracket
        // or quote), jumping to its opener (extend selects the whole pair).
        if open_pos, close_pos, found := enclosing_pair(txt, cursor.caret); found {
            if extend {
                cursor.anchor = open_pos
                cursor.caret = close_pos + 1
            } else {
                cursor.caret = open_pos
                cursor.anchor = open_pos
            }
            cursor.preferred_column = column(txt, cursor.caret)
        }
    }
    normalize_cursors(state)
}

// Positions a cursor after find_matching_bracket / find_matching_quote located
// the partner delimiter. `forward` is true when the matched delimiter lies to
// the right of the one under the caret.
@(private)
apply_delimiter_jump :: proc(cursor: ^Cursor, txt: string, delim_pos, match_pos: int, forward, extend: bool) {
    if extend {
        if forward {
            cursor.anchor = delim_pos
            cursor.caret = match_pos + 1
        } else {
            cursor.anchor = delim_pos + 1
            cursor.caret = match_pos
        }
    } else {
        cursor.caret = match_pos
        cursor.anchor = match_pos
    }
    cursor.preferred_column = column(txt, cursor.caret)
}

// Selects the text between the innermost bracket pair around the caret,
// excluding the brackets. Works next to a bracket or from inside the pair.
select_between_brackets :: proc(state: ^State) {
    txt := text(state)
    for &cursor in state.cursors {
        open_pos, close_pos, found := bracket_span(txt, cursor.caret)
        if !found {
            continue
        }
        cursor.anchor = open_pos + 1
        cursor.caret = close_pos
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

// Matching close for an auto-paired opener; ok=false if r is not an opener.
auto_close_for :: proc(r: rune) -> (rune, bool) {
    switch r {
    case '(': return ')', true
    case '[': return ']', true
    case '{': return '}', true
    }
    return 0, false
}

is_close_bracket :: proc(r: rune) -> bool {
    return r == ')' || r == ']' || r == '}'
}

is_quote :: proc(r: rune) -> bool {
    return r == '"' || r == '\'' || r == '`'
}

@(private)
is_word_byte_ascii :: proc(b: u8) -> bool {
    return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_'
}

// Types an opener: wraps a selection in open..close, or inserts the pair with
// the caret left between them when there is no selection.
insert_pair :: proc(state: ^State, open, close: rune) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    ob, ow := utf8.encode_rune(open)
    cbuf, cw := utf8.encode_rune(close)
    open_s := string(ob[:ow])
    close_s := string(cbuf[:cw])

    offset := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        piecetable.piecetable_insert(&state.table, lo + offset, open_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(open_s)})
        close_pos := hi + offset + ow
        piecetable.piecetable_insert(&state.table, close_pos, close_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = close_pos, text = strings.clone(close_s)})

        cursor.anchor = lo + offset + ow
        cursor.caret = hi > lo ? hi + offset + ow : cursor.anchor
        offset += ow + cw
    }
    finish_edit(state, &entry)
}

// Types a closer: steps over an identical character already in front of the
// caret (so typing `)` past an auto-inserted `)` just moves), else inserts it.
insert_or_step :: proc(state: ^State, close: rune) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    cbuf, cw := utf8.encode_rune(close)
    close_s := string(cbuf[:cw])

    offset := 0
    edited := false
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && match_at(txt, lo, close_s, true) {
            cursor.caret = lo + offset + cw
            cursor.anchor = cursor.caret
            continue
        }
        if hi > lo {
            piecetable.piecetable_delete(&state.table, lo + offset, hi - lo)
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
        }
        piecetable.piecetable_insert(&state.table, lo + offset, close_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(close_s)})
        cursor.caret = lo + offset + cw
        cursor.anchor = cursor.caret
        offset += cw - (hi - lo)
        edited = true
    }
    if edited {
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
}

// Types a quote: wraps a selection, steps over an identical following quote,
// inserts a single quote after a word character (apostrophes), else inserts a
// matching pair with the caret between.
insert_quote :: proc(state: ^State, q: rune) {
    if has_any_selection(state) {
        insert_pair(state, q, q)
        return
    }

    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    qbuf, qw := utf8.encode_rune(q)
    q_s := string(qbuf[:qw])

    offset := 0
    for &cursor in state.cursors {
        lo, _ := selection_range(cursor)
        if match_at(txt, lo, q_s, true) {
            cursor.caret = lo + offset + qw
            cursor.anchor = cursor.caret
            continue
        }
        pair := !(lo > 0 && is_word_byte_ascii(txt[lo - 1]))
        piecetable.piecetable_insert(&state.table, lo + offset, q_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(q_s)})
        if pair {
            piecetable.piecetable_insert(&state.table, lo + offset + qw, q_s)
            append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset + qw, text = strings.clone(q_s)})
        }
        cursor.caret = lo + offset + qw
        cursor.anchor = cursor.caret
        offset += pair ? qw * 2 : qw
    }
    finish_edit(state, &entry)
}

// True when typing `*` should auto-close a block comment: a single collapsed
// cursor with a `/` immediately before the caret, so the `/*` just formed gets
// its matching `*/` like a bracket pair.
block_comment_applies :: proc(state: ^State) -> bool {
    if len(state.cursors) != 1 {
        return false
    }
    cursor := state.cursors[0]
    if has_selection(cursor) {
        return false
    }
    txt := text(state)
    return cursor.caret > 0 && txt[cursor.caret - 1] == '/'
}

// Types the `*` that completes a `/*` and inserts the matching `*/`, leaving the
// caret between them (`/*|*/`). Assumes block_comment_applies(state) held (single
// collapsed cursor with `/` before the caret).
insert_block_comment :: proc(state: ^State) {
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    cursor := &state.cursors[0]
    lo := cursor.caret
    piecetable.piecetable_insert(&state.table, lo, "**/")
    append(&entry.ops, Edit_Op {kind = .Insert, pos = lo, text = strings.clone("**/")})
    cursor.caret = lo + 1
    cursor.anchor = cursor.caret
    finish_edit(state, &entry)
}

// True when open/close form an auto-inserted pair (used for pair-aware
// backspace).
@(private)
is_auto_pair_bytes :: proc(open, close: u8) -> bool {
    switch open {
    case '(': return close == ')'
    case '[': return close == ']'
    case '{': return close == '}'
    case '"', '\'', '`': return close == open
    }
    return false
}

// True when `query` occurs at byte offset `pos` in txt (ASCII case-insensitive
// when insensitive).
@(private)
match_at :: proc(txt: string, pos: int, query: string, case_sensitive: bool) -> bool {
    if pos + len(query) > len(txt) {
        return false
    }
    for i in 0 ..< len(query) {
        a := txt[pos + i]
        b := query[i]
        if !case_sensitive {
            if a >= 'A' && a <= 'Z' {a += 32}
            if b >= 'A' && b <= 'Z' {b += 32}
        }
        if a != b {
            return false
        }
    }
    return true
}

// Replaces every occurrence of `query` with `replacement` as a single undo
// step. Returns the number of replacements made.
replace_all :: proc(state: ^State, query, replacement: string, case_sensitive: bool) -> int {
    if len(query) == 0 {
        return 0
    }
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    offset := 0
    count := 0
    i := 0
    for i + len(query) <= len(txt) {
        if !match_at(txt, i, query, case_sensitive) {
            i += 1
            continue
        }
        append(&entry.ops, Edit_Op {kind = .Delete, pos = i + offset, text = strings.clone(txt[i:i + len(query)])})
        piecetable.piecetable_delete(&state.table, i + offset, len(query))
        if len(replacement) > 0 {
            append(&entry.ops, Edit_Op {kind = .Insert, pos = i + offset, text = strings.clone(replacement)})
            piecetable.piecetable_insert(&state.table, i + offset, replacement)
        }
        offset += len(replacement) - len(query)
        count += 1
        i += len(query)
    }

    if count > 0 {
        clear(&state.cursors)
        append(&state.cursors, Cursor {caret = 0, anchor = 0})
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
    return count
}

delete_backward :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}

    offset := 0
    changed := false
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && lo > 0 {
            // Empty auto-pair (e.g. caret between "()"): delete both sides.
            if lo < len(txt) && is_auto_pair_bytes(txt[lo - 1], txt[lo]) {
                lo -= 1
                hi += 1
            } else {
                _, width := utf8.decode_last_rune_in_string(txt[:lo])
                lo -= width
            }
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

// Resolves the delimiter pair to act on for a caret: prefers a bracket or quote
// directly adjacent to the caret, otherwise the innermost pair enclosing it.
bracket_span :: proc(txt: string, pos: int) -> (open_pos, close_pos: int, found: bool) {
    if bracket_pos, match_pos, forward, ok := find_matching_bracket(txt, pos); ok {
        if forward {
            return bracket_pos, match_pos, true
        }
        return match_pos, bracket_pos, true
    }
    if quote_pos, match_pos, forward, ok := find_matching_quote(txt, pos); ok {
        if forward {
            return quote_pos, match_pos, true
        }
        return match_pos, quote_pos, true
    }
    return enclosing_pair(txt, pos)
}

// Innermost pair enclosing pos, considering both brackets and quotes; the pair
// whose opener is closest to pos (largest opening offset) wins.
@(private)
enclosing_pair :: proc(txt: string, pos: int) -> (open_pos, close_pos: int, found: bool) {
    bo, bc, bok := find_enclosing_bracket(txt, pos)
    qo, qc, qok := find_enclosing_quote(txt, pos)
    switch {
    case bok && qok:
        if qo > bo {
            return qo, qc, true
        }
        return bo, bc, true
    case bok:
        return bo, bc, true
    case qok:
        return qo, qc, true
    }
    return 0, 0, false
}

@(private)
is_quote_byte :: proc(b: u8) -> bool {
    return b == '"' || b == '\'' || b == '`'
}

// Partner of a quote at or just before pos, on the same line. Parity of
// same-type quotes before it decides open vs close (even => opening, partner right).
@(private)
find_matching_quote :: proc(txt: string, pos: int) -> (quote_pos, match_pos: int, forward, found: bool) {
    candidates := [2]int {pos, pos - 1}
    for p in candidates {
        if p < 0 || p >= len(txt) || !is_quote_byte(txt[p]) {
            continue
        }
        q := txt[p]
        ls := line_start(txt, p)
        le := line_end(txt, p)
        count := 0
        for i := ls; i < p; i += 1 {
            if txt[i] == q {
                count += 1
            }
        }
        if count % 2 == 0 {
            for i := p + 1; i < le; i += 1 {
                if txt[i] == q {
                    return p, i, true, true
                }
            }
        } else {
            for i := p - 1; i >= ls; i -= 1 {
                if txt[i] == q {
                    return p, i, false, true
                }
            }
        }
    }
    return 0, 0, false, false
}

// Innermost quote pair on the caret's line enclosing pos (quotes excluded).
// Same-type quotes cannot nest, so pairs form left-to-right; closest opener wins.
@(private)
find_enclosing_quote :: proc(txt: string, pos: int) -> (open_pos, close_pos: int, found: bool) {
    ls := line_start(txt, pos)
    le := line_end(txt, pos)
    best_open := -1
    best_close := -1
    for q in ([?]u8 {'"', '\'', '`'}) {
        open := -1
        for i := ls; i < le; i += 1 {
            if txt[i] != q {
                continue
            }
            if open < 0 {
                open = i
            } else {
                if pos > open && pos <= i && open > best_open {
                    best_open = open
                    best_close = i
                }
                open = -1
            }
        }
    }
    if best_open < 0 {
        return 0, 0, false
    }
    return best_open, best_close, true
}

// Innermost bracket pair enclosing pos: scans left for the nearest unmatched
// opener, then forward for its partner. Fallback when not next to a bracket.
find_enclosing_bracket :: proc(txt: string, pos: int) -> (open_pos, close_pos: int, found: bool) {
    // Closers seen per type while scanning left; an opener with no outstanding
    // closer of its type is the one we enclose.
    pending: [3]int // ( ) , [ ] , { }
    open_char: u8
    open_pos = -1
    for i := min(pos, len(txt)) - 1; i >= 0; i -= 1 {
        switch txt[i] {
        case ')': pending[0] += 1
        case ']': pending[1] += 1
        case '}': pending[2] += 1
        case '(':
            if pending[0] > 0 { pending[0] -= 1 } else { open_pos = i; open_char = '(' }
        case '[':
            if pending[1] > 0 { pending[1] -= 1 } else { open_pos = i; open_char = '[' }
        case '{':
            if pending[2] > 0 { pending[2] -= 1 } else { open_pos = i; open_char = '{' }
        }
        if open_pos >= 0 {
            break
        }
    }
    if open_pos < 0 {
        return 0, 0, false
    }

    open, close, _, _ := bracket_kind(open_char)
    depth := 1
    for i := open_pos + 1; i < len(txt); i += 1 {
        if txt[i] == open {
            depth += 1
        } else if txt[i] == close {
            depth -= 1
            if depth == 0 {
                return open_pos, i, true
            }
        }
    }
    return 0, 0, false
}
