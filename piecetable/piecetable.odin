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

Piece_Table :: struct {
    original: string,
    add:      [dynamic]u8,
    pieces:   [dynamic]Piece,
    // Total bytes, maintained by the edits so a length query walks nothing.
    length:   int,
    // The contents as one buffer, rebuilt by piecetable_view on the first read
    // after an edit. Readers want the whole text far more often than the table
    // changes, so it is materialized once per edit instead of once per read.
    snapshot: [dynamic]u8, // owned
    stale:    bool,        // snapshot must be rebuilt before it is read
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
}

piecetable_length :: proc(pt: ^Piece_Table) -> int {
    return pt.length
}

piecetable_set_text :: proc(pt: ^Piece_Table, text: string) {
    piecetable_destroy(pt)
    pt^ = piecetable_create(text)
}

// Splits the piece containing `pos` (if `pos` doesn't already fall on a
// boundary) and returns the index of the piece that starts at `pos`.
// A `pos` out of range clamps to the first or the last index; a negative one
// must not reach the split, which would write a piece of negative length.
@(private)
piecetable_split_at :: proc(pt: ^Piece_Table, pos: int) -> int {
    if pos <= 0 {
        return 0
    }
    if pos >= pt.length {
        return len(pt.pieces)
    }

    offset := 0
    for i := 0; i < len(pt.pieces); i += 1 {
        piece := pt.pieces[i]
        if pos == offset {
            return i
        }
        if pos < offset + piece.length {
            local := pos - offset
            left := Piece {source = piece.source, start = piece.start, length = local}
            right := Piece {source = piece.source, start = piece.start + local, length = piece.length - local}
            pt.pieces[i] = left
            inject_at(&pt.pieces, i + 1, right)
            return i + 1
        }
        offset += piece.length
    }
    return len(pt.pieces)
}

// Joins pieces[i - 1] and pieces[i] when they are neighbouring runs of the same
// backing buffer. Without this the list grows by one entry per keystroke, and
// every length query and materialization walks it.
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

piecetable_insert :: proc(pt: ^Piece_Table, pos: int, text: string) {
    if len(text) == 0 {
        return
    }

    add_start := len(pt.add)
    append(&pt.add, text)
    pt.length += len(text)
    pt.stale = true

    index := piecetable_split_at(pt, pos)
    // Sequential typing lands at the end of the piece written by the previous
    // insert; extend it rather than adding another.
    if index > 0 {
        prev := &pt.pieces[index - 1]
        if prev.source == .Add && prev.start + prev.length == add_start {
            prev.length += len(text)
            return
        }
    }
    inject_at(&pt.pieces, index, Piece {source = .Add, start = add_start, length = len(text)})
}

piecetable_delete :: proc(pt: ^Piece_Table, pos: int, delete_length: int) {
    if delete_length <= 0 {
        return
    }

    start_index := piecetable_split_at(pt, pos)
    end_index := piecetable_split_at(pt, pos + delete_length)
    // A range past the end removes less than asked, so count what really goes.
    for i in start_index ..< end_index {
        pt.length -= pt.pieces[i].length
    }
    pt.stale = true
    remove_range(&pt.pieces, start_index, end_index)
    // Removing the span can leave two runs of one buffer touching again.
    piecetable_merge_at(pt, start_index)
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
    }
    return string(pt.snapshot[:])
}

// Materializes the full contents as a single string using the given allocator.
piecetable_to_string :: proc(pt: ^Piece_Table, allocator := context.allocator) -> string {
    return strings.clone(piecetable_view(pt), allocator)
}
