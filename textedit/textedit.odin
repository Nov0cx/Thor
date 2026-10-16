// Package textedit is the UI-independent editing core: cursors, selection,
// movement, edits, and undo/redo on top of a piece table. Widgets translate
// input into these operations and only handle measuring and drawing.
package textedit

import "core:strings"
import "core:unicode"
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

// How an edit may fold into the entry below it on the undo stack, so a typed
// word or a run of backspaces takes one step to undo instead of one per key.
Coalesce :: enum {
    None,
    Typing,
    Delete_Back,
    Delete_Forward,
}

Undo_Entry :: struct {
    ops:            [dynamic]Edit_Op, // owned, with the text of every op
    cursors_before: [dynamic]Cursor,  // owned
    cursors_after:  [dynamic]Cursor,  // owned
    coalesce:       Coalesce,
    // State.content_id before and after the entry.
    id_before:      u64,
    id_after:       u64,
}

// Bounds on the undo history. Past either, the oldest entries are dropped; the newest always stays.
MAX_UNDO_ENTRIES :: 1024
MAX_UNDO_BYTES :: 16 * 1024 * 1024

// The undo history, a ring over one block. Dropping the oldest entry moves `start`.
Undo_Ring :: struct {
    entries: [dynamic]Undo_Entry, // owned
    start:   int, // slot of the oldest entry
    count:   int,
}

State :: struct {
    table:      piecetable.Piece_Table, // owned
    cursors:    [dynamic]Cursor,        // owned
    undo_stack: Undo_Ring,              // owned
    redo_stack: [dynamic]Undo_Entry,    // owned
    // Op text held by undo_stack, against MAX_UNDO_BYTES.
    undo_bytes: int,
    // True while the top undo entry can still absorb the next keystroke.
    coalescing: bool,
    // Bumped on every content change (edits, undo, redo, set_text); never lowered.
    // Callers compare against a saved revision to detect unsaved changes.
    revision:   u64,
    // Names the content: the revision that first made it. Undo and redo bring
    // an older value back, so equal ids mean equal text.
    content_id: u64,
    // This document's soft-tab width; 0 follows the package default.
    tab_width:  int,
    // This document's indent style; Unknown follows the package default.
    indent_style: Indent_Style,
    // Comment and string syntax for bracket matching. Borrowed.
    lexical:    Lexical,
    // Byte offset of every line start, so a line query is a binary search and not
    // a scan from byte 0. Patched from the change log at the first query after a
    // content change, like the text snapshot, and rebuilt when the log no longer
    // reaches back. Offsets, not
    // slices, so an edit cannot leave it pointing into dead text.
    lines:          [dynamic]int, // owned
    lines_revision: u64,
    lines_valid:    bool,
    // The last CHANGE_LOG changes, at index revision % CHANGE_LOG.
    changes:        [CHANGE_LOG]Change,
}

// One content change: the bytes [lo, old_hi) of the text before it became the
// bytes [lo, new_hi) of the text after it.
Change :: struct {
    revision: u64, // the revision the change made
    lo:       int,
    old_hi:   int,
    new_hi:   int,
}

// Changes kept for a reader that is behind; older ones are lost.
CHANGE_LOG :: 64

// The change that made `revision`. False when it is no longer in the log.
change_at :: proc(state: ^State, revision: u64) -> (Change, bool) {
    change := state.changes[revision % CHANGE_LOG]
    return change, revision != 0 && change.revision == revision
}

// The changes after `revision` up to the current one, joined into one span over
// the text at `revision`. False when the log no longer reaches back that far.
changes_since :: proc(state: ^State, revision: u64) -> (Change, bool) {
    if revision == 0 || revision >= state.revision || state.revision - revision > CHANGE_LOG {
        return {}, false
    }
    total, ok := change_at(state, revision + 1)
    if !ok {
        return {}, false
    }
    for r := revision + 2; r <= state.revision; r += 1 {
        next, found := change_at(state, r)
        if !found {
            return {}, false
        }
        hi := max(total.new_hi, next.old_hi)
        total.old_hi = hi - (total.new_hi - total.old_hi)
        total.new_hi = hi + (next.new_hi - next.old_hi)
        total.lo = min(total.lo, next.lo)
    }
    total.revision = state.revision
    return total, true
}

// Logs the span of `ops` as the change that made `revision`. With `reverse`,
// the ops are undone: walked from the last, each kind inverted.
@(private)
record_change :: proc(state: ^State, revision: u64, ops: []Edit_Op, reverse := false) {
    lo, hi, delta := 0, -1, 0
    for i in 0 ..< len(ops) {
        op := ops[reverse ? len(ops) - 1 - i : i]
        n := len(op.text)
        insert := (op.kind == .Insert) != reverse
        if hi < 0 {
            lo, hi = op.pos, op.pos
        }
        lo = min(lo, op.pos)
        if insert {
            hi = op.pos <= hi ? hi + n : op.pos + n
            delta += n
        } else {
            hi = max(hi, op.pos + n) - n
            delta -= n
        }
    }
    hi = max(hi, lo)
    state.changes[revision % CHANGE_LOG] = Change {
        revision = revision,
        lo       = lo,
        old_hi   = hi - delta,
        new_hi   = hi,
    }
}

