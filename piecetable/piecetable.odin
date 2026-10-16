package piecetable

import "core:strings"

Piece_Source :: enum {
    Original,
    Add,
}

Piece :: struct {
    source: Piece_Source,
    start:  int,
    length: int,
}

// One edit not yet applied to the snapshot. The inserted bytes are read from
// the add buffer.
@(private)
Pending_Op :: struct {
    pos:       int,
    add_start: int,
    length:    int,
    insert:    bool,
}

// Edits kept for an in-place patch of the snapshot; more make a full rebuild.
MAX_PENDING :: 8

Piece_Table :: struct {
    original: string,         // owned
    add:      [dynamic]u8,    // owned
    pieces:   [dynamic]Piece, // owned
    // Total bytes, maintained by the edits so a length query walks nothing.
    length:   int,
    // The contents as one buffer, brought up to date by piecetable_view on the
    // first read after an edit: patched in place from `pending`, or rebuilt.
    snapshot: [dynamic]u8, // owned
    stale:    bool,        // snapshot must be rebuilt before it is read
    // Edits since the last read, applied in place to the valid snapshot.
    pending:  [dynamic]Pending_Op, // owned
    // Piece index and start offset of the last split, where the next scan starts; -1 when unset.
    hint_index:  int,
    hint_offset: int,
}

piecetable_create :: proc(initial_text: string = "") -> Piece_Table {
    pt := Piece_Table {
        original = strings.clone(initial_text),
        length   = len(initial_text),
        stale    = true,
    }
    if len(pt.original) > 0 {
        append(&pt.pieces, Piece {source = .Original, start = 0, length = len(pt.original)})
    }
    return pt
}

piecetable_destroy :: proc(pt: ^Piece_Table) {
    delete(pt.original)
    delete(pt.add)
    delete(pt.pieces)
    delete(pt.snapshot)
    delete(pt.pending)
}

piecetable_length :: proc(pt: ^Piece_Table) -> int {
    return pt.length
}

// Replaces the contents with `text`. The new table is built first, because
// `text` can borrow this table's own snapshot, which the destroy frees.
piecetable_set_text :: proc(pt: ^Piece_Table, text: string) {
    fresh := piecetable_create(text)
    piecetable_destroy(pt)
    pt^ = fresh
}

// Splits the piece containing `pos` unless it is on a boundary, and returns the
// index of the piece starting there. Clamps `pos`; scans from the hint when it is at or before `pos`.
@(private)
piecetable_split_at :: proc(pt: ^Piece_Table, pos: int) -> int {
    if pos <= 0 {
        piecetable_set_hint(pt, 0, 0)
        return 0
    }
    if pos >= pt.length {
        // pos may be a caller's out-of-range value rather than the true end,
        // so the resulting index has no offset worth resuming from.
        piecetable_set_hint(pt, -1, 0)
        return len(pt.pieces)
    }

    i, offset := 0, 0
    if pt.hint_index >= 0 && pt.hint_index <= len(pt.pieces) && pt.hint_offset <= pos {
        i, offset = pt.hint_index, pt.hint_offset
    }

    for ; i < len(pt.pieces); i += 1 {
        piece := pt.pieces[i]
        if pos == offset {
            piecetable_set_hint(pt, i, offset)
            return i
        }
        if pos < offset + piece.length {
            local := pos - offset
            left := Piece {source = piece.source, start = piece.start, length = local}
            right := Piece {source = piece.source, start = piece.start + local, length = piece.length - local}
            pt.pieces[i] = left
            inject_at(&pt.pieces, i + 1, right)
            piecetable_set_hint(pt, i + 1, pos)
            return i + 1
        }
        offset += piece.length
    }
    piecetable_set_hint(pt, -1, 0)
    return len(pt.pieces)
}

// Records where the next split_at may resume scanning from.
@(private)
piecetable_set_hint :: proc(pt: ^Piece_Table, index, offset: int) {
    pt.hint_index = index
    pt.hint_offset = offset
}

// Joins pieces[i - 1] and pieces[i] when they are adjacent runs of the same buffer.
@(private)
piecetable_merge_at :: proc(pt: ^Piece_Table, i: int) {
    if i <= 0 || i >= len(pt.pieces) {
        return
    }
    prev := pt.pieces[i - 1]
    next := pt.pieces[i]
    if prev.source != next.source || prev.start + prev.length != next.start {
        return
    }
    pt.pieces[i - 1].length += next.length
    ordered_remove(&pt.pieces, i)
}

// Why a checked edit did nothing.
Error :: enum {
    None,
    Out_Of_Range,
}

// True when `pos` can start an edit: 0 <= pos <= length. The end is included,
// because an insert appends there.
piecetable_valid_offset :: proc(pt: ^Piece_Table, pos: int) -> bool {
    return pos >= 0 && pos <= pt.length
}

// True when `count` bytes from `pos` stay inside the buffer. Overflow-safe.
piecetable_valid_range :: proc(pt: ^Piece_Table, pos, count: int) -> bool {
    return pos >= 0 && count >= 0 && pos <= pt.length && count <= pt.length - pos
}

