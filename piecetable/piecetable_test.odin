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