init :: proc(state: ^State) {
    append(&state.cursors, Cursor {})
}

destroy :: proc(state: ^State) {
    piecetable.piecetable_destroy(&state.table)
    delete(state.cursors)
    ring_destroy(&state.undo_stack)
    clear_entries(&state.redo_stack)
    delete(state.redo_stack)
    delete(state.lines)
}

set_text :: proc(state: ^State, new_text: string) {
    old_len := length(state)
    piecetable.piecetable_set_text(&state.table, new_text)
    ring_clear(&state.undo_stack)
    clear_entries(&state.redo_stack)
    clear(&state.cursors)
    append(&state.cursors, Cursor {})
    state.undo_bytes = 0
    state.coalescing = false
    state.revision += 1
    state.content_id = state.revision
    state.lines_valid = false
    state.changes[state.revision % CHANGE_LOG] = Change {
        revision = state.revision,
        old_hi   = old_len,
        new_hi   = len(new_text),
    }
}

// Replaces the whole text as one undo entry, so a reload from disk can be
// undone. Only the part that differs is recorded. The cursors are clamped to
// the new text. False when the text is the same.
replace_text :: proc(state: ^State, new_text: string) -> bool {
    old := text(state)
    if old == new_text {
        return false
    }
    limit := min(len(old), len(new_text))
    prefix := 0
    for prefix < limit && old[prefix] == new_text[prefix] {
        prefix += 1
    }
    suffix := 0
    for suffix < limit - prefix && old[len(old) - 1 - suffix] == new_text[len(new_text) - 1 - suffix] {
        suffix += 1
    }

    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    removed := old[prefix:len(old) - suffix]
    inserted := new_text[prefix:len(new_text) - suffix]
    if len(removed) > 0 {
        append(&entry.ops, Edit_Op {kind = .Delete, pos = prefix, text = strings.clone(removed)})
        table_delete(state, prefix, len(removed))
    }
    if len(inserted) > 0 {
        append(&entry.ops, Edit_Op {kind = .Insert, pos = prefix, text = strings.clone(inserted)})
        table_insert(state, prefix, inserted)
    }
    for &cursor in state.cursors {
        cursor.caret = min(cursor.caret, len(new_text))
        cursor.anchor = min(cursor.anchor, len(new_text))
    }
    finish_edit(state, &entry)
    return true
}

// The id of the current content. See State.content_id.
content_id :: proc(state: ^State) -> u64 {
    return state.content_id
}

// The id of the current content, for a save. Ends the typing run, so the next
// key makes its own undo entry and undo can come back to this content.
checkpoint :: proc(state: ^State) -> u64 {
    state.coalescing = false
    return state.content_id
}

// The buffer's contents, borrowed from the piece table. Valid until the first
// call that follows a content change: that call re-materializes the snapshot,
// so a caller which keeps the text across an edit needs text_clone.
text :: proc(state: ^State) -> string {
    return piecetable.piecetable_view(&state.table)
}

// An owned copy of the buffer, for the callers that outlive the next edit.
text_clone :: proc(state: ^State, allocator := context.allocator) -> string {
    return piecetable.piecetable_to_string(&state.table, allocator)
}

length :: proc(state: ^State) -> int {
    return piecetable.piecetable_length(&state.table)
}

// Why a checked edit did nothing.
Error :: enum {
    None,
    Out_Of_Range,
}

// Inserts into the table at an offset textedit computed itself. An offset out of
// range is a bug here, so it stops a debug build and changes nothing otherwise.
@(private)
table_insert :: proc(state: ^State, pos: int, text: string) {
    err := piecetable.piecetable_insert_checked(&state.table, pos, text)
    assert(err == .None, "textedit: insert offset out of range")
}

// Deletes from the table, as table_insert inserts.
@(private)
table_delete :: proc(state: ^State, pos, count: int) {
    err := piecetable.piecetable_delete_checked(&state.table, pos, count)
    assert(err == .None, "textedit: delete range out of range")
}

// True when `pos` can start an edit: 0 <= pos <= length. The end is included,
// because an insert appends there.
valid_offset :: proc(state: ^State, pos: int) -> bool {
    return piecetable.piecetable_valid_offset(&state.table, pos)
}

// True when `count` bytes from `pos` stay inside the buffer.
valid_range :: proc(state: ^State, pos, count: int) -> bool {
    return piecetable.piecetable_valid_range(&state.table, pos, count)
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
    append(&state.cursors, Cursor {caret = p, anchor = p, preferred_column = cursor_column(state, txt, p)})
}

// Replaces the whole cursor set, clamped to the buffer (used when the content is
// replaced under the cursors, e.g. a reload from disk). An empty set leaves one
// cursor at the start.
set_cursors :: proc(state: ^State, cursors: []Cursor) {
    txt := text(state)
    clear(&state.cursors)
    for cursor in cursors {
        caret := clamp(cursor.caret, 0, len(txt))
        anchor := clamp(cursor.anchor, 0, len(txt))
        append(&state.cursors, Cursor {
            caret = caret,
            anchor = anchor,
            preferred_column = cursor_column(state, txt, caret),
        })
    }
    if len(state.cursors) == 0 {
        append(&state.cursors, Cursor {})
    }
    normalize_cursors(state)
}

