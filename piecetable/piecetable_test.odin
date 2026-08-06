package piecetable

import "core:testing"

@(test)
test_insert_and_delete :: proc(t: ^testing.T) {
    pt := piecetable_create("hello world")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, 5, ",")
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "hello, world")
    testing.expect_value(t, piecetable_length(&pt), 12)

    piecetable_delete(&pt, 0, 7)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "world")
    testing.expect_value(t, piecetable_length(&pt), 5)
}

// Typing character by character must not add a piece per keystroke.
@(test)
test_sequential_insert_compacts :: proc(t: ^testing.T) {
    pt := piecetable_create()
    defer piecetable_destroy(&pt)

    word := "compaction"
    for i in 0 ..< len(word) {
        piecetable_insert(&pt, i, word[i:i + 1])
    }

    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), word)
    testing.expect_value(t, len(pt.pieces), 1)
}

// Typing at the front of existing text is contiguous in the add buffer too.
@(test)
test_sequential_insert_into_original :: proc(t: ^testing.T) {
    pt := piecetable_create("tail")
    defer piecetable_destroy(&pt)

    head := "abc"
    for i in 0 ..< len(head) {
        piecetable_insert(&pt, i, head[i:i + 1])
    }

    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "abctail")
    testing.expect_value(t, len(pt.pieces), 2) // the typed run, then the original
}

// A non-contiguous insert stays its own piece: the caret moved back, so the new
// text does not follow the previous run in either the document or the add buffer.
@(test)
test_insert_elsewhere_does_not_merge :: proc(t: ^testing.T) {
    pt := piecetable_create("ac")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, 2, "d")
    piecetable_insert(&pt, 1, "b")
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "abcd")
    testing.expect_value(t, len(pt.pieces), 4)
}

// Removing an inserted run rejoins the halves of the piece it had split.
@(test)
test_delete_rejoins_pieces :: proc(t: ^testing.T) {
    pt := piecetable_create("abcdef")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, 3, "XYZ")
    testing.expect_value(t, len(pt.pieces), 3)

    piecetable_delete(&pt, 3, 3)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "abcdef")
    testing.expect_value(t, len(pt.pieces), 1)
}

// The halves either side of a deletion are not adjacent in the backing buffer,
// so they must stay separate pieces.
@(test)
test_delete_does_not_fuse_disjoint_pieces :: proc(t: ^testing.T) {
    pt := piecetable_create("abcXYZdef")
    defer piecetable_destroy(&pt)

    piecetable_delete(&pt, 3, 3)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "abcdef")
    testing.expect_value(t, len(pt.pieces), 2)
}

// Backspacing over a typed run shrinks it back to nothing without leaving
// stragglers behind.
@(test)
test_type_then_backspace :: proc(t: ^testing.T) {
    pt := piecetable_create("()")
    defer piecetable_destroy(&pt)

    word := "abc"
    for i in 0 ..< len(word) {
        piecetable_insert(&pt, 1 + i, word[i:i + 1])
    }
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "(abc)")

    for i := 0; i < 3; i += 1 {
        piecetable_delete(&pt, piecetable_length(&pt) - 2, 1)
    }
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "()")
    testing.expect_value(t, len(pt.pieces), 1)
}

// The snapshot is rebuilt on the first read after each edit, and only then.
@(test)
test_view_tracks_edits :: proc(t: ^testing.T) {
    pt := piecetable_create("hello world")
    defer piecetable_destroy(&pt)

    testing.expect_value(t, piecetable_view(&pt), "hello world")
    testing.expect(t, !pt.stale, "a read must leave the snapshot fresh")

    piecetable_insert(&pt, 5, ",")
    testing.expect(t, pt.stale, "an insert must stale the snapshot")
    testing.expect_value(t, piecetable_view(&pt), "hello, world")

    piecetable_delete(&pt, 0, 7)
    testing.expect(t, pt.stale, "a delete must stale the snapshot")
    testing.expect_value(t, piecetable_view(&pt), "world")

    piecetable_set_text(&pt, "replaced")
    testing.expect_value(t, piecetable_view(&pt), "replaced")
}

// Repeated reads of an unchanged table hand back the same buffer, so navigating
// a document costs no materialization at all.
@(test)
test_view_reuses_snapshot :: proc(t: ^testing.T) {
    pt := piecetable_create("hello")
    defer piecetable_destroy(&pt)

    first := piecetable_view(&pt)
    second := piecetable_view(&pt)
    testing.expect(t, raw_data(first) == raw_data(second), "an unchanged table re-materialized")

    piecetable_insert(&pt, 5, "!")
    testing.expect_value(t, piecetable_view(&pt), "hello!")
}

// A delete running past the end removes what is there; the length must count
// that, not what was asked for.
@(test)
test_length_after_overlong_delete :: proc(t: ^testing.T) {
    pt := piecetable_create("abc")
    defer piecetable_destroy(&pt)

    piecetable_delete(&pt, 1, 99)
    testing.expect_value(t, piecetable_length(&pt), 1)
    testing.expect_value(t, piecetable_view(&pt), "a")
}

// An out-of-range position clamps to the ends instead of splitting a piece into
// a negative length.
@(test)
test_out_of_range_positions :: proc(t: ^testing.T) {
    pt := piecetable_create("abc")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, -5, "X")
    testing.expect_value(t, piecetable_view(&pt), "Xabc")
    testing.expect_value(t, piecetable_length(&pt), 4)

    piecetable_insert(&pt, 99, "Y")
    testing.expect_value(t, piecetable_view(&pt), "XabcY")
    testing.expect_value(t, piecetable_length(&pt), 5)

    // The range is [pos, pos + length): only the part inside the text goes.
    piecetable_delete(&pt, -3, 4)
    testing.expect_value(t, piecetable_view(&pt), "abcY")
    testing.expect_value(t, piecetable_length(&pt), 4)

    piecetable_delete(&pt, 99, 4)
    testing.expect_value(t, piecetable_view(&pt), "abcY")
    testing.expect_value(t, piecetable_length(&pt), 4)

    for piece in pt.pieces {
        testing.expect(t, piece.length > 0, "a piece of non-positive length survived")
        testing.expect(t, piece.start >= 0, "a piece starting before its buffer survived")
    }
}

@(test)
test_set_text_resets :: proc(t: ^testing.T) {
    pt := piecetable_create("first")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, 5, "!")
    piecetable_set_text(&pt, "second")
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "second")
    testing.expect_value(t, piecetable_length(&pt), 6)
    testing.expect_value(t, len(pt.add), 0)
}
