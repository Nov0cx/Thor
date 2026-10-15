package piecetable

import "core:math/rand"
import "core:strings"
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

// set_text must survive text that borrows the table's own snapshot: the new
// table is built before the old one is freed.
@(test)
test_set_text_from_own_view :: proc(t: ^testing.T) {
    pt := piecetable_create("hello")
    defer piecetable_destroy(&pt)

    piecetable_set_text(&pt, piecetable_view(&pt))
    testing.expect_value(t, piecetable_view(&pt), "hello")
    testing.expect_value(t, piecetable_length(&pt), 5)
}

// The snapshot is brought up to date on the first read after each edit, and only then.
@(test)
test_view_tracks_edits :: proc(t: ^testing.T) {
    pt := piecetable_create("hello world")
    defer piecetable_destroy(&pt)

    testing.expect_value(t, piecetable_view(&pt), "hello world")
    testing.expect(t, !pt.stale, "a read must leave the snapshot fresh")

    piecetable_insert(&pt, 5, ",")
    testing.expect_value(t, len(pt.pending), 1)
    testing.expect_value(t, piecetable_view(&pt), "hello, world")

    piecetable_delete(&pt, 0, 7)
    testing.expect_value(t, len(pt.pending), 1)
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

// Replace All's core pattern: many delete+insert pairs at strictly ascending
// positions over one Original piece. Each pair must resolve through the
// resumed scan hint rather than a full rescan, or the piece list this
// produces (one non-mergeable split per match) turns the pass quadratic.
@(test)
test_ascending_edits_resume_from_hint :: proc(t: ^testing.T) {
    pt := piecetable_create("aXaXaXaXaXa")
    defer piecetable_destroy(&pt)

    for pos := 0; pos < piecetable_length(&pt); pos += 1 {
        if piecetable_view(&pt)[pos] != 'X' {
            continue
        }
        piecetable_delete(&pt, pos, 1)
        piecetable_insert(&pt, pos, "Y")
        testing.expect(t, pt.hint_index >= 0, "an ascending edit must leave a usable hint")
    }

    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "aYaYaYaYaYa")
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

// The checked edits reject an offset outside the buffer and leave it untouched.
@(test)
test_checked_edits_reject_out_of_range :: proc(t: ^testing.T) {
    pt := piecetable_create("hello")
    defer piecetable_destroy(&pt)

    testing.expect_value(t, piecetable_insert_checked(&pt, -1, "x"), Error.Out_Of_Range)
    testing.expect_value(t, piecetable_insert_checked(&pt, 6, "x"), Error.Out_Of_Range)
    testing.expect_value(t, piecetable_delete_checked(&pt, 3, 5), Error.Out_Of_Range)
    testing.expect_value(t, piecetable_delete_checked(&pt, -1, 2), Error.Out_Of_Range)
    testing.expect_value(t, piecetable_delete_checked(&pt, 0, -1), Error.Out_Of_Range)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "hello")
    testing.expect_value(t, piecetable_length(&pt), 5)

    // The bounds themselves are valid: an insert at length appends, a delete of
    // the last byte ends exactly at length.
    testing.expect_value(t, piecetable_insert_checked(&pt, 5, "!"), Error.None)
    testing.expect_value(t, piecetable_delete_checked(&pt, 5, 1), Error.None)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "hello")
}

// The unchecked edits clamp instead of failing, which is what the checked ones
// exist to catch.
@(test)
test_unchecked_edits_clamp :: proc(t: ^testing.T) {
    pt := piecetable_create("ab")
    defer piecetable_destroy(&pt)

    piecetable_insert(&pt, 99, "c")
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "abc")
    piecetable_insert(&pt, -4, "z")
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "zabc")

    piecetable_delete(&pt, 2, 99)
    testing.expect_value(t, piecetable_to_string(&pt, context.temp_allocator), "za")
    testing.expect_value(t, piecetable_length(&pt), 2)
}

// The snapshot patched in place from pending edits equals a full rebuild.
@(test)
test_patched_view_matches_rebuild :: proc(t: ^testing.T) {
    pt := piecetable_create("line one\nline two\nline three\n")
    defer piecetable_destroy(&pt)
    model := strings.builder_make(context.temp_allocator)
    strings.write_string(&model, piecetable_view(&pt))

    gen := rand.create_u64(7)
    context.random_generator = rand.default_random_generator(&gen)
    words := [?]string{"x", "\n", "abc", "ü", "\tz\n"}
    for round in 0 ..< 400 {
        edits := 1 + rand.int_max(3)
        for _ in 0 ..< edits {
            n := len(model.buf)
            pos := rand.int_max(n + 1)
            if rand.int_max(2) == 0 || n == 0 {
                word := words[rand.int_max(len(words))]
                piecetable_insert(&pt, pos, word)
                inject_at(&model.buf, pos, ..transmute([]u8)word)
            } else {
                count := min(1 + rand.int_max(4), n - pos)
                piecetable_delete(&pt, pos, count)
                remove_range(&model.buf, pos, pos + count)
            }
        }
        if piecetable_view(&pt) != strings.to_string(model) {
            testing.expectf(t, false, "round %d: patched snapshot drifted", round)
            return
        }
    }
}

// More pending edits than MAX_PENDING fall back to a full rebuild.
@(test)
test_many_edits_rebuild :: proc(t: ^testing.T) {
    pt := piecetable_create("abc")
    defer piecetable_destroy(&pt)
    _ = piecetable_view(&pt)

    for i in 0 ..= MAX_PENDING {
        piecetable_insert(&pt, i, "-")
    }
    testing.expect(t, pt.stale, "the overflow must mark the snapshot for a rebuild")
    testing.expect_value(t, len(pt.pending), 0)
    testing.expect_value(t, piecetable_view(&pt), "---------abc")
}

// A view borrowed before an edit stays intact until the next read.
@(test)
test_borrowed_view_survives_edit :: proc(t: ^testing.T) {
    pt := piecetable_create("hello world")
    defer piecetable_destroy(&pt)

    before := piecetable_view(&pt)
    piecetable_delete(&pt, 0, 6)
    piecetable_insert(&pt, 0, before[6:])
    testing.expect_value(t, before, "hello world")
    testing.expect_value(t, piecetable_view(&pt), "worldworld")
}