// Replaces the cursor set with a single selection anchored at lo, caret at hi
// (used by find to highlight a match).
select_range :: proc(state: ^State, lo, hi: int) {
    txt := text(state)
    a := clamp(lo, 0, len(txt))
    b := clamp(hi, 0, len(txt))
    clear(&state.cursors)
    append(&state.cursors, Cursor {anchor = a, caret = b, preferred_column = cursor_column(state, txt, b)})
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
        preferred_column = cursor_column(state, txt, len(txt)),
    })
}

// Public entry point for callers (e.g. the editor's visual movement) that set
// cursor carets directly and need the sorted/merged invariant restored.
normalize :: proc(state: ^State) {
    normalize_cursors(state)
}

// Keeps cursors sorted by selection start and merges the ones that overlap, so
// every edit path gets disjoint ascending ranges. Ranges that only meet at one
// point stay apart (adjacent Ctrl+D matches edit separately).
@(private)
normalize_cursors :: proc(state: ^State) {
    if len(state.cursors) < 2 {
        return
    }

    for i in 1 ..< len(state.cursors) {
        j := i
        for j > 0 && cursor_before(state.cursors[j], state.cursors[j - 1]) {
            state.cursors[j - 1], state.cursors[j] = state.cursors[j], state.cursors[j - 1]
            j -= 1
        }
    }

    txt := text(state)
    for i := len(state.cursors) - 1; i > 0; i -= 1 {
        if !cursors_merge(state.cursors[i - 1], state.cursors[i]) {
            continue
        }
        state.cursors[i] = merged_cursor(state.cursors[i - 1], state.cursors[i], txt, tab_width(state))
        ordered_remove(&state.cursors, i - 1)
    }
}

// Orders cursors by selection start, then by selection end.
@(private)
cursor_before :: proc(a, b: Cursor) -> bool {
    a_lo, a_hi := selection_range(a)
    b_lo, b_hi := selection_range(b)
    return a_lo < b_lo || (a_lo == b_lo && a_hi < b_hi)
}

// True when a and b (a first in sort order) must become one cursor: their
// ranges overlap, or they meet at one point and one of them is a bare caret.
@(private)
cursors_merge :: proc(a, b: Cursor) -> bool {
    _, a_hi := selection_range(a)
    b_lo, _ := selection_range(b)
    if a_hi > b_lo {
        return true
    }
    return a_hi == b_lo && (!has_selection(a) || !has_selection(b))
}

// One cursor covering both ranges, facing the way b faces, or a's way when b is
// a bare caret.
@(private)
merged_cursor :: proc(a, b: Cursor, txt: string, tab_width: int) -> Cursor {
    a_lo, a_hi := selection_range(a)
    b_lo, b_hi := selection_range(b)
    lo, hi := min(a_lo, b_lo), max(a_hi, b_hi)
    reversed := has_selection(b) ? b.caret < b.anchor : a.caret < a.anchor
    out := Cursor {caret = hi, anchor = lo}
    if reversed {
        out = Cursor {caret = lo, anchor = hi}
    }
    out.preferred_column = column(txt, out.caret, tab_width)
    return out
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
            cursor.caret = grapheme_prev(txt, cursor.caret)
        } else if delta > 0 && cursor.caret < len(txt) {
            cursor.caret = grapheme_next(txt, cursor.caret)
        }
        if !extend {
            cursor.anchor = cursor.caret
        }
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
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
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
    }
    normalize_cursors(state)
}

move_vertical :: proc(state: ^State, delta: int, extend: bool) {
    txt := text(state)
    for &cursor in state.cursors {
        start, _ := line_start_relative(txt, cursor.caret, delta)
        cursor.caret = offset_for_column(txt, start, cursor.preferred_column, tab_width(state))
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
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
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
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
    }
    normalize_cursors(state)
}

// Jumps to (or selects up to, with extend) the delimiter matching the one the
// cursor sits in front of. Brackets ()[]{} match by nesting depth and a quote
// matches the other end of its string. A bracket in code does not count the
// brackets in strings and comments.
move_to_matching_bracket :: proc(state: ^State, extend: bool) {
    txt := text(state)
    ranges := skip_ranges(txt, state.lexical)
    for &cursor in state.cursors {
        if bracket_pos, match_pos, forward, found := find_matching_bracket(txt, ranges, cursor.caret); found {
            apply_delimiter_jump(&cursor, txt, bracket_pos, match_pos, forward, extend, tab_width(state))
            continue
        }
        if quote_pos, match_pos, forward, found := find_matching_quote(txt, ranges, cursor.caret); found {
            apply_delimiter_jump(&cursor, txt, quote_pos, match_pos, forward, extend, tab_width(state))
            continue
        }
        if open_pos, close_pos, found := enclosing_pair(txt, ranges, cursor.caret); found {
            if extend {
                cursor.anchor = open_pos
                cursor.caret = close_pos + 1
            } else {
                cursor.caret = open_pos
                cursor.anchor = open_pos
            }
            cursor.preferred_column = cursor_column(state, txt, cursor.caret)
        }
    }
    normalize_cursors(state)
}