// Inserts `text` at `pos`. An out-of-range `pos` is clamped; use
// piecetable_insert_checked for an offset from outside.
piecetable_insert :: proc(pt: ^Piece_Table, pos: int, text: string) {
    if len(text) == 0 {
        return
    }

    add_start := len(pt.add)
    append(&pt.add, text)
    piecetable_note_edit(pt, Pending_Op {pos = clamp(pos, 0, pt.length), add_start = add_start, length = len(text), insert = true})

    // Split before the length grows, or an append misses the end-of-buffer fast path.
    index := piecetable_split_at(pt, pos)
    pt.length += len(text)
    // The split's own hint is the true offset it landed on (pos itself may be
    // an out-of-range value split_at only clamped), so extend from that.
    at_split := pt.hint_index == index
    // Sequential typing lands at the end of the piece written by the previous
    // insert; extend it rather than adding another.
    if index > 0 {
        prev := &pt.pieces[index - 1]
        if prev.source == .Add && prev.start + prev.length == add_start {
            prev.length += len(text)
            if at_split {
                pt.hint_offset += len(text)
            }
            return
        }
    }
    inject_at(&pt.pieces, index, Piece {source = .Add, start = add_start, length = len(text)})
    if at_split {
        piecetable_set_hint(pt, index + 1, pt.hint_offset + len(text))
    }
}

// Deletes `delete_length` bytes at `pos`. The range must satisfy
// piecetable_valid_range; a range that leaves the buffer removes only the part
// inside it. Use piecetable_delete_checked for a caller-supplied range.
piecetable_delete :: proc(pt: ^Piece_Table, pos: int, delete_length: int) {
    if delete_length <= 0 {
        return
    }

    start_index := piecetable_split_at(pt, pos)
    // The split's own hint is the true offset it landed on (pos itself may be
    // an out-of-range value split_at only clamped); the second split below
    // overwrites the hint, so capture it now.
    start_at_split := pt.hint_index == start_index
    start_offset := pt.hint_offset
    end_index := piecetable_split_at(pt, pos + delete_length)
    // A range past the end removes less than asked, so count what really goes.
    removed := 0
    for i in start_index ..< end_index {
        removed += pt.pieces[i].length
    }
    pt.length -= removed
    if removed > 0 {
        piecetable_note_edit(pt, Pending_Op {pos = clamp(pos, 0, pt.length + removed), length = removed})
    }
    remove_range(&pt.pieces, start_index, end_index)
    before := len(pt.pieces)
    // Removing the span can leave two runs of one buffer touching again.
    piecetable_merge_at(pt, start_index)
    if start_at_split && len(pt.pieces) == before {
        // No merge: pieces[start_index] still starts exactly at start_offset.
        piecetable_set_hint(pt, start_index, start_offset)
    } else {
        // The merge folded the boundary into one piece, or the start itself
        // was clamped; the next split must rescan from the top.
        piecetable_set_hint(pt, -1, 0)
    }
}

// Bounds-checked piecetable_insert: an out-of-range `pos` changes nothing and
// reports .Out_Of_Range.
@(require_results)
piecetable_insert_checked :: proc(pt: ^Piece_Table, pos: int, text: string) -> Error {
    if !piecetable_valid_offset(pt, pos) {
        return .Out_Of_Range
    }
    piecetable_insert(pt, pos, text)
    return .None
}

// Bounds-checked piecetable_delete: a range that leaves the buffer, or a
// negative one, changes nothing and reports .Out_Of_Range.
@(require_results)
piecetable_delete_checked :: proc(pt: ^Piece_Table, pos: int, delete_length: int) -> Error {
    if !piecetable_valid_range(pt, pos, delete_length) {
        return .Out_Of_Range
    }
    piecetable_delete(pt, pos, delete_length)
    return .None
}

// Queues an edit for the snapshot, or marks it for a full rebuild.
@(private)
piecetable_note_edit :: proc(pt: ^Piece_Table, op: Pending_Op) {
    if pt.stale {
        return
    }
    if len(pt.pending) >= MAX_PENDING {
        pt.stale = true
        clear(&pt.pending)
        return
    }
    append(&pt.pending, op)
}

@(private)
piecetable_piece_bytes :: proc(pt: ^Piece_Table, piece: Piece) -> string {
    switch piece.source {
    case .Original:
        return pt.original
    case .Add:
        return string(pt.add[:])
    }
    return ""
}

// The full contents as one string, borrowed from the table. Valid until the
// first read that follows an edit — that read rebuilds the snapshot in place.
// Callers that keep the text across an edit need piecetable_to_string.
piecetable_view :: proc(pt: ^Piece_Table) -> string {
    if pt.stale {
        clear(&pt.snapshot)
        reserve(&pt.snapshot, pt.length)
        for piece in pt.pieces {
            buffer := piecetable_piece_bytes(pt, piece)
            append(&pt.snapshot, buffer[piece.start:piece.start + piece.length])
        }
        pt.stale = false
        clear(&pt.pending)
    } else if len(pt.pending) > 0 {
        for op in pt.pending {
            if op.insert {
                inject_at(&pt.snapshot, op.pos, ..pt.add[op.add_start:op.add_start + op.length])
            } else {
                remove_range(&pt.snapshot, op.pos, op.pos + op.length)
            }
        }
        clear(&pt.pending)
    }
    return string(pt.snapshot[:])
}

// Materializes the full contents as a single string using the given allocator.
piecetable_to_string :: proc(pt: ^Piece_Table, allocator := context.allocator) -> string {
    return strings.clone(piecetable_view(pt), allocator)
}
