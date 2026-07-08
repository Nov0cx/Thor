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
}

piecetable_create :: proc(initial_text: string = "") -> Piece_Table {
    pt := Piece_Table {
        original = strings.clone(initial_text),
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
}

piecetable_length :: proc(pt: ^Piece_Table) -> int {
    total := 0
    for piece in pt.pieces {
        total += piece.length
    }
    return total
}

piecetable_set_text :: proc(pt: ^Piece_Table, text: string) {
    piecetable_destroy(pt)
    pt^ = piecetable_create(text)
}

// Splits the piece containing `pos` (if `pos` doesn't already fall on a
// boundary) and returns the index of the piece that starts at `pos`.
@(private)
piecetable_split_at :: proc(pt: ^Piece_Table, pos: int) -> int {
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

piecetable_insert :: proc(pt: ^Piece_Table, pos: int, text: string) {
    if len(text) == 0 {
        return
    }

    add_start := len(pt.add)
    for i := 0; i < len(text); i += 1 {
        append(&pt.add, text[i])
    }

    index := piecetable_split_at(pt, pos)
    inject_at(&pt.pieces, index, Piece {source = .Add, start = add_start, length = len(text)})
}

piecetable_delete :: proc(pt: ^Piece_Table, pos: int, delete_length: int) {
    if delete_length <= 0 {
        return
    }

    start_index := piecetable_split_at(pt, pos)
    end_index := piecetable_split_at(pt, pos + delete_length)
    remove_range(&pt.pieces, start_index, end_index)
}

piecetable_clear :: proc(pt: ^Piece_Table) {
    piecetable_delete(pt, 0, piecetable_length(pt))
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

// Materializes the full contents as a single string using the given allocator.
piecetable_to_string :: proc(pt: ^Piece_Table, allocator := context.allocator) -> string {
    builder := strings.builder_make(allocator)
    for piece in pt.pieces {
        buffer := piecetable_piece_bytes(pt, piece)
        strings.write_string(&builder, buffer[piece.start:piece.start + piece.length])
    }
    return strings.to_string(builder)
}

Piece_Table_Iterator :: struct {
    pt:          ^Piece_Table,
    piece_index: int,
    offset:      int,
}

piecetable_iterator :: proc(pt: ^Piece_Table) -> Piece_Table_Iterator {
    return Piece_Table_Iterator {pt = pt}
}

piecetable_iterator_next :: proc(it: ^Piece_Table_Iterator) -> (byte_value: u8, ok: bool) {
    for it.piece_index < len(it.pt.pieces) {
        piece := it.pt.pieces[it.piece_index]
        if it.offset >= piece.length {
            it.piece_index += 1
            it.offset = 0
            continue
        }

        buffer := piecetable_piece_bytes(it.pt, piece)
        byte_value = buffer[piece.start + it.offset]
        it.offset += 1
        return byte_value, true
    }
    return 0, false
}