// Positions a cursor after find_matching_bracket / find_matching_quote located
// the partner delimiter. `forward` is true when the matched delimiter lies to
// the right of the one under the caret.
@(private)
apply_delimiter_jump :: proc(cursor: ^Cursor, txt: string, delim_pos, match_pos: int, forward, extend: bool, tab_width: int) {
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
    cursor.preferred_column = column(txt, cursor.caret, tab_width)
}

// Selects the text between the innermost bracket pair around the caret,
// excluding the brackets. Works next to a bracket or from inside the pair.
select_between_brackets :: proc(state: ^State) {
    txt := text(state)
    ranges := skip_ranges(txt, state.lexical)
    for &cursor in state.cursors {
        open_pos, close_pos, found := bracket_span_in(txt, ranges, cursor.caret)
        if !found {
            continue
        }
        cursor.anchor = open_pos + 1
        cursor.caret = close_pos
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
    }
    normalize_cursors(state)
}

// Spawns an extra cursor one line above (delta < 0) or below each existing one.
add_cursor_vertical :: proc(state: ^State, delta: int) {
    txt := text(state)
    spawned := make([dynamic]Cursor, context.temp_allocator)
    for cursor in state.cursors {
        start, full := line_start_relative(txt, cursor.caret, delta)
        if !full {
            continue
        }
        pos := offset_for_column(txt, start, cursor.preferred_column, tab_width(state))
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

    // Replacing a selection is its own undo step, and only a single typed
    // character joins a typing run — never a paste or a completion insert.
    coalesce := has_any_selection(state) || !is_single_grapheme(s) ? Coalesce.None : .Typing

    // Cursors are kept sorted; apply low to high, shifting later positions.
    offset := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            table_delete(state, lo + offset, hi - lo)
        }
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(s)})
        table_insert(state, lo + offset, s)
        cursor.caret = lo + offset + len(s)
        cursor.anchor = cursor.caret
        offset += len(s) - (hi - lo)
    }

    finish_edit(state, &entry, coalesce)
}

// True when `s` holds exactly one grapheme cluster, i.e. one keystroke's worth
// of text. A combining mark typed onto a letter is one cluster, not two.
@(private)
is_single_grapheme :: proc(s: string) -> bool {
    if len(s) == 0 {
        return false
    }
    return grapheme_next(s, 0) == len(s)
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
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    ob, ow := utf8.encode_rune(open)
    cbuf, cw := utf8.encode_rune(close)
    open_s := string(ob[:ow])
    close_s := string(cbuf[:cw])

    offset := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        table_insert(state, lo + offset, open_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(open_s)})
        close_pos := hi + offset + ow
        table_insert(state, close_pos, close_s)
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
        if hi == lo && strings.has_prefix(txt[lo:], close_s) {
            cursor.caret = lo + offset + cw
            cursor.anchor = cursor.caret
            continue
        }
        if hi > lo {
            table_delete(state, lo + offset, hi - lo)
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
        }
        table_insert(state, lo + offset, close_s)
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
    edited := false
    for &cursor in state.cursors {
        lo, _ := selection_range(cursor)
        if strings.has_prefix(txt[lo:], q_s) {
            cursor.caret = lo + offset + qw
            cursor.anchor = cursor.caret
            continue
        }
        edited = true
        pair := !(lo > 0 && is_word_byte_ascii(txt[lo - 1]))
        table_insert(state, lo + offset, q_s)
        append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset, text = strings.clone(q_s)})
        if pair {
            table_insert(state, lo + offset + qw, q_s)
            append(&entry.ops, Edit_Op {kind = .Insert, pos = lo + offset + qw, text = strings.clone(q_s)})
        }
        cursor.caret = lo + offset + qw
        cursor.anchor = cursor.caret
        offset += pair ? qw * 2 : qw
    }
    if edited {
        finish_edit(state, &entry)
    } else {
        entry_destroy(&entry)
    }
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
    table_insert(state, lo, "**/")
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

delete_backward :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    // Deleting a selection is its own undo step.
    coalesce := has_any_selection(state) ? Coalesce.None : .Delete_Back

    offset := 0
    changed := false
    // End of the last deleted range, in offsets of `txt`.
    done := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && lo > 0 {
            // Empty auto-pair (e.g. caret between "()"): delete both sides.
            if lo < len(txt) && is_auto_pair_bytes(txt[lo - 1], txt[lo]) {
                lo -= 1
                hi += 1
            } else {
                lo = grapheme_prev(txt, lo)
            }
        }
        // A range must not reach into the one the caret before it deleted.
        lo = max(lo, done)
        hi = max(hi, lo)
        done = hi
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            table_delete(state, lo + offset, hi - lo)
            changed = true
        }
        cursor.caret = lo + offset
        cursor.anchor = cursor.caret
        offset -= hi - lo
    }

    if changed {
        finish_edit(state, &entry, coalesce)
    } else {
        entry_destroy(&entry)
    }
}

delete_forward :: proc(state: ^State) {
    txt := text(state)
    entry := Undo_Entry {cursors_before = clone_cursors(state)}
    // Deleting a selection is its own undo step.
    coalesce := has_any_selection(state) ? Coalesce.None : .Delete_Forward

    offset := 0
    changed := false
    // End of the last deleted range, in offsets of `txt`.
    done := 0
    for &cursor in state.cursors {
        lo, hi := selection_range(cursor)
        if hi == lo && lo < len(txt) {
            hi = grapheme_next(txt, lo)
        }
        lo = max(lo, done)
        hi = max(hi, lo)
        done = hi
        if hi > lo {
            append(&entry.ops, Edit_Op {kind = .Delete, pos = lo + offset, text = strings.clone(txt[lo:hi])})
            table_delete(state, lo + offset, hi - lo)
            changed = true
        }
        cursor.caret = lo + offset
        cursor.anchor = cursor.caret
        offset -= hi - lo
    }

    if changed {
        finish_edit(state, &entry, coalesce)
    } else {
        entry_destroy(&entry)
    }
}

undo :: proc(state: ^State) {
    if state.undo_stack.count == 0 {
        return
    }
    entry := ring_pop(&state.undo_stack)
    state.undo_bytes -= entry_bytes(&entry)
    state.coalescing = false

    #reverse for op in entry.ops {
        switch op.kind {
        case .Insert:
            table_delete(state, op.pos, len(op.text))
        case .Delete:
            table_insert(state, op.pos, op.text)
        }
    }

    clear(&state.cursors)
    for cursor in entry.cursors_before {
        append(&state.cursors, cursor)
    }
    state.content_id = entry.id_before
    append(&state.redo_stack, entry)
    state.revision += 1
    record_change(state, state.revision, entry.ops[:], true)
}

redo :: proc(state: ^State) {
    if len(state.redo_stack) == 0 {
        return
    }
    entry := pop(&state.redo_stack)
    state.undo_bytes += entry_bytes(&entry)
    state.coalescing = false

    for op in entry.ops {
        switch op.kind {
        case .Insert:
            table_insert(state, op.pos, op.text)
        case .Delete:
            table_delete(state, op.pos, len(op.text))
        }
    }

    clear(&state.cursors)
    for cursor in entry.cursors_after {
        append(&state.cursors, cursor)
    }
    state.content_id = entry.id_after
    ring_push(&state.undo_stack, entry)
    state.revision += 1
    record_change(state, state.revision, entry.ops[:])
}

// Folds the newest undo entry into the one below it, so one undo takes both
// back. For an edit that only follows from the edit before it.
join_last_undo :: proc(state: ^State) {
    if state.undo_stack.count < 2 {
        return
    }
    top := ring_pop(&state.undo_stack)
    prev := ring_at(&state.undo_stack, state.undo_stack.count - 1)
    append(&prev.ops, ..top.ops[:])
    delete(top.ops)
    delete(top.cursors_before)
    delete(prev.cursors_after)
    prev.cursors_after = top.cursors_after
    prev.id_after = top.id_after
    prev.coalesce = .None
    state.coalescing = false
}

@(private)
finish_edit :: proc(state: ^State, entry: ^Undo_Entry, coalesce := Coalesce.None) {
    txt := text(state)
    for &cursor in state.cursors {
        cursor.preferred_column = cursor_column(state, txt, cursor.caret)
    }
    normalize_cursors(state)
    entry.cursors_after = clone_cursors(state)
    entry.coalesce = coalesce
    entry.id_before = state.content_id
    entry.id_after = state.revision + 1
    record_change(state, state.revision + 1, entry.ops[:])

    clear_entries(&state.redo_stack)
    if !coalesce_into_previous(state, entry) {
        state.undo_bytes += entry_bytes(entry)
        ring_push(&state.undo_stack, entry^)
    }
    trim_undo_history(state)
    state.coalescing = coalesce != .None
    state.revision += 1
    state.content_id = state.revision
}

@(private)
entry_bytes :: proc(entry: ^Undo_Entry) -> int {
    total := 0
    for op in entry.ops {
        total += len(op.text)
    }
    return total
}

@(private)
trim_undo_history :: proc(state: ^State) {
    for state.undo_stack.count > 1 &&
        (state.undo_stack.count > MAX_UNDO_ENTRIES || state.undo_bytes > MAX_UNDO_BYTES) {
        oldest := ring_at(&state.undo_stack, 0)
        state.undo_bytes -= entry_bytes(oldest)
        entry_destroy(oldest)
        ring_drop_front(&state.undo_stack)
    }
}

// Character classes that keep a coalescing run going: a typed letter joins the
// word so far and a space the run of spaces, while punctuation and newlines
// always start a fresh undo step.
@(private)
Run_Class :: enum {
    Word,
    Space,
    Other,
}

@(private)
run_class :: proc(r: rune) -> Run_Class {
    switch {
    case is_word_rune(r):
        return .Word
    case r == ' ' || r == '\t':
        return .Space
    }
    return .Other
}

// True when `next` continues the run `run` belongs to, the two being adjacent
// in the buffer in that order.
@(private)
same_run :: proc(run, next: string) -> bool {
    if len(run) == 0 || len(next) == 0 {
        return false
    }
    last, _ := utf8.decode_last_rune_in_string(run)
    first, _ := utf8.decode_rune_in_string(next)
    class := run_class(last)
    return class != .Other && class == run_class(first)
}

@(private)
join_op_text :: proc(first, second: string) -> string {
    joined := strings.concatenate({first, second})
    delete(first)
    delete(second)
    return joined
}

// Folds `entry` into the top undo entry when both are consecutive keystrokes of
// the same kind, and reports the merge. The ops must line up one for one, each
// continuing the run of its partner: for typing, after it; for a delete, before.
@(private)
coalesce_into_previous :: proc(state: ^State, entry: ^Undo_Entry) -> bool {
    if !state.coalescing || entry.coalesce == .None || state.undo_stack.count == 0 {
        return false
    }
    prev := ring_at(&state.undo_stack, state.undo_stack.count - 1)
    if prev.coalesce != entry.coalesce || len(prev.ops) != len(entry.ops) || len(entry.ops) == 0 {
        return false
    }

    // Bytes the already-merged ops add ahead of this one, which move the
    // positions recorded against the older entry.
    shift := 0
    for op, i in entry.ops {
        old := prev.ops[i]
        if old.kind != op.kind {
            return false
        }
        expected: int
        continues: bool
        switch entry.coalesce {
        case .None:
            return false
        case .Typing:
            expected = old.pos + len(old.text) + shift
            continues = same_run(old.text, op.text)
        case .Delete_Back:
            expected = old.pos - len(op.text) - shift
            continues = same_run(op.text, old.text)
        case .Delete_Forward:
            expected = old.pos - shift
            continues = same_run(old.text, op.text)
        }
        if op.pos != expected || !continues {
            return false
        }
        shift += len(op.text)
    }

    shift = 0
    for op, i in entry.ops {
        old := &prev.ops[i]
        switch entry.coalesce {
        case .None:
        case .Typing:
            old.pos += shift
            old.text = join_op_text(old.text, op.text)
        case .Delete_Back:
            old.pos = op.pos
            old.text = join_op_text(op.text, old.text)
        case .Delete_Forward:
            old.pos = op.pos
            old.text = join_op_text(old.text, op.text)
        }
        shift += len(op.text)
    }
    state.undo_bytes += shift

    prev.id_after = entry.id_after
    delete(prev.cursors_after)
    prev.cursors_after = entry.cursors_after
    entry.cursors_after = nil
    delete(entry.cursors_before)
    entry.cursors_before = nil
    delete(entry.ops) // the op texts were consumed by the merge above
    entry.ops = nil
    return true
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

// The entry `i` places after the oldest one.
@(private)
ring_at :: proc(ring: ^Undo_Ring, i: int) -> ^Undo_Entry {
    return &ring.entries[(ring.start + i) % len(ring.entries)]
}

@(private)
ring_push :: proc(ring: ^Undo_Ring, entry: Undo_Entry) {
    if ring.count == len(ring.entries) {
        ring_grow(ring)
    }
    ring.entries[(ring.start + ring.count) % len(ring.entries)] = entry
    ring.count += 1
}

// Takes the newest entry, for undo.
@(private)
ring_pop :: proc(ring: ^Undo_Ring) -> Undo_Entry {
    ring.count -= 1
    return ring_at(ring, ring.count)^
}

// Drops the oldest entry. The caller destroys it first; only the bounds move.
@(private)
ring_drop_front :: proc(ring: ^Undo_Ring) {
    ring.start = (ring.start + 1) % len(ring.entries)
    ring.count -= 1
}

// Doubles the backing and puts the entries back in order from slot 0. The
// entries are moved as values, so the op text stays where it is.
@(private)
ring_grow :: proc(ring: ^Undo_Ring) {
    grown := make([dynamic]Undo_Entry, max(len(ring.entries) * 2, 16))
    for i in 0 ..< ring.count {
        grown[i] = ring_at(ring, i)^
    }
    delete(ring.entries)
    ring.entries = grown
    ring.start = 0
}

@(private)
ring_clear :: proc(ring: ^Undo_Ring) {
    for i in 0 ..< ring.count {
        entry_destroy(ring_at(ring, i))
    }
    ring.start = 0
    ring.count = 0
}

@(private)
ring_destroy :: proc(ring: ^Undo_Ring) {
    ring_clear(ring)
    delete(ring.entries)
    ring.entries = nil
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

// The line table, brought up to date when the content changed since the last query. Main
// thread only: it writes to the state.
@(private)
line_table :: proc(state: ^State) -> []int {
    if state.lines_valid && state.lines_revision == state.revision {
        return state.lines[:]
    }

    txt := text(state)
    if change, ok := changes_since(state, state.lines_revision); state.lines_valid && ok {
        patch_line_table(state, txt, change)
        state.lines_revision = state.revision
        return state.lines[:]
    }
    clear(&state.lines)
    append(&state.lines, 0)
    for i in 0 ..< len(txt) {
        if txt[i] == '\n' {
            append(&state.lines, i + 1)
        }
    }
    state.lines_revision = state.revision
    state.lines_valid = true
    return state.lines[:]
}

// Moves the line table through `change`: drops the starts it replaced, shifts the
// ones after it and adds the starts of the new text `txt[lo:new_hi]`.
@(private)
patch_line_table :: proc(state: ^State, txt: string, change: Change) {
    lines := &state.lines
    // First start after lo, and first start after old_hi.
    first := first_line_after(lines[:], change.lo)
    last := first_line_after(lines[:], change.old_hi)
    delta := change.new_hi - change.old_hi
    for i in last ..< len(lines) {
        lines[i] += delta
    }
    remove_range(lines, first, last)
    added := make([dynamic]int, 0, 16, context.temp_allocator)
    for i in change.lo ..< change.new_hi {
        if txt[i] == '\n' {
            append(&added, i + 1)
        }
    }
    inject_at(lines, first, ..added[:])
}

// Index of the first entry of the sorted `lines` that is greater than `pos`.
@(private)
first_line_after :: proc(lines: []int, pos: int) -> int {
    lo, hi := 0, len(lines)
    for lo < hi {
        mid := lo + (hi - lo) / 2
        if lines[mid] <= pos {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

// Zero-based index of the line holding `pos`, over the line table. Same result as
// line_index, without the scan.
state_line_index :: proc(state: ^State, pos: int) -> int {
    lines := line_table(state)
    // The last line that starts at or before `pos`.
    lo, hi := 0, len(lines) - 1
    for lo < hi {
        mid := (lo + hi + 1) / 2
        if lines[mid] <= pos {
            lo = mid
        } else {
            hi = mid - 1
        }
    }
    return lo
}

// Start byte of the given line index, clamped to the last line.
state_line_start :: proc(state: ^State, line: int) -> int {
    lines := line_table(state)
    return lines[clamp(line, 0, len(lines) - 1)]
}

state_line_count :: proc(state: ^State) -> int {
    return len(line_table(state))
}

// Start byte of the line `delta` lines from the one holding `pos`, clamped to
// the first and last line. `full` is false when the clamp stopped it short.
// Walks only the lines it crosses, unlike line_index + line_start_of_index,
// which both scan from byte 0.
line_start_relative :: proc(txt: string, pos: int, delta: int) -> (start: int, full: bool) {
    start = line_start(txt, pos)
    for _ in 0 ..< abs(delta) {
        if delta < 0 {
            if start == 0 {
                return start, false
            }
            start = line_start(txt, start - 1)
            continue
        }
        end := line_end(txt, start)
        if end >= len(txt) {
            return start, false
        }
        start = end + 1
    }
    return start, true
}

// Bytes scanned back to find a cluster start. A cluster longer than this
// degrades to one rune, never to a partial rune.
@(private)
GRAPHEME_BACKSCAN :: 64

// Byte offset of the grapheme-cluster boundary after `pos`.
grapheme_next :: proc(txt: string, pos: int) -> int {
    if pos >= len(txt) {
        return len(txt)
    }
    it := utf8.decode_grapheme_iterator_make(txt[pos:])
    // The first boundary is always 0; the second one ends this cluster. Only
    // `byte_index` is usable: the iterator's `text` is sliced by display cells.
    _, _, ok := utf8.decode_grapheme_iterate(&it)
    if !ok {
        return len(txt)
    }
    _, next, more := utf8.decode_grapheme_iterate(&it)
    return more ? pos + next.byte_index : len(txt)
}

// Byte offset of the grapheme-cluster boundary before `pos`. Scans a bounded
// window instead of the whole prefix, so a keystroke stays O(1).
grapheme_prev :: proc(txt: string, pos: int) -> int {
    if pos <= 0 {
        return 0
    }
    from := max(0, pos - GRAPHEME_BACKSCAN)
    // A window opening mid-rune would mis-segment.
    for from < pos && txt[from] & 0xC0 == 0x80 {
        from += 1
    }

    best := from
    it := utf8.decode_grapheme_iterator_make(txt[from:pos])
    for {
        _, cluster, ok := utf8.decode_grapheme_iterate(&it)
        if !ok {
            break
        }
        best = from + cluster.byte_index
    }
    return best
}

// Cells a rune takes in a monospace row: 2 for East Asian wide and fullwidth
// forms and for emoji, else 1.
rune_cells :: proc(r: rune) -> int {
    switch r {
    case 0x1100 ..= 0x115F, 0x2E80 ..= 0x303E, 0x3041 ..= 0x33FF, 0x3400 ..= 0x4DBF, 0x4E00 ..= 0x9FFF,
         0xA000 ..= 0xA4CF, 0xAC00 ..= 0xD7A3, 0xF900 ..= 0xFAFF, 0xFE30 ..= 0xFE4F, 0xFF00 ..= 0xFF60,
         0xFFE0 ..= 0xFFE6, 0x1F300 ..= 0x1F64F, 0x1F680 ..= 0x1F6FF, 0x1F900 ..= 0x1F9FF,
         0x20000 ..= 0x3FFFD:
        return 2
    }
    return 1
}

// Display columns spanned by `s` counted from column 0: a tab advances to the
// next multiple of tab_width, every other grapheme cluster counts one. Stops at
// a newline. An ASCII run is stepped by byte, but only while the next byte is
// ASCII too, since a combining mark would join the cluster before it.
display_width :: proc(s: string, tab_width: int) -> int {
    width := max(tab_width, 1)
    col := 0
    for i := 0; i < len(s); {
        b := s[i]
        switch {
        case b == '\n':
            return col
        case b == '\t':
            col += width - (col % width)
            i += 1
        case b < 0x80 && (i + 1 >= len(s) || s[i + 1] < 0x80):
            col += 1
            i += 1
        case:
            i = grapheme_next(s, i)
            col += 1
        }
    }
    return col
}

// Byte offset at display column `col` in `s`, never past it: a tab straddling
// `col` is not entered, so the offset lands before it. Stops at a newline.
display_offset :: proc(s: string, col: int, tab_width: int) -> int {
    width := max(tab_width, 1)
    current := 0
    i := 0
    for i < len(s) && current < col {
        b := s[i]
        if b == '\n' {
            break
        }
        next, step := current + 1, 1
        switch {
        case b == '\t':
            next = current + width - (current % width)
        case b < 0x80 && (i + 1 >= len(s) || s[i + 1] < 0x80):
        case:
            step = grapheme_next(s, i) - i
        }
        if next > col {
            break // only a tab overshoots, and it is not entered
        }
        current = next
        i += step
    }
    return i
}

// Display column of `pos` at the document's tab width.
@(private)
cursor_column :: proc(state: ^State, txt: string, pos: int) -> int {
    return column(txt, pos, tab_width(state))
}

// Display column of `pos` within its line.
column :: proc(txt: string, pos: int, tab_width: int) -> int {
    return display_width(txt[line_start(txt, pos):pos], tab_width)
}

// Byte offset at display column `col` in the line starting at `start`, clamped
// to the end of that line.
offset_for_column :: proc(txt: string, start: int, col: int, tab_width: int) -> int {
    return start + display_offset(txt[start:], col, tab_width)
}

// A letter, a number, a combining mark or `_`.
@(private)
is_word_rune :: proc(r: rune) -> bool {
    if r < 0x80 {
        return is_word_byte_ascii(u8(r))
    }
    return unicode.is_letter(r) || unicode.is_number(r) || unicode.is_combining(r)
}

// Whether the rune at `pos` is a word rune, and its byte width.
@(private)
word_rune_after :: proc(txt: string, pos: int) -> (bool, int) {
    if txt[pos] < 0x80 {
        return is_word_byte_ascii(txt[pos]), 1
    }
    r, width := utf8.decode_rune_in_string(txt[pos:])
    return is_word_rune(r), width
}

// Whether the rune that ends at `pos` is a word rune, and its byte width.
@(private)
word_rune_before :: proc(txt: string, pos: int) -> (bool, int) {
    if txt[pos - 1] < 0x80 {
        return is_word_byte_ascii(txt[pos - 1]), 1
    }
    r, width := utf8.decode_last_rune_in_string(txt[:pos])
    return is_word_rune(r), width
}

// True when [start, end) is not glued to a word character, tested only on the
// sides where the span's own edge is one. A span ending in punctuation is not
// rejected for what follows it.
@(private)
word_bounded :: proc(txt: string, start, end: int) -> bool {
    if end <= start {
        return true
    }
    if first, _ := word_rune_after(txt, start); first && start > 0 {
        if before, _ := word_rune_before(txt, start); before {
            return false
        }
    }
    if last, _ := word_rune_before(txt, end); last && end < len(txt) {
        if after, _ := word_rune_after(txt, end); after {
            return false
        }
    }
    return true
}

// The end of the run of word runes from `pos`.
@(private)
word_run_end :: proc(txt: string, pos: int) -> int {
    p := pos
    for p < len(txt) {
        word, width := word_rune_after(txt, p)
        if !word {
            break
        }
        p += width
    }
    return p
}

// The start of the run of word runes that ends at `pos`.
@(private)
word_run_start :: proc(txt: string, pos: int) -> int {
    p := pos
    for p > 0 {
        word, width := word_rune_before(txt, p)
        if !word {
            break
        }
        p -= width
    }
    return p
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
    if p >= len(txt) {
        return p
    }
    if word, _ := word_rune_after(txt, p); word {
        return word_run_end(txt, p)
    }
    for p < len(txt) && !is_space_byte(txt[p]) && txt[p] != '\n' {
        word, width := word_rune_after(txt, p)
        if word {
            break
        }
        p += width
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
    if p <= 0 {
        return 0
    }
    if word, _ := word_rune_before(txt, p); word {
        return word_run_start(txt, p)
    }
    for p > 0 && !is_space_byte(txt[p - 1]) && txt[p - 1] != '\n' {
        word, width := word_rune_before(txt, p)
        if word {
            break
        }
        p -= width
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
